import Foundation
import Compression

/// How a file's bytes are compressed. DuckDB decompresses gzip and zstd while it reads.
public enum FileCompression: String, Sendable {
    case none, gzip, zstd
    /// The value of DuckDB's `compression` reader option.
    var duckDB: String { self == .none ? "uncompressed" : rawValue }
}

/// What Scan reads a file or folder as.
public enum FileFormat: Sendable, Equatable {
    /// Delimited text. A nil delimiter lets DuckDB's sniffer choose it.
    case delimited(delimiter: String?)
    case jsonLines, json, geoJSON, parquet, excel, sqlite, duckdb
    /// A folder of files in one format, possibly Hive-partitioned (`year=2024/…`).
    indirect case dataset(FileFormat)

    /// Lowercased file name extensions for each format. Compressed text adds `.gz`, `.zst` or `.zstd`.
    static let delimitedExtensions = ["csv": nil, "tsv": "\t", "tab": "\t", "psv": "|", "txt": nil, "dat": nil] as [String: String?]
    static let jsonLinesExtensions: Set<String> = ["jsonl", "ndjson"]
    static let parquetExtensions: Set<String> = ["parquet", "parq", "pq"]
    static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "s3db", "sl3"]
    static let duckDBExtensions: Set<String> = ["duckdb", "ddb"]
}

/// A detected file format, its compression and a short label for the status bar.
public struct FileKind: Sendable, Equatable {
    public var format: FileFormat
    public var compression: FileCompression = .none
    public var label: String

    /// The format implied by a file name alone, without reading the file. Used for icons.
    public static func guess(name: String) -> FileKind? {
        var parts = name.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return nil }
        var compression = FileCompression.none
        switch parts.last {
        case "gz": compression = .gzip
        case "zst", "zstd": compression = .zstd
        default: break
        }
        if compression != .none { parts.removeLast(); guard parts.count > 1 else { return nil } }
        let ext = parts.last!
        let suffix = compression == .none ? "" : (compression == .gzip ? ".gz" : ".zst")
        let format: FileFormat
        if let delimiter = FileFormat.delimitedExtensions[ext] { format = .delimited(delimiter: delimiter) }
        else if FileFormat.jsonLinesExtensions.contains(ext) { format = .jsonLines }
        else if ext == "json" { format = .json }
        else if ext == "geojson" { format = .geoJSON }
        else if compression != .none { return nil }
        else if FileFormat.parquetExtensions.contains(ext) { format = .parquet }
        else if ext == "xlsx" { format = .excel }
        else if FileFormat.sqliteExtensions.contains(ext) { format = .sqlite }
        else if FileFormat.duckDBExtensions.contains(ext) { format = .duckdb }
        else { return nil }
        return FileKind(format: format, compression: compression, label: ext + suffix)
    }

    /// The format of a local file or folder. Database files are identified by their header, so a
    /// `.db` file can be either SQLite or DuckDB.
    public static func detect(_ url: URL) throws -> FileKind {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return try Dataset.scan(url).kind
        }
        let header = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }; return try? handle.read(upToCount: 16)
        } ?? Data()
        if header.starts(with: Data("SQLite format 3\0".utf8)) { return FileKind(format: .sqlite, label: "sqlite") }
        if header.count >= 12, header[header.startIndex + 8 ..< header.startIndex + 12] == Data("DUCK".utf8) { return FileKind(format: .duckdb, label: "duckdb") }
        guard var kind = guess(name: url.lastPathComponent) else {
            throw EngineError("Scan cannot open .\(url.pathExtension) files. Open CSV, TSV, JSON, JSONL, GeoJSON, Parquet, Excel, SQLite or DuckDB files, or a folder of them.")
        }
        switch kind.format {
        case .sqlite, .duckdb: throw EngineError("This file is not a SQLite or DuckDB database.")
        case .excel where !header.starts(with: [0x50, 0x4B, 0x03, 0x04]):
            throw EngineError("This is not an .xlsx workbook. Scan reads Excel 2007 and later files; save older .xls files as .xlsx first.")
        default: break
        }
        // A gzip or zstd suffix on a file that is not compressed would make DuckDB fail later.
        if kind.compression == .gzip && !header.starts(with: [0x1F, 0x8B]) { kind.compression = .none }
        if kind.compression == .zstd && !header.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { kind.compression = .none }
        return kind
    }
}

/// A folder read as one table: every file of the most common supported format, matched with
/// recursive globs. `key=value` folder names become columns (Hive partitioning).
struct Dataset {
    var kind: FileKind
    var globs: [String]
    var hivePartitioned: Bool

    /// Files are counted up to this limit to choose the format; the globs still match all of them.
    static let scanLimit = 20_000

