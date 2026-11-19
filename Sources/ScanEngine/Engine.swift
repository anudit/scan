import Foundation
import ScanQuery
import CSQLite
import os

public struct SourceInfo: Sendable {
    public var columns: [Column]; public var tables: [String]; public var format: String; public var needsImport: Bool
    /// True when the file is being read from a URL, with only downloaded row groups available locally.
    public var isRemote: Bool = false
}
/// File formats the current view can be exported to, chosen by file extension.
public enum ExportFormat: String, CaseIterable, Sendable {
    case csv, json, jsonl, parquet
    public init?(url: URL) { self.init(rawValue: url.pathExtension.lowercased() == "ndjson" ? "jsonl" : url.pathExtension.lowercased()) }
    public var title: String { switch self { case .csv: "CSV"; case .json: "JSON (array)"; case .jsonl: "JSON Lines"; case .parquet: "Parquet" } }
    var copyOptions: String {
        switch self {
        case .csv: "FORMAT CSV, HEADER true"
        case .json: "FORMAT JSON, ARRAY true"
        case .jsonl: "FORMAT JSON"
        case .parquet: "FORMAT PARQUET"
        }
    }
}
/// Value counts for a profile or a facet. A nil value is NULL.
public struct ValueCount: Sendable, Hashable {
    public var value: String?
    public var count: Int
    public init(value: String?, count: Int) { self.value = value; self.count = count }
}
/// A summary of one column in the active view.
public struct ColumnProfile: Sendable, Equatable {
    public var column: String
    public var kind: CellKind
    public var rows = 0
    public var nulls = 0
    /// Approximate (HyperLogLog), and excluding NULL.
    public var distinct = 0
    public var minimum: String?
    public var maximum: String?
    public var mean: Double?
    /// Equal-width counts between `binRange` bounds, for numbers and dates (as epoch seconds).
    public var bins: [Int] = []
    public var binRange: ClosedRange<Double>?
    public var top: [ValueCount] = []
    public init(column: String, kind: CellKind) { self.column = column; self.kind = kind }
}
public struct AskResult: Sendable {
    public var columns: [Column]
    public var page: RowPage
}
public actor Engine {
    private nonisolated let connection: Connection
    private var source = "source"
    private var sourceURL: URL?
    private var format = ""
    /// An attached DuckDB database. Its rowid is not dense, so pages go through an ordered row list.
    private var isDatabase = false
    /// A single Parquet file, whose file_row_number column is hidden.
    private var isParquet = false
    private var schema: [Column] = []
    private var tables: [String] = []
    private var hasRowID = false
    private var rowID = "rowid"
    private var ordered = false
    private var activeState = ViewState()
    private var generation = 0
    private var remote: RemoteParquet?
    private var remoteRevision = -1
    /// The local copy of a remote non-Parquet file, kept while another table of it is opened.
    private var remoteDownload: URL?
    private let remoteCache: URL?
    private let log = OSSignposter(subsystem: "dev.scan.app", category: "Queries")
    public init(memoryMB: Int = 512, threads: Int = 4, remoteCache: URL? = nil) throws {
        connection = try Connection(memoryMB: memoryMB, threads: threads)
        self.remoteCache = remoteCache
    }
    /// Rows a text-file preview reads to infer column types.
    static let previewSampleRows = 128
    /// The small engine Quick Look uses for one preview.
    public static func preview() throws -> Engine { try Engine(memoryMB: 128, threads: 2) }
    public nonisolated func cancel() { connection.cancel() }
    public var memoryLimitMB: Int { connection.memoryMB }
    public func open(_ url: URL, table: String? = nil, previewLimit: Int? = nil) async throws -> SourceInfo {
        sourceURL = url; ordered = false; isDatabase = false; isParquet = false
        remote = nil; remoteRevision = -1
        if table == nil { remoteDownload = nil }
        try connection.execute("DROP VIEW IF EXISTS scan_data")
        try connection.execute("DROP VIEW IF EXISTS source")
        if RemoteFile.isRemote(url) {
            return try await openRemote(url, table: table, previewLimit: previewLimit)
        }
        return try openLocal(url, table: table, previewLimit: previewLimit)
    }
    private func openLocal(_ url: URL, table: String?, previewLimit: Int?) throws -> SourceInfo {
        // A folder is scanned once, here; its file list is not needed again.
        var isDirectory: ObjCBool = false
        let dataset = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? try Dataset.scan(url) : nil
        let kind = try dataset?.kind ?? FileKind.detect(url)
        format = kind.label
        let path = Planner.literal(url.path)
        switch kind.format {
        case .duckdb:
            if tables.isEmpty { try connection.execute("ATTACH \(path) AS input (READ_ONLY)") }
            let result = try connection.query(SQL("SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_catalog='input' ORDER BY 1"))
            tables = result.columns.first?.compactMap { $0 } ?? []
            guard let chosen = table ?? tables.first else { throw EngineError("This database contains no tables.") }
            let parts = chosen.split(separator: ".", maxSplits: 1).map(String.init)
            source = "input." + parts.map(Planner.identifier).joined(separator: ".")
            rowID = "rowid"; hasRowID = true; isDatabase = true
        case .sqlite:
            tables = try sqliteTables(url)
            guard let chosen = table ?? tables.first else { throw EngineError("This database contains no tables.") }
            try importSQLite(url, table: chosen, limit: previewLimit)
            source = "sqlite_data"; rowID = "rowid"; hasRowID = true
        case .excel:
            tables = try XLSXSheets.names(url)
            guard let chosen = table ?? tables.first else { throw EngineError("This workbook contains no sheets.") }
            try importExcel(url, sheet: chosen, limit: previewLimit)
            source = "excel_data"; rowID = "rowid"; hasRowID = true
        case .dataset(let inner):
            tables = []
            guard let dataset else { throw EngineError("This folder cannot be read.") }
            let files = "[" + dataset.globs.map(Planner.literal).joined(separator: ", ") + "]"
            let options = "union_by_name=true, hive_partitioning=\(dataset.hivePartitioned)"
            let reader: String
            switch inner {
            case .parquet: reader = "read_parquet(\(files), \(options))"
            case .jsonLines: reader = "read_json(\(files), format='auto', \(options), sample_size=\(previewLimit == nil ? -1 : 2048), maximum_object_size=\(Self.maxJSONObject))"
            case .delimited(let delimiter): reader = "read_csv(\(files), header=true, \(options), sample_size=2048\(delimiter.map { ", delim=\(Planner.literal($0))" } ?? ""))"
            default: throw EngineError("This folder's files cannot be read as one table.")
            }
            // file_row_number restarts in every file, so a folder has no stable row ID until it is indexed.
            source = "source"; rowID = "rowid"; hasRowID = false
            try connection.execute("CREATE VIEW source AS SELECT * FROM \(reader)")
        case .geoJSON:
            tables = []
            source = "source"; rowID = "rowid"; hasRowID = false
            try connection.execute("CREATE VIEW source AS \(try geoJSONQuery(url, compression: kind.compression))")
        case .parquet, .delimited, .jsonLines, .json:
            tables = []
            source = "source"
            let parquet = kind.format == .parquet
            isParquet = parquet
            func reader(_ path: String, compression: FileCompression, preview: Bool) -> String {
                let path = Planner.literal(path)
                switch kind.format {
                case .parquet: return "read_parquet(\(path), file_row_number=true)"
                case .jsonLines: return "read_json(\(path), format='newline_delimited', sample_size=\(preview ? 2048 : -1), maximum_object_size=\(Self.maxJSONObject), compression='\(compression.duckDB)')"
                // 'auto' reads a top-level array of objects, one object per line, or a single object.
                case .json: return "read_json(\(path), format='auto', sample_size=\(preview ? 2048 : -1), maximum_object_size=\(Self.maxJSONObject), compression='\(compression.duckDB)')"
                case .delimited(let delimiter): return "read_csv(\(path), header=true, sample_size=2048, compression='\(compression.duckDB)'\(delimiter.map { ", delim=\(Planner.literal($0))" } ?? ""))"
                default: fatalError("not a single-file reader")
                }
            }
            hasRowID = parquet; rowID = "file_row_number"
            // A text preview reads only the file's head: the header plus enough rows to infer types
            // (the full app samples 2,048). Scanning or sniffing the whole file is what made Quick Look slow.
            // JSON arrays and zstd files have no cheap line-based head, so DuckDB streams them instead.
            let lineBased = kind.format == .jsonLines || { if case .delimited = kind.format { return true }; return false }()
            if lineBased, kind.compression != .zstd, let limit = previewLimit,
               let sample = try? headSample(url, gzip: kind.compression == .gzip, records: max(limit, Self.previewSampleRows) + 1, quoted: kind.format != .jsonLines) {
                do {
                    // Sniff once: keep the preview rows in a table so schema and rows need no re-read.
                    try connection.execute("CREATE OR REPLACE TABLE preview_rows AS SELECT * FROM \(reader(sample.path, compression: .none, preview: true)) LIMIT \(max(0, limit))")
                    source = "preview_rows"; rowID = "rowid"; hasRowID = true
                    schema = try describe(source)
                    try connection.execute("CREATE TEMP VIEW scan_data AS SELECT * FROM \(source)")
                    activeState = ViewState(); activeState.columns = schema
                    return SourceInfo(columns: schema, tables: tables, format: format, needsImport: false)
                } catch { source = "source"; rowID = "file_row_number"; hasRowID = false }
            }
            try connection.execute("CREATE VIEW source AS SELECT * FROM \(reader(url.path, compression: kind.compression, preview: previewLimit != nil))")
        }
        schema = try describe(source).filter { !(isParquet && $0.name == "file_row_number") }
        try connection.execute("CREATE TEMP VIEW scan_data AS SELECT * FROM \(source)")
        activeState = ViewState(); activeState.columns = schema
        return SourceInfo(columns: schema, tables: tables, format: format, needsImport: !hasRowID)
    }
    /// The largest single JSON value read_json accepts (100 MB), unless a GeoJSON file needs more.
    static let maxJSONObject = 104_857_600
    /// One row per GeoJSON feature: its properties become columns and the geometry stays JSON.
    private func geoJSONQuery(_ url: URL, compression: FileCompression) throws -> String {
        // A FeatureCollection is one JSON object, so the reader must accept the whole document.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let limit = min(Int(UInt32.max), max(Self.maxJSONObject, compression == .none ? size + 1 : size * 20))
        let document = "read_json(\(Planner.literal(url.path)), format='auto', records=true, sample_size=-1, maximum_object_size=\(limit), compression='\(compression.duckDB)')"
        guard try describe(document).contains(where: { $0.name == "features" && $0.type.hasSuffix("[]") }) else {
            throw EngineError("This GeoJSON file is not a FeatureCollection.")
        }
        // One column per feature member: type, geometry, properties and, when present, id.
        try connection.execute("CREATE OR REPLACE VIEW geo_features AS SELECT unnest(f) FROM (SELECT unnest(features) AS f FROM \(document))")
        let members = Dictionary(try describe("geo_features").map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
        // Properties with a consistent shape are a STRUCT and expand into columns; mixed ones stay JSON.
        let properties = members["properties"].map { $0.hasPrefix("STRUCT(") ? "unnest(properties)" : "properties" }
        let projection = [members["id"] != nil ? "id AS feature_id" : nil, properties,
                          members["geometry"] != nil ? "CAST(to_json(geometry) AS JSON) AS geometry" : nil].compactMap { $0 }
        guard !projection.isEmpty else { throw EngineError("This GeoJSON file has no features.") }
        return "SELECT \(projection.joined(separator: ", ")) FROM geo_features"
    }
    /// Opens a remote Parquet file through a sparse local cache. Only the footer (and then the
    /// row groups needed for a page) is downloaded; DuckDB reads the assembled local file.
    private func openRemote(_ url: URL, table: String?, previewLimit: Int?) async throws -> SourceInfo {
        // Only Parquet can be read by range. Other files are downloaded whole, then opened locally.
        if (try? RemoteParquet.normalizedURL(url)) == nil {
            let local: URL
            if let downloaded = remoteDownload, table != nil { local = downloaded }
            else { local = try await RemoteFile.download(url, cacheRoot: remoteCache); remoteDownload = local }
            var info = try openLocal(local, table: table, previewLimit: previewLimit)
            info.isRemote = true
            return info
        }
        let remote = try await RemoteParquet.open(url: url, cacheRoot: remoteCache)
        self.remote = remote
        format = "parquet"; isParquet = true
        tables = []
        hasRowID = true; rowID = "file_row_number"
        source = "source"
        try createRemoteView(remote)
        remoteRevision = await remote.revision
        schema = try describe(source).filter { $0.name != "file_row_number" }
        try connection.execute("CREATE TEMP VIEW scan_data AS SELECT * FROM \(source)")
        activeState = ViewState(); activeState.columns = schema
        return SourceInfo(columns: schema, tables: tables, format: format, needsImport: false, isRemote: true)
    }
    private func createRemoteView(_ remote: RemoteParquet) throws {
        try connection.execute("CREATE VIEW source AS SELECT * FROM read_parquet(\(Planner.literal(remote.dataURL.path)), file_row_number=true)")
    }
    /// Rebuilds the views after new row groups were added to the cache file.
    private func refreshRemoteView() async throws {
        guard let remote else { return }
        let revision = await remote.revision
        guard revision != remoteRevision else { return }
        try connection.execute("DROP VIEW IF EXISTS scan_data")
        try connection.execute("DROP VIEW IF EXISTS source")
        try createRemoteView(remote)
        try connection.execute("CREATE TEMP VIEW scan_data AS SELECT * FROM source")
        remoteRevision = revision
    }
    /// A short description of how much of a remote file has been cached, or nil for local files.
    public func remoteStatus() async -> RemoteParquetStatus? {
        guard let remote else { return nil }
        var status = await remote.status()
        status.complete = await remote.isComplete
        return status
    }
    private func describe(_ relation: String) throws -> [Column] {
        let rows = try connection.query(SQL("SELECT CAST(column_name AS VARCHAR), CAST(column_type AS VARCHAR) FROM (DESCRIBE SELECT * FROM \(relation))"))
        return (0..<rows.count).map { Column(rows.columns[0][$0] ?? "", rows.columns[1][$0] ?? "VARCHAR") }
    }
    /// Copies the first `records` records of a text file, decompressing gzip, into the private temp directory.
    /// With `quoted`, newlines inside double-quoted CSV fields do not end a record.
    private func headSample(_ url: URL, gzip: Bool, records: Int, quoted: Bool, maxBytes: Int = 16 << 20) throws -> URL {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var output = Data(), count = 0, boundary = 0, inQuote = false, finished = false
        let inflater = gzip ? try GzipHead() : nil
        scan: while count < records && output.count < maxBytes {
            guard let chunk = try handle.read(upToCount: 256 << 10), !chunk.isEmpty else { finished = true; break }
            let bytes = try inflater?.inflate(chunk) ?? chunk
            let base = output.count
            output.append(bytes)
            for (index, byte) in bytes.enumerated() {
                if quoted && byte == 0x22 { inQuote.toggle() }
                else if byte == 0x0A && !inQuote {
                    count += 1; boundary = base + index + 1
                    if count == records { break scan }
                }
            }
            if inflater?.ended == true { finished = true; break }
        }
        // Keep whole records only. Without one, the caller reads the whole file instead.
        if !finished { guard count > 1 else { throw EngineError("No complete records in the file head.") }; output = output.prefix(boundary) }
        let sample = connection.directory.appendingPathComponent("head-sample.txt")
        try output.write(to: sample)
        return sample
    }
    public func materialize() throws {
        guard !hasRowID else { return }
        try connection.execute("CREATE OR REPLACE TABLE imported AS SELECT * FROM source",retryOnOOM:true)
        source = "imported"; rowID = "rowid"; hasRowID = true
        try connection.execute("CREATE OR REPLACE TEMP VIEW scan_data AS SELECT * FROM imported")
    }
    private func whereClause(_ state: ViewState) throws -> String {
        try Planner.validateFilter(state.filter)
        return state.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " WHERE (\(state.filter))"
    }
    public func apply(_ state: ViewState, generation: Int) async throws -> Int {
        let interval = log.beginInterval("apply")
        defer { log.endInterval("apply", interval) }
        let predicate = try whereClause(state)
        if let remote {
            // A filter or sort reads every row, so the whole remote file must be present.
            if !state.filter.isEmpty || !state.sorts.isEmpty {
                try await remote.ensureAll()
                try Task.checkCancellation()
                try await refreshRemoteView()
            } else {
                // Plain paging can stay partial. The row count comes from the footer.
                ordered = false
                activeState = state; self.generation = generation
                return Int(remote.totalRows)
            }
        }
        if !state.sorts.isEmpty && !hasRowID { try materialize() }
        if !state.sorts.isEmpty || (!predicate.isEmpty && hasRowID) || isDatabase {
            let order = Planner.order(state.sorts)
            // Materialize only ordered row IDs. Payload columns never enter the sort.
            try connection.execute("CREATE OR REPLACE TEMP TABLE next_order AS SELECT \(Planner.identifier(rowID)) AS rid FROM \(source)\(predicate)\(order)",retryOnOOM:true)
            try connection.execute("DROP TABLE IF EXISTS scan_order")
            try connection.execute("ALTER TABLE next_order RENAME TO scan_order")
            ordered = true
        } else { ordered = false }
        activeState = state; self.generation = generation
        let count = try connection.query(SQL("SELECT CAST(count(*) AS VARCHAR) FROM \(ordered ? "scan_order" : source)\(ordered ? "" : predicate)"))
        return Int(count.columns[0][0] ?? "0") ?? 0
    }
    /// Fetches rows [offset, offset+limit) of the active view. `only` restricts the columns read;
    /// the others come back empty, so callers can load cheap columns first.
    public func page(offset: Int, limit: Int = 256, generation: Int, full: Bool = false, only: Set<String>? = nil) async throws -> RowPage {
        guard generation == self.generation else { throw CancellationError() }
        let interval = log.beginInterval("page fetch"); defer { log.endInterval("page fetch", interval) }
        let columns = activeState.columns
        let selected = columns.filter { only?.contains($0.name) ?? true }
        let projection = selected.map { Planner.display($0, alias: "s", full: full) }.joined(separator: ", ")
        guard !projection.isEmpty else { return RowPage(offset: offset, columns: columns.map { _ in [] }) }
        func aligned(_ fetched: [[String?]]) -> RowPage {
            var next = fetched.makeIterator()
            return RowPage(offset: offset, columns: columns.map { only?.contains($0.name) ?? true ? next.next() ?? [] : [] })
        }
        if let remote {
            let scansAll = ordered || !activeState.filter.isEmpty || !activeState.sorts.isEmpty
            if scansAll {
                try await remote.ensureAll()
                try Task.checkCancellation()
                try await refreshRemoteView()
            } else {
                let segments = try await remote.ensureRows(max(0, offset)..<(max(0, offset) + max(0, limit)), columns: only)
                guard generation == self.generation else { throw CancellationError() }
                try await refreshRemoteView()
                if !(await remote.isComplete) {
                    return try remotePage(offset: offset, limit: limit, columns: columns,
                                          selected: selected, projection: projection, only: only,
                                          segments: segments)
                }
            }
            guard generation == self.generation else { throw CancellationError() }
        }
        let sql: String
        if ordered {
            let keys = try connection.query(SQL("SELECT CAST(rid AS VARCHAR) FROM scan_order WHERE rowid >= \(max(0, offset)) AND rowid < \(max(0, offset) + max(0, limit)) ORDER BY rowid"))
            let ids = keys.columns.first?.compactMap { $0.flatMap(Int64.init) } ?? []
            guard let low = ids.min(), let high = ids.max() else { return RowPage(offset:offset,columns:columns.map { _ in [] }) }
            let rid = "s." + Planner.identifier(rowID)
            let fetched = try connection.query(SQL("SELECT CAST(\(rid) AS VARCHAR), \(projection) FROM \(source) s WHERE \(rid) BETWEEN \(low) AND \(high) AND \(rid) IN (\(ids.map(String.init).joined(separator:",")))"))
            var positions: [Int64:Int] = [:]
            for index in 0..<fetched.count { if let value = fetched.columns[0][index].flatMap(Int64.init) { positions[value] = index } }
            return aligned(fetched.columns.dropFirst().map { column in ids.map { id in positions[id].flatMap { column[$0] } } })
        } else if hasRowID && activeState.filter.isEmpty {
            sql = "SELECT \(projection) FROM \(source) s WHERE s.\(Planner.identifier(rowID)) >= \(max(0, offset)) AND s.\(Planner.identifier(rowID)) < \(max(0, offset) + max(0, limit))"
        } else { sql = "SELECT \(projection) FROM \(source) s\(try whereClause(activeState)) LIMIT \(max(0, limit)) OFFSET \(max(0, offset))" }
        return aligned(try connection.query(SQL(sql)).columns)
    }
    /// Reads a page from the subset of row groups currently in the local cache. Each segment is
    /// a contiguous run of rows in DuckDB's `file_row_number` space.
    private func remotePage(offset: Int, limit: Int, columns: [Column], selected: [Column],
                            projection: String, only: Set<String>?, segments: [RemoteRowSegment]) throws -> RowPage {
        var merged = columns.map { _ in [String?]() }
        let selectedIndices = columns.indices.filter { only?.contains(columns[$0].name) ?? true }
        for segment in segments {
            guard segment.count > 0 else { continue }
            let end = segment.fileRow + Int64(segment.count)
            let fetched = try connection.query(SQL("SELECT \(projection) FROM \(source) s WHERE s.\(Planner.identifier(rowID)) >= \(segment.fileRow) AND s.\(Planner.identifier(rowID)) < \(end)"))
            guard fetched.count == segment.count else {
                throw EngineError("The remote file changed while it was being read. Reopen the URL.")
            }
            for (index, column) in selectedIndices.enumerated() where fetched.columns.indices.contains(index) {
                merged[column].append(contentsOf: fetched.columns[index])
            }
        }
        return RowPage(offset: offset, columns: merged)
    }
    /// The full, untruncated value of one cell. Reads only that column.
    public func cell(row: Int, column: String, generation: Int) async throws -> String? {
        let page = try await page(offset: row, limit: 1, generation: generation, full: true, only: [column])
        guard let index = activeState.columns.firstIndex(where: { $0.name == column }) else { return nil }
        return page.columns[index].first ?? nil
    }
    /// The smallest and largest value of a numeric column in the active view (its filter applies),
    /// or nil when the column holds no finite numbers. Used to color a column as a heatmap.
    public func range(column: String, generation: Int) async throws -> ClosedRange<Double>? {
        guard generation == self.generation else { throw CancellationError() }
        // Min and max need every row; a partially cached remote file would give a partial range.
        try await loadAll()
        let value = "TRY_CAST(\(Planner.identifier(column)) AS DOUBLE)"
        let finite = "CASE WHEN isfinite(\(value)) THEN \(value) END"
        let result = try connection.query(SQL("SELECT CAST(min(\(finite)) AS VARCHAR), CAST(max(\(finite)) AS VARCHAR) FROM \(source)\(try whereClause(activeState))"))
        guard generation == self.generation else { throw CancellationError() }
        guard let low = result.columns.first?.first.flatMap({ $0 }).flatMap(Double.init),
              let high = result.columns.last?.first.flatMap({ $0 }).flatMap(Double.init) else { return nil }
        return low...high
    }
    /// A summary of one column in the active view: counts, extremes, a histogram for numbers and
    /// dates, and the most common values. A remote file is downloaded in full first.
    public func profile(column: String, generation: Int, bins: Int = 24, top: Int = 10) async throws -> ColumnProfile {
        guard generation == self.generation else { throw CancellationError() }
        guard let info = activeState.columns.first(where: { $0.name == column }) ?? schema.first(where: { $0.name == column }) else {
            throw EngineError("The column \(column) no longer exists.")
        }
        try await loadAll()
        let c = Planner.identifier(column), filter = try whereClause(activeState)
        let ordered = info.kind != .nested && info.kind != .binary
        let numeric = Self.numericExpression(info)
        let stats = try connection.query(SQL("""
            SELECT CAST(count(*) AS VARCHAR), CAST(count(\(c)) AS VARCHAR), CAST(approx_count_distinct(\(c)) AS VARCHAR),
                   \(ordered ? "CAST(min(\(c)) AS VARCHAR), CAST(max(\(c)) AS VARCHAR)" : "NULL, NULL"),
                   \(numeric.map { "CAST(avg(\($0)) AS VARCHAR), CAST(min(\($0)) AS VARCHAR), CAST(max(\($0)) AS VARCHAR)" } ?? "NULL, NULL, NULL")
            FROM \(source)\(filter)
            """)).columns.map { $0.first ?? nil }
        guard generation == self.generation else { throw CancellationError() }
        var profile = ColumnProfile(column: column, kind: info.kind)
        profile.rows = Int(stats[0] ?? "") ?? 0
        profile.nulls = profile.rows - (Int(stats[1] ?? "") ?? 0)
        profile.distinct = min(Int(stats[2] ?? "") ?? 0, profile.rows - profile.nulls)
        profile.minimum = stats[3]; profile.maximum = stats[4]
        if info.kind == .number { profile.mean = stats[5].flatMap(Double.init) }
        if let low = stats[6].flatMap(Double.init), let high = stats[7].flatMap(Double.init), let numeric {
            profile.bins = try histogram(numeric, low: low, high: high, bins: bins, filter: filter)
            profile.binRange = low...high
        }
        let values = try connection.query(SQL("""
            SELECT scan_value, CAST(scan_count AS VARCHAR) FROM (
                SELECT \(info.kind == .nested ? "CAST(to_json(\(c)) AS VARCHAR)" : "CAST(\(c) AS VARCHAR)") AS scan_value, count(*) AS scan_count
                FROM \(source)\(filter) GROUP BY 1)
            ORDER BY scan_count DESC, scan_value NULLS LAST LIMIT \(max(1, top))
            """)).columns
        guard generation == self.generation else { throw CancellationError() }
        profile.top = zip(values[0], values[1]).map { ValueCount(value: $0, count: Int($1 ?? "") ?? 0) }
        return profile
    }
    /// Value counts of a column in the active view, most common first, for a sidebar facet.
    public func topValues(column: String, limit: Int = 12, generation: Int) async throws -> [ValueCount] {
        try await profile(column: column, generation: generation, bins: 0, top: limit).top
    }
    /// Small histograms of numeric columns in the active view, for the header sparklines.
    /// Remote files are skipped: they would have to be downloaded in full.
    public func sparklines(columns: [String], bins: Int = 16, generation: Int) async throws -> [String: [Int]] {
        guard remote == nil else { return [:] }
        var result: [String: [Int]] = [:]
        let filter = try whereClause(activeState)
        for name in columns {
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
            guard let info = activeState.columns.first(where: { $0.name == name }), let numeric = Self.numericExpression(info) else { continue }
            let range = try connection.query(SQL("SELECT CAST(min(\(numeric)) AS VARCHAR), CAST(max(\(numeric)) AS VARCHAR) FROM \(source)\(filter)")).columns
            guard let low = range[0].first.flatMap({ $0 }).flatMap(Double.init), let high = range[1].first.flatMap({ $0 }).flatMap(Double.init) else { continue }
            result[name] = try histogram(numeric, low: low, high: high, bins: bins, filter: filter)
        }
        return result
    }
    /// The finite numeric value of a column, with dates and timestamps as epoch seconds.
    private static func numericExpression(_ column: Column) -> String? {
        let c = Planner.identifier(column.name), t = column.type.uppercased()
        let value: String
        if column.kind == .number { value = "TRY_CAST(\(c) AS DOUBLE)" }
        else if column.kind == .temporal, t.contains("DATE") || t.contains("TIMESTAMP") { value = "CAST(epoch(\(c)) AS DOUBLE)" }
        else { return nil }
        return "(CASE WHEN isfinite(\(value)) THEN \(value) END)"
    }
    private func histogram(_ value: String, low: Double, high: Double, bins: Int, filter: String) throws -> [Int] {
        guard bins > 0 else { return [] }
        let width = high - low
        let bucket = width > 0 ? "least(\(bins - 1), CAST(floor((\(value) - \(low)) / \(width) * \(bins)) AS INTEGER))" : "0"
        let condition = filter.isEmpty ? " WHERE \(value) IS NOT NULL" : filter + " AND \(value) IS NOT NULL"
        let result = try connection.query(SQL("SELECT CAST(\(bucket) AS VARCHAR), CAST(count(*) AS VARCHAR) FROM \(source)\(condition) GROUP BY 1")).columns
        var counts = Array(repeating: 0, count: width > 0 ? bins : 1)
        for (bin, count) in zip(result[0], result[1]) {
            if let bin = bin.flatMap(Int.init), counts.indices.contains(bin) { counts[bin] = Int(count ?? "") ?? 0 }
        }
        return counts
    }
    /// Every row of a remote file has to be local before a whole-column summary.
    private func loadAll() async throws {
        guard remote != nil else { return }
        try await remote?.ensureAll()
        try Task.checkCancellation()
        try await refreshRemoteView()
    }
    public func preview(limit: Int = 500) async throws -> RowPage { try await page(offset: 0, limit: limit, generation: generation) }
    public func validate(filter: String) async throws {
        try Planner.validateFilter(filter)
        _ = try connection.query(SQL("SELECT CAST(1 AS VARCHAR) FROM \(source) WHERE (\(filter.isEmpty ? "true" : filter)) LIMIT 0"))
    }
    public func ask(_ generatedSQL: String) async throws -> AskResult {
        let sql = try AskQuery.validate(generatedSQL)
        if let remote {
            try await remote.ensureAll()
            try await refreshRemoteView()
        }
        // Validate the parsed statement too; token checks alone cannot establish
        // that an LLM-generated statement is read-only.
        _ = try connection.query(SQL("SELECT * FROM (\(sql)) AS check_result LIMIT 0"), onlySelect: true)
        let columns = try describe("(\(sql))")
        guard !columns.isEmpty else { throw EngineError("The query returned no columns.") }
        let projection = columns.map { "left(CAST(\(Planner.identifier($0.name)) AS VARCHAR), 300) AS \(Planner.identifier($0.name))" }.joined(separator:", ")
        let page = try connection.query(SQL("SELECT \(projection) FROM (\(sql)) AS ask_result LIMIT 200"), onlySelect:true)
        return AskResult(columns:columns,page:page)
    }
    public func pivot(state: ViewState, path: [String?] = []) async throws -> [PivotNode] {
        guard path.count < state.groups.count else { return [] }
        if let remote {
            try await remote.ensureAll()
            try await refreshRemoteView()
        }
        let key = state.groups[path.count]
        let c = Planner.identifier(key)
        var predicates: [String] = []; var parameters: [String?] = []
        if !state.filter.isEmpty { try Planner.validateFilter(state.filter); predicates.append("(\(state.filter))") }
        for (i, value) in path.enumerated() { predicates.append("CAST(\(Planner.identifier(state.groups[i])) AS VARCHAR) IS NOT DISTINCT FROM ?"); parameters.append(value) }
        let aggregates = state.columns.map { col -> String in
            if col.name == key { return "CAST(\(c) AS VARCHAR)" }
            let op = state.aggregates[col.name] ?? (col.kind == .number ? .sum : .count)
            return "CAST(\(Planner.aggregate(op, column: col.name)) AS VARCHAR)"
        }
        let whereSQL = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let sql = "SELECT CAST(\(c) AS VARCHAR), \((aggregates + ["CAST(count(*) AS VARCHAR)"]).joined(separator: ", ")) FROM \(source)\(whereSQL) GROUP BY \(c) ORDER BY \(c) NULLS LAST LIMIT 10001"
        let result = try connection.query(SQL(sql, parameters))
        guard result.count <= 10000 else { throw EngineError("This pivot has more than 10,000 groups at one level. Filter the data before expanding it.") }
        return (0..<result.count).map { i in PivotNode(path: path + [result.columns[0][i]], values: Array(result.row(i).dropFirst())) }
    }
    public func export(to url: URL, state: ViewState) async throws {
        guard url.standardizedFileURL != sourceURL?.standardizedFileURL, !FileManager.default.fileExists(atPath: url.path) else { throw EngineError("Choose a new file. Scan never overwrites existing files.") }
        if let remote {
            try await remote.ensureAll()
            try await refreshRemoteView()
        }
        let projection: String
        let group: String
        if state.groups.isEmpty { projection = state.columns.map { Planner.identifier($0.name) }.joined(separator: ", "); group = "" }
        else {
            projection = (state.groups.map(Planner.identifier) + state.columns.filter { !state.groups.contains($0.name) }.map { "\(Planner.aggregate(state.aggregates[$0.name] ?? ($0.kind == .number ? .sum : .count), column: $0.name)) AS \(Planner.identifier($0.name))" } + ["count(*) AS Rec"]).joined(separator: ", ")
            group = " GROUP BY " + state.groups.map(Planner.identifier).joined(separator: ", ")
        }
        let query = "SELECT \(projection) FROM \(source)\(try whereClause(state))\(group)\(state.groups.isEmpty ? Planner.order(state.sorts) : "")"
        guard let format = ExportFormat(url: url) else { throw EngineError("Export as CSV, JSON, JSONL or Parquet.") }
        try connection.execute("COPY (\(query)) TO \(Planner.literal(url.path)) (\(format.copyOptions))")
    }
    private func sqliteOpen(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw EngineError("Could not open SQLite database read-only.")
        }; return db
    }
    private func sqliteTables(_ url: URL) throws -> [String] {
        let db = try sqliteOpen(url); defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name", -1, &statement, nil) == SQLITE_OK else { throw EngineError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }; var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(statement, 0))) }; return names
    }
    /// Copies one sheet into a table, including rows below blank rows. Column types come from the
    /// first data row; when a later cell does not fit them, the sheet is read again with every
    /// column as text, so no value is lost.
    private func importExcel(_ url: URL, sheet: String, limit: Int?) throws {
        let reader = "read_xlsx(\(Planner.literal(url.path)), sheet=\(Planner.literal(sheet)), stop_at_empty=false"
        let tail = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        do {
            try connection.execute("CREATE OR REPLACE TABLE excel_data AS SELECT * FROM \(reader), empty_as_varchar=true)\(tail)", retryOnOOM: true)
        } catch let error as EngineError where !error.outOfMemory {
            try connection.execute("CREATE OR REPLACE TABLE excel_data AS SELECT * FROM \(reader), all_varchar=true)\(tail)", retryOnOOM: true)
        }
        // Reading past blank rows keeps data below them, but formatted empty rows at the end of a
        // sheet would then show up as NULL rows. Drop those; rowids stay dense.
        let columns = try describe("excel_data")
        guard !columns.isEmpty else { return }
        let anyValue = columns.map { "\(Planner.identifier($0.name)) IS NOT NULL" }.joined(separator: " OR ")
        try connection.execute("DELETE FROM excel_data WHERE rowid > COALESCE((SELECT max(rowid) FROM excel_data WHERE \(anyValue)), -1)")
    }
    private func importSQLite(_ url: URL, table: String, limit: Int? = nil) throws {
        let db = try sqliteOpen(url); defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM \(Planner.identifier(table))\(limit.map { " LIMIT \(max(0,$0))" } ?? "")", -1, &statement, nil) == SQLITE_OK else { throw EngineError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let n = sqlite3_column_count(statement)
        let fields = (0..<n).map { i -> String in
            let name = String(cString: sqlite3_column_name(statement, i))
            let type = sqlite3_column_decltype(statement, i).map { String(cString: $0).uppercased() } ?? "TEXT"
            let mapped = type.contains("INT") ? "BIGINT" : (["REAL", "FLOAT", "DOUBLE", "NUMERIC", "DECIMAL"].contains(where: type.contains) ? "DOUBLE" : "VARCHAR")
            return Planner.identifier(name) + " " + mapped
        }
        try connection.execute("CREATE OR REPLACE TABLE sqlite_data (\(fields.joined(separator: ", ")))")
        try connection.execute("BEGIN")
        do {
            var batch: [[String?]] = []
            func flush() throws {
                guard !batch.isEmpty else { return }
                let row = "(" + Array(repeating: "?", count: Int(n)).joined(separator: ",") + ")"
                try connection.execute("INSERT INTO sqlite_data VALUES " + Array(repeating: row, count: batch.count).joined(separator: ","), batch.flatMap { $0 })
                batch.removeAll(keepingCapacity: true)
            }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                batch.append((0..<n).map { i in sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : sqlite3_column_text(statement, i).map { String(cString: $0) } })
                if batch.count == 256 { try flush() }; status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw EngineError(String(cString: sqlite3_errmsg(db))) }
            try flush(); try connection.execute("COMMIT")
        } catch { try? connection.execute("ROLLBACK"); throw error }
    }
}
