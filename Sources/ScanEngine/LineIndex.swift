import Foundation

/// The byte position of every non-blank line of a JSON Lines file.
///
/// One sequential pass over the file (about a second per few GB) is enough to page it: a page is
/// read by seeking straight to its lines, so opening and scrolling never parse the rest of the file.
struct LineIndex: Sendable {
    let url: URL
    private(set) var starts: [UInt64] = []
    private(set) var lengths: [UInt32] = []
    /// The longest line in bytes, newline excluded.
    private(set) var maxLength = 0
    var count: Int { starts.count }

    /// Indexes `url`. Blank lines are skipped, like DuckDB's newline-delimited reader does.
    /// Throws when the file cannot be read, or when a line is longer than 4 GB.
    init(url: URL, isCancelled: () -> Bool = { false }) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let chunkSize = 8 << 20
        var position: UInt64 = 0, lineStart: UInt64 = 0, hasContent = false
        func finishLine(at end: UInt64, into index: inout LineIndex) throws {
            if hasContent {
                let length = end - lineStart
                guard length <= UInt64(UInt32.max) else { throw EngineError("A line of this file is longer than 4 GB.") }
                index.starts.append(lineStart); index.lengths.append(UInt32(length))
                index.maxLength = max(index.maxLength, Int(length))
            }
        }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            if isCancelled() { throw CancellationError() }
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let bytes = raw.bindMemory(to: UInt8.self)
                var cursor = 0
                while cursor < bytes.count {
                    let remaining = bytes.count - cursor
                    let newline = memchr(bytes.baseAddress! + cursor, 0x0A, remaining)
                    let segmentEnd = newline.map { bytes.baseAddress!.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? bytes.count
                    if !hasContent {
                        var probe = cursor
                        while probe < segmentEnd { let byte = bytes[probe]; if byte != 0x20 && byte != 0x09 && byte != 0x0D { hasContent = true; break }; probe += 1 }
                    }
                    guard newline != nil else { break }
                    var end = position + UInt64(segmentEnd)
                    // A CRLF line ends before its carriage return.
                    if hasContent, segmentEnd > 0, bytes[segmentEnd - 1] == 0x0D { end -= 1 }
                    try finishLine(at: end, into: &self)
                    lineStart = position + UInt64(segmentEnd) + 1; hasContent = false
                    cursor = segmentEnd + 1
                }
                position += UInt64(bytes.count)
            }
        }
        // The last line may have no trailing newline.
        var end = position
        if hasContent, position > lineStart, let last = try? lastByte(of: handle, at: position - 1), last == 0x0D { end -= 1 }
        try finishLine(at: end, into: &self)
    }
    private func lastByte(of handle: FileHandle, at offset: UInt64) throws -> UInt8? {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: 1)?.first
    }
    /// The given rows, in the given order, as one newline-separated block.
    func read(rows: [Int]) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var output = Data()
        for row in rows where starts.indices.contains(row) {
            try handle.seek(toOffset: starts[row])
            guard let line = try handle.read(upToCount: Int(lengths[row])), line.count == Int(lengths[row]) else {
                throw EngineError("The file changed while it was being read. Reopen it.")
            }
            output.append(line); output.append(0x0A)
        }
        return output
    }
    /// A sample of the file for schema inference: its first rows plus rows spread evenly through the
    /// rest, so a key that appears only late in the file is still seen. Rows over `maxRowBytes` are
    /// left out, and the sample stops growing at `maxBytes`. Returns the number of rows written.
    func writeSample(to destination: URL, spread: Int = 6144, head: Int = 1024, maxRowBytes: Int = 4 << 20, maxBytes: Int = 64 << 20) throws -> Int {
        var rows = Set(0..<min(head, count))
        if count > head {
            let stride = max(1, (count - head) / max(1, spread))
            rows.formUnion(Swift.stride(from: head, to: count, by: stride))
        }
        let chosen = rows.sorted().filter { Int(lengths[$0]) <= maxRowBytes }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
        var written = 0, bytes = 0
        for row in chosen {
            guard bytes + Int(lengths[row]) <= maxBytes else { break }
            try handle.seek(toOffset: starts[row])
            guard let line = try handle.read(upToCount: Int(lengths[row])) else { continue }
            try output.write(contentsOf: line); try output.write(contentsOf: Data([0x0A]))
            written += 1; bytes += line.count + 1
        }
        return written
    }
}