    static func scan(_ folder: URL) throws -> Dataset {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw EngineError("Could not read the folder.")
        }
        // Group files by format family; remember each family's suffixes for the globs.
        var counts: [String: Int] = [:], suffixes: [String: Set<String>] = [:], formats: [String: FileFormat] = [:]
        var hive = false, seen = 0
        for case let file as URL in walker {
            guard seen < scanLimit else { break }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let kind = FileKind.guess(name: file.lastPathComponent) else { continue }
            let family: String
            switch kind.format {
            case .parquet: family = "parquet"
            case .delimited(let delimiter): family = "delimited:" + (delimiter ?? "auto")
            case .jsonLines, .json: family = "json"
            default: continue
            }
            seen += 1
            counts[family, default: 0] += 1
            formats[family] = kind.format == .json ? .jsonLines : kind.format
            suffixes[family, default: []].insert(kind.label)
            let relative = file.deletingLastPathComponent().path.dropFirst(root.path.count)
            if relative.split(separator: "/").contains(where: { $0.contains("=") }) { hive = true }
        }
        guard let family = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key,
              let format = formats[family] else {
            throw EngineError("This folder contains no Parquet, CSV, TSV or JSON Lines files.")
        }
        let globs = suffixes[family, default: []].sorted().map { root.appendingPathComponent("**/*.\($0)").path }
        let label = (family == "parquet" ? "parquet" : family == "json" ? "jsonl" : "csv") + " folder"
        return Dataset(kind: FileKind(format: .dataset(format), label: label), globs: globs, hivePartitioned: hive)
    }
}

/// Lists the sheets of an .xlsx workbook by reading `xl/workbook.xml` from the zip archive.
/// The Excel extension reads one named sheet at a time but cannot list them.
enum XLSXSheets {
    static func names(_ url: URL) throws -> [String] {
        let data = try entry("xl/workbook.xml", in: url)
        let delegate = SheetCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw EngineError("The workbook's sheet list could not be read.") }
        return delegate.names
    }

    private final class SheetCollector: NSObject, XMLParserDelegate {
        var names: [String] = []
        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            // Some writers prefix the main namespace, e.g. <x:sheet>.
            if element.split(separator: ":").last == "sheet", let name = attributes["name"] { names.append(name) }
        }
    }

    /// The uncompressed bytes of one stored or deflated member of a zip archive.
    static func entry(_ path: String, in url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = try handle.seekToEnd()
        // The end-of-central-directory record is in the last 22 bytes plus an optional comment.
        let tailLength = min(size, 22 + 65_535)
        try handle.seek(toOffset: size - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard tail.count >= 22, let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: { u32(tail, $0) == 0x0605_4B50 }) else {
            throw EngineError("This .xlsx file is damaged: no zip directory.")
        }
        let directorySize = Int(u32(tail, end + 12)), directoryOffset = UInt64(u32(tail, end + 16))
        guard directoryOffset != 0xFFFF_FFFF, directoryOffset + UInt64(directorySize) <= size else {
            throw EngineError("This .xlsx file is damaged or too large to list its sheets.")
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = [UInt8](try handle.read(upToCount: directorySize) ?? Data())
        var cursor = 0
        while cursor + 46 <= directory.count, u32(directory, cursor) == 0x0201_4B50 {
            let method = u16(directory, cursor + 10)
            let compressed = Int(u32(directory, cursor + 20)), uncompressed = Int(u32(directory, cursor + 24))
            let nameLength = Int(u16(directory, cursor + 28))
            let next = cursor + 46 + nameLength + Int(u16(directory, cursor + 30)) + Int(u16(directory, cursor + 32))
            guard cursor + 46 + nameLength <= directory.count else { break }
            let name = String(decoding: directory[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            if name == path {
                try handle.seek(toOffset: UInt64(u32(directory, cursor + 42)))
                let local = [UInt8](try handle.read(upToCount: 30) ?? Data())
                guard local.count == 30, u32(local, 0) == 0x0403_4B50 else { throw EngineError("This .xlsx file is damaged.") }
                try handle.seek(toOffset: try handle.offset() + UInt64(u16(local, 26)) + UInt64(u16(local, 28)))
                let payload = try handle.read(upToCount: compressed) ?? Data()
                guard payload.count == compressed, uncompressed < 256 << 20 else { throw EngineError("This .xlsx file is damaged.") }
                if method == 0 { return payload }
                guard method == 8 else { throw EngineError("This .xlsx file uses an unsupported compression method.") }
                // Apple's COMPRESSION_ZLIB is raw DEFLATE, which is what zip members contain.
                var output = Data(count: max(uncompressed, 1))
                let written = output.withUnsafeMutableBytes { out in
                    payload.withUnsafeBytes { input in
                        compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, uncompressed,
                                                  input.bindMemory(to: UInt8.self).baseAddress!, compressed, nil, COMPRESSION_ZLIB)
                    }
                }
                guard written == uncompressed else { throw EngineError("This .xlsx file is damaged.") }
                return output.prefix(written)
            }
            cursor = next
        }
        throw EngineError("This file is not an Excel workbook: it has no xl/workbook.xml.")
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
