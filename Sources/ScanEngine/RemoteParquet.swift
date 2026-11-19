import CryptoKit
import Foundation

/// A snapshot of how much of a remote Parquet file has been downloaded.
public struct RemoteParquetStatus: Sendable {
    public var cachedBytes: Int64
    public var totalBytes: Int64
    public var rowGroupsCached: Int
    public var rowGroupsTotal: Int
    public var complete: Bool
}

/// Rows of a downloaded row group, addressed by DuckDB's `file_row_number`.
/// `fileRow` counts rows across the row groups currently present in the local view,
/// which differs from the original row number while only part of the file is cached.
public struct RemoteRowSegment: Sendable {
    public var fileRow: Int64
    public var count: Int
}

public enum RemoteParquetError: Error, LocalizedError, Sendable {
    case invalidURL
    case notParquet
    case authenticationRequired
    case accessDenied(CloudProvider, signed: Bool)
    case rangeUnsupported
    case http(Int, String)
    case malformed(String)
    case unsupported(String)
    case disk(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a complete HTTPS, s3://, gs:// or r2:// URL to a data file."
        case .notParquet: return "Remote preview supports Parquet files. The URL should end in .parquet."
        case .authenticationRequired: return "This Hugging Face repository is gated or private. Add an access token in Settings → Hugging Face, or set HF_TOKEN."
        case .accessDenied(let provider, let signed):
            let variables = switch provider {
            case .s3: "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
            case .gcs: "GCS_ACCESS_KEY_ID and GCS_SECRET_ACCESS_KEY (HMAC keys)"
            case .r2: "R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY"
            }
            return signed
                ? "\(provider.title) denied access to this object. Check that the keys in Settings → Cloud Storage can read it, that the object exists, and that the region is right."
                : "This \(provider.title) object is not public. Add keys in Settings → Cloud Storage, or set \(variables)."
        case .rangeUnsupported: return "This server does not support range requests, so the file cannot be previewed without downloading all of it."
        case .http(let code, let message): return "The server returned HTTP \(code)\(message.isEmpty ? "." : ": \(message)")"
        case .malformed(let message): return "This Parquet file could not be read: \(message)"
        case .unsupported(let message): return message
        case .disk(let message): return "Could not write the download cache: \(message)"
        }
    }
}

// MARK: - HTTP ranges

struct RemoteProbe: Sendable {
    var size: Int64
    var etag: String?
    var lastModified: String?
}

/// Collects the response of one ranged request. The session delegate fills it in on its serial
/// queue; the awaiting caller reads it after the request completes.
final class RangeSink: @unchecked Sendable {
    enum Target {
        /// Headers only. The body is not requested.
        case none
        /// The body is collected in memory, up to `limit` bytes.
        case memory(limit: Int)
        /// The body is written straight into an open file at `offset`, as it arrives.
        case file(fd: Int32, offset: Int64)
    }

    let target: Target
    /// Decides from the response headers whether the body should be received at all.
    let accept: @Sendable (HTTPURLResponse) -> Bool
    var response: HTTPURLResponse?
    var buffer = Data()
    var written: Int64 = 0
    var failure: Error?
    /// The body was declined by `accept`, so the response is only useful for its headers.
    var rejected = false

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    init(target: Target, accept: @escaping @Sendable (HTTPURLResponse) -> Bool = { _ in true }) {
        self.target = target
        self.accept = accept
    }

    /// Resumes the waiting caller, or remembers the result if the caller has not started waiting yet.
    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            outcome = result
            lock.unlock()
        }
    }

    func wait(_ next: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            next.resume(with: outcome)
        } else {
            continuation = next
            lock.unlock()
        }
    }
}

/// Session delegate for ranged requests. It streams every body into its `RangeSink`, and drops
/// the bearer token when a request is redirected to another host: Hugging Face redirects
/// /resolve/ URLs to a signed CDN host, and sending the token there would invalidate the request.
final class RangeSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: RangeSink] = [:]

    func register(_ task: URLSessionTask, _ sink: RangeSink) {
        lock.lock(); sinks[task.taskIdentifier] = sink; lock.unlock()
    }

    private func sink(for task: URLSessionTask) -> RangeSink? {
        lock.lock(); defer { lock.unlock() }
        return sinks[task.taskIdentifier]
    }

    private func remove(_ task: URLSessionTask) -> RangeSink? {
        lock.lock(); defer { lock.unlock() }
        return sinks.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if next.url?.host?.lowercased() != task.originalRequest?.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let sink = sink(for: dataTask) else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            sink.failure = RemoteParquetError.http(0, "The response was not HTTP.")
            completionHandler(.cancel)
            return
        }
        sink.response = http
        if sink.accept(http) {
            completionHandler(.allow)
        } else {
            sink.rejected = true
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let sink = sink(for: dataTask), sink.failure == nil else { return }
        switch sink.target {
        case .none:
            break
        case .memory(let limit):
            guard sink.buffer.count + data.count <= limit else {
                sink.failure = RemoteParquetError.malformed("The server returned more data than requested.")
                dataTask.cancel()
                return
            }
            sink.buffer.append(data)
            sink.written += Int64(data.count)
        case .file(let fd, let offset):
            do {
                try pwriteAll(fd, data, at: offset + sink.written)
                sink.written += Int64(data.count)
            } catch {
                sink.failure = error
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let sink = remove(task) else { return }
        if let failure = sink.failure {
            sink.finish(.failure(failure))
        } else if sink.rejected {
            sink.finish(.success(()))
        } else if let error {
            sink.finish(.failure((error as? URLError).map(HTTPRangeClient.map) ?? error))
        } else {
            sink.finish(.success(()))
        }
    }
}

/// Reads byte ranges from a remote file. Redirects are followed; the access token is only
/// sent to the original host, never to the signed CDN URL that Hugging Face redirects to.
final class HTTPRangeClient: @unchecked Sendable {
    private let endpoint: RemoteEndpoint
    private var url: URL { endpoint.url }
    private let delegate = RangeSessionDelegate()
    private let session: URLSession

    /// The Hugging Face token is only sent to Hugging Face hosts, and cloud requests are signed
    /// for their own endpoint, never for arbitrary servers.
    init(endpoint: RemoteEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        // Parallel row group downloads share the connection pool of this one session.
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Runs one request to completion. The caller owns `sink` and can inspect what arrived
    /// even when the request fails part way.
    private func run(_ request: URLRequest, sink: RangeSink) async throws {
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        delegate.register(task, sink)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.wait(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// One request that returns both the file size and its last bytes, which normally hold the
    /// whole Parquet footer. Returns nil when the server cannot answer a suffix range, so the
    /// caller can fall back to `probe()`.
    func probeWithTail(_ length: Int) async throws -> (probe: RemoteProbe, tail: Data)? {
        var request = makeRequest(method: "GET")
        request.setValue("bytes=-\(length)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let sink = RangeSink(target: .memory(limit: length), accept: { $0.statusCode == 206 })
        do { try await run(request, sink: sink) }
        catch is CancellationError { throw CancellationError() }
        catch let error as RemoteParquetError {
            if case .authenticationRequired = error { throw error }
            return nil
        } catch { return nil }
        guard let http = sink.response else { return nil }
        _ = try validate(http)
        guard http.statusCode == 206, !sink.rejected,
              let header = http.value(forHTTPHeaderField: "Content-Range"),
              let range = Self.contentRange(header), let total = range.total,
              Int64(sink.buffer.count) == Int64(range.span.count) else { return nil }
        return (RemoteProbe(size: total, etag: http.value(forHTTPHeaderField: "ETag"),
                            lastModified: http.value(forHTTPHeaderField: "Last-Modified")),
                sink.buffer)
    }

    func probe() async throws -> RemoteProbe {
        if let probe = try await probeWithHead() { return probe }
        return try await probeWithRange()
    }

    private func probeWithHead() async throws -> RemoteProbe? {
        var request = makeRequest(method: "HEAD")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let sink = RangeSink(target: .none)
        try await run(request, sink: sink)
        guard let response = sink.response else { return nil }
        let http = try validate(response)
        guard http.statusCode == 200 else { return nil }
        if let accept = http.value(forHTTPHeaderField: "Accept-Ranges"), accept.lowercased() == "none" {
            throw RemoteParquetError.rangeUnsupported
        }
        guard let length = contentLength(http) else { return nil }
        return RemoteProbe(size: length, etag: http.value(forHTTPHeaderField: "ETag"),
                           lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }

    private func probeWithRange() async throws -> RemoteProbe {
        var request = makeRequest(method: "GET")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Read only the response headers. The body is declined, so a server that ignores Range
        // and answers 200 never gets to send the whole file.
        let sink = RangeSink(target: .none, accept: { _ in false })
        try await run(request, sink: sink)
        guard let response = sink.response else { throw RemoteParquetError.http(0, "The server did not respond.") }
        let http = try validate(response)
        switch http.statusCode {
        case 206:
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = Self.totalLength(fromContentRange: range) else {
                throw RemoteParquetError.rangeUnsupported
            }
            return RemoteProbe(size: total, etag: http.value(forHTTPHeaderField: "ETag"),
                               lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        case 200:
            throw RemoteParquetError.rangeUnsupported
        default:
            throw RemoteParquetError.http(http.statusCode, "")
        }
    }

    /// Reads a byte range fully into memory. Used for the Parquet footer.
    func read(_ range: Range<Int64>) async throws -> Data {
        guard !range.isEmpty else { return Data() }
        var request = makeRequest(method: "GET")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let count = range.count
        let fromStart = range.lowerBound == 0
        // Some servers ignore Range. Only accept that if the whole (small) file was requested.
        let sink = RangeSink(target: .memory(limit: count), accept: {
            $0.statusCode == 206 || ($0.statusCode == 200 && fromStart && $0.expectedContentLength == Int64(count))
        })
        try await run(request, sink: sink)
        guard let response = sink.response else { throw RemoteParquetError.http(0, "The server did not respond.") }
        let http = try validate(response)
        switch http.statusCode {
        case 206:
            guard sink.buffer.count == count else {
                throw RemoteParquetError.malformed("The server returned a short byte range.")
            }
            return sink.buffer
        case 200:
            guard !sink.rejected, sink.buffer.count == count else { throw RemoteParquetError.rangeUnsupported }
            return sink.buffer
        case 416:
            throw RemoteParquetError.http(416, "The requested range is past the end of the file.")
        default:
            throw RemoteParquetError.http(http.statusCode, "")
        }
    }

    /// Downloads a byte range straight into an open file at the same offset, as the bytes arrive,
    /// so a large range never has to sit in memory or in a temporary file. A failed attempt keeps
    /// what it wrote and the retry asks only for the rest.
    func download(_ range: Range<Int64>, into fd: Int32) async throws {
        guard !range.isEmpty else { return }
        var cursor = range.lowerBound
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await downloadOnce(cursor..<range.upperBound, into: fd, written: &cursor)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard Self.isRetryable(error), attempt < 3 else { break }
                try await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }
        throw lastError ?? RemoteParquetError.http(0, "The download failed.")
    }

    /// `written` is the file position of the next byte to fetch; it advances by what was stored.
    private func downloadOnce(_ range: Range<Int64>, into fd: Int32, written cursor: inout Int64) async throws {
        var request = makeRequest(method: "GET")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let expected = Int64(range.count)
        let sink = RangeSink(target: .file(fd: fd, offset: range.lowerBound), accept: {
            $0.statusCode == 206 && ($0.expectedContentLength < 0 || $0.expectedContentLength == expected)
        })
        defer { cursor += sink.written }
        try await run(request, sink: sink)
        guard let response = sink.response else { throw RemoteParquetError.http(0, "The server did not respond.") }
        let http = try validate(response)
        switch http.statusCode {
        case 206:
            guard !sink.rejected else {
                throw RemoteParquetError.malformed("The server returned a different length than requested.")
            }
            guard sink.written == expected else {
                throw RemoteParquetError.malformed("The server returned \(sink.written) bytes instead of \(expected).")
            }
        case 200:
            throw RemoteParquetError.rangeUnsupported
        case 416:
            throw RemoteParquetError.http(416, "The requested range is past the end of the file.")
        default:
            throw RemoteParquetError.http(http.statusCode, "")
        }
    }

    private func makeRequest(method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Scan/1.0 (+https://github.com/anudit/scan)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        endpoint.authorize(&request)
        return request
    }

    private func validate(_ response: HTTPURLResponse) throws -> HTTPURLResponse {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw endpoint.accessError
        }
        return response
    }

    private func contentLength(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Length") else { return nil }
        return Int64(value)
    }

    /// Parses `bytes 100-199/1000`. The total is nil when the server sends `*`.
    static func contentRange(_ value: String) -> (span: Range<Int64>, total: Int64?)? {
        let pieces = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let sides = pieces[1].split(separator: "/", maxSplits: 1).map(String.init)
        guard sides.count == 2 else { return nil }
        let bounds = sides[0].split(separator: "-").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        guard bounds.count == 2, bounds[0] >= 0, bounds[1] >= bounds[0] else { return nil }
        return (bounds[0]..<(bounds[1] + 1), Int64(sides[1].trimmingCharacters(in: .whitespaces)))
    }

    static func totalLength(fromContentRange value: String) -> Int64? {
        // bytes 0-0/2147292183
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return total == "*" ? nil : Int64(total)
    }

    static func isRetryable(_ error: Error) -> Bool {
        if case let RemoteParquetError.http(code, _) = error { return code == 408 || code == 429 || (500..<600).contains(code) }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .dnsLookupFailed, .resourceUnavailable, .badServerResponse].contains(error.code)
        }
        return false
    }

    static func map(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled: return CancellationError()
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed:
            return RemoteParquetError.http(0, "The secure connection failed. \(error.localizedDescription)")
        default: return error
        }
    }
}

// MARK: - Parquet metadata

struct ParquetRowGroup: Sendable {
    var index: Int
    var numRows: Int64
    var startRow: Int64
    /// The byte range of each column chunk, in leaf-column order. A chunk of nested data
    /// (a struct or list) is one leaf per physical column.
    var chunks: [Range<Int64>]

    /// The span from the first column chunk to the end of the last one.
    var byteRange: Range<Int64> {
        let low = chunks.filter { !$0.isEmpty }.map(\.lowerBound).min() ?? 0
        let high = chunks.map(\.upperBound).max() ?? 0
        return low..<max(low, high)
    }
}

struct ParquetLayout: Sendable {
    var groups: [ParquetRowGroup]
    var rows: Int64
    /// The top-level column each leaf belongs to, so a query for column `a` can find its chunks.
    var leafNames: [String]
}

enum ParquetFooter {
    static func parse(_ root: ThriftStruct, fileSize: Int64) throws -> ParquetLayout {
        if root.value(8) != nil {
            throw RemoteParquetError.unsupported("Encrypted Parquet files are not supported.")
        }
        guard let rowGroups = root.value(4)?.listValue else {
            throw RemoteParquetError.malformed("The file has no row group list.")
        }
        var groups: [ParquetRowGroup] = []
        groups.reserveCapacity(rowGroups.count)
        var leafNames: [String] = []
        var start: Int64 = 0
        for (index, value) in rowGroups.enumerated() {
            guard let rowGroup = value.structValue else {
                throw RemoteParquetError.malformed("A row group is not a structure.")
            }
            guard let columns = rowGroup.value(1)?.listValue else {
                throw RemoteParquetError.malformed("Row group \(index) has no columns.")
            }
            let rows = rowGroup.int(3) ?? 0
            guard rows >= 0, rows <= Int64.max - start else {
                throw RemoteParquetError.malformed("Row group \(index) has an invalid row count.")
            }
            if index > 0, columns.count != leafNames.count {
                throw RemoteParquetError.malformed("Row group \(index) has a different number of columns.")
            }
            var chunks: [Range<Int64>] = []
            chunks.reserveCapacity(columns.count)
            var low: Int64?
            var high: Int64 = 0
            for columnValue in columns {
                guard let column = columnValue.structValue else {
                    throw RemoteParquetError.malformed("Row group \(index) has an invalid column chunk.")
                }
                if column.value(8) != nil || column.value(9) != nil {
                    throw RemoteParquetError.unsupported("Encrypted Parquet files are not supported.")
                }
                if let path = column.value(1)?.binaryValue, !path.isEmpty {
                    throw RemoteParquetError.unsupported("This Parquet file keeps column data in a separate file, which remote preview does not support.")
                }
                guard let metadata = column.value(3)?.structValue else {
                    throw RemoteParquetError.malformed("Row group \(index) has a column without metadata.")
                }
                guard let size = metadata.int(7), size >= 0 else {
                    throw RemoteParquetError.malformed("Row group \(index) has an invalid column size.")
                }
                let offsets = [metadata.int(9), metadata.int(10), metadata.int(11)]
                    .compactMap { $0 }
                    .filter { $0 > 0 }
                guard let chunkStart = offsets.min() else {
                    throw RemoteParquetError.malformed("Row group \(index) has a column without a data offset.")
                }
                guard size <= Int64.max - chunkStart, chunkStart + size <= fileSize else {
                    throw RemoteParquetError.malformed("Row group \(index) is out of bounds.")
                }
                if index == 0 {
                    let first = metadata.value(3)?.listValue?.first?.binaryValue
                    leafNames.append(first.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                }
                chunks.append(chunkStart..<(chunkStart + size))
                if size > 0 {
                    low = min(low ?? chunkStart, chunkStart)
                    high = max(high, chunkStart + size)
                }
            }
            guard let low, high > low, high <= fileSize else {
                throw RemoteParquetError.malformed("Row group \(index) lies outside the file.")
            }
            groups.append(ParquetRowGroup(index: index, numRows: rows, startRow: start, chunks: chunks))
            start += rows
        }
        return ParquetLayout(groups: groups, rows: start, leafNames: leafNames)
    }

    /// Builds a footer that describes only the downloaded row groups. Column data stays at its
    /// original offset, so only the metadata is rewritten; a sparse file can hold the result.
    /// A listed group may have only some of its columns downloaded; the others are never read
    /// because a query only touches the columns it projects.
    static func subset(_ root: ThriftStruct, groups: [ParquetRowGroup], present: Set<Int>) throws -> Data {
        guard let originalGroups = root.value(4)?.listValue else {
            throw RemoteParquetError.malformed("The file has no row group list.")
        }
        var kept: [ThriftValue] = []
        var rows: Int64 = 0
        for group in groups where present.contains(group.index) {
            guard originalGroups.indices.contains(group.index),
                  var rowGroup = originalGroups[group.index].structValue else {
                throw RemoteParquetError.malformed("A cached row group is missing from the footer.")
            }
            if let columns = rowGroup.value(1)?.listValue {
                var cleaned: [ThriftValue] = []
                cleaned.reserveCapacity(columns.count)
                for columnValue in columns {
                    guard var column = columnValue.structValue else {
                        throw RemoteParquetError.malformed("A cached column chunk is invalid.")
                    }
                    // Page indexes and bloom filters live at other offsets that were not fetched.
                    // Dropping them makes DuckDB read pages sequentially, which is still correct.
                    column.remove(1) // file_path
                    column.remove(4); column.remove(5); column.remove(6); column.remove(7)
                    if var metadata = column.value(3)?.structValue {
                        metadata.remove(10) // index_page_offset
                        metadata.remove(14); metadata.remove(15) // bloom filter
                        column.set(3, .structure(metadata))
                    }
                    cleaned.append(.structure(column))
                }
                rowGroup.set(1, .list(.structure, cleaned))
            }
            kept.append(.structure(rowGroup))
            rows += group.numRows
        }
        var result = root
        result.remove(9) // footer signature is no longer valid
        result.set(3, .i64(rows))
        result.set(4, .list(.structure, kept))
        var writer = ThriftCompactWriter()
        writer.write(result)
        return Data(writer.bytes)
    }
}

// MARK: - Cache manifest

struct RemoteCacheManifest: Codable, Sendable {
    static let currentVersion = 2

    /// A row group with only some of its columns downloaded.
    struct PartialGroup: Codable, Sendable {
        var group: Int
        var leaves: [Int]
    }

    var version = RemoteCacheManifest.currentVersion
    var url: String
    var etag: String?
    var lastModified: String?
    var size: Int64
    var footerLength: Int
    /// Row groups whose every column is downloaded.
    var complete: [Int]
    var partial: [PartialGroup]
    var lastAccess: Date

    static func load(_ url: URL) -> RemoteCacheManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let manifest = try? decoder.decode(RemoteCacheManifest.self, from: data),
              manifest.version == currentVersion else { return nil }
        return manifest
    }

    func save(_ url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Remote file

/// One column chunk of one row group.
struct ChunkKey: Hashable, Sendable {
    var group: Int32
    var leaf: Int32
}

/// One HTTP request that covers one or more neighbouring column chunks.
struct DownloadJob: Sendable {
    var range: Range<Int64>
    var keys: [ChunkKey]
}

/// A remote Parquet file backed by a sparse local cache. Downloaded column chunks are written
/// into the cache at their original offsets, and the footer is rewritten to describe only
/// the row groups that have data, so DuckDB reads a small, valid Parquet file without a full
/// download. A page that shows two columns of a wide table downloads only those two columns.
public actor RemoteParquet {
    public nonisolated let dataURL: URL
    public nonisolated let totalRows: Int64
    public nonisolated let totalBytes: Int64
    public nonisolated let originURL: URL
    public nonisolated let cacheDirectory: URL

    /// Bytes requested from the end of the file on open. This covers the footer of most files.
    static let footerPrefetchBytes = 128 << 10
    /// Parallel HTTP requests for column data.
    static let maxConcurrentDownloads = 6
    /// Chunks closer together than this are fetched with one request.
    static let coalesceGap: Int64 = 256 << 10
    /// A merged request never grows past this, so large downloads still run in parallel.
    static let maxRequestBytes: Int64 = 32 << 20
    /// Read-ahead for sequential scrolling is skipped when it would fetch more than this.
    static let prefetchLimitBytes: Int64 = 32 << 20

    private nonisolated let fd: Int32
    private let client: HTTPRangeClient
    private let manifestURL: URL
    /// The raw footer. The parsed tree is large for wide files, so it is dropped after the
    /// layout is read and parsed again only when the cache footer is rewritten.
    private let footerData: Data
    private let groups: [ParquetRowGroup]
    private let leafCount: Int
    private let columnLeaves: [String: [Int]]
    private let columnLeavesFolded: [String: [Int]]
    /// How many column chunks with data each row group has.
    private let groupTotals: [Int]
    private let totalChunks: Int

    private var present: Set<ChunkKey> = []
    private var groupCounts: [Int]
    private var touchedGroups = 0
    private var cachedBytes: Int64 = 0
    private var inFlight: [ChunkKey: Task<Void, Error>] = [:]
    private var manifest: RemoteCacheManifest
    private var manifestDirty = false
    private var lastManifestSave = ContinuousClock.now
    private var footerDirty = false
    private var generation = 0
    private var lastRequestedGroup: Int?
    private var activeDownloads = 0
    private var downloadWaiters: [CheckedContinuation<Void, Never>] = []

    public var revision: Int { generation }

    private init(dataURL: URL, cacheDirectory: URL, fd: Int32, totalBytes: Int64, totalRows: Int64,
                 originURL: URL, client: HTTPRangeClient, manifestURL: URL, manifest: RemoteCacheManifest,
                 footerData: Data, layout: ParquetLayout, present restored: Set<ChunkKey>) {
        self.dataURL = dataURL
        self.cacheDirectory = cacheDirectory
        self.fd = fd
        self.totalBytes = totalBytes
        self.totalRows = totalRows
        self.originURL = originURL
        self.client = client
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.footerData = footerData
        self.groups = layout.groups
        self.leafCount = layout.leafNames.count
        var leaves: [String: [Int]] = [:]
        var folded: [String: [Int]] = [:]
        for (leaf, name) in layout.leafNames.enumerated() {
            leaves[name, default: []].append(leaf)
            folded[name.lowercased(), default: []].append(leaf)
        }
        self.columnLeaves = leaves
        self.columnLeavesFolded = folded
        self.groupTotals = layout.groups.map { $0.chunks.filter { !$0.isEmpty }.count }
        self.totalChunks = groupTotals.reduce(0, +)
        self.groupCounts = Array(repeating: 0, count: layout.groups.count)
        for key in restored {
            let size = layout.groups[Int(key.group)].chunks[Int(key.leaf)].count
            present.insert(key)
            cachedBytes += Int64(size)
            groupCounts[Int(key.group)] += 1
            if groupCounts[Int(key.group)] == 1 { touchedGroups += 1 }
        }
    }

    deinit { close(fd) }

    public static func open(url: URL, cacheRoot: URL? = nil) async throws -> RemoteParquet {
        let origin = try normalizedURL(url)
        let root = cacheRoot ?? defaultCacheDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let directory = root.appendingPathComponent(cacheKey(origin), isDirectory: true)
        let dataURL = directory.appendingPathComponent("data.parquet")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let footerURL = directory.appendingPathComponent("footer.bin")

        let cached = RemoteCacheManifest.load(manifestURL)
        let client = HTTPRangeClient(endpoint: try await RemoteEndpoint.resolve(origin))

        // One request returns the file size, its validators and, normally, the whole footer. A
        // cached footer only needs the size and validators, so it asks for just the trailer.
        var probe: RemoteProbe?
        var tail: Data?
        var probeError: Error?
        let tailLength = (cached?.footerLength ?? 0) > 0 ? 8 : footerPrefetchBytes
        do {
            if let result = try await client.probeWithTail(tailLength) {
                probe = result.probe
                tail = result.tail
            } else {
                probe = try await client.probe()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch { probeError = error }

        var manifest = cached
        if let current = manifest, let probe,
           current.size != probe.size || (current.etag != nil && current.etag != probe.etag) {
            manifest = nil
        }
        if manifest == nil {
            try? FileManager.default.removeItem(at: directory)
        }
        if manifest == nil, probe == nil, let probeError { throw probeError }
        if manifest == nil, let probe {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            manifest = RemoteCacheManifest(url: origin.absoluteString, etag: probe.etag,
                                           lastModified: probe.lastModified, size: probe.size,
                                           footerLength: 0, complete: [], partial: [], lastAccess: Date())
        }
        guard var manifest else { throw RemoteParquetError.invalidURL }

        // Re-read the footer only when it is missing; it is tiny compared with the data.
        let footerData: Data
        if manifest.footerLength > 0, let stored = try? Data(contentsOf: footerURL), stored.count == manifest.footerLength {
            footerData = stored
        } else {
            footerData = try await readFooter(client: client, size: manifest.size, tail: tail)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try footerData.write(to: footerURL, options: .atomic)
            manifest.footerLength = footerData.count
        }
        var reader = ThriftCompactReader(footerData)
        let footer = try reader.readStruct()
        let layout = try ParquetFooter.parse(footer, fileSize: manifest.size)

        let existed = FileManager.default.fileExists(atPath: dataURL.path)
        let fd = Darwin.open(dataURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw RemoteParquetError.disk(String(cString: strerror(errno)))
        }
        var restored = Set<ChunkKey>()
        if existed {
            restored = restoredChunks(manifest, layout: layout)
        } else {
            guard ftruncate(fd, off_t(manifest.size)) == 0 else {
                close(fd)
                throw RemoteParquetError.disk(String(cString: strerror(errno)))
            }
        }

        // Make the cache file a valid Parquet file even before any row group is downloaded,
        // so DuckDB can provide the schema immediately.
        let included = Set(Dictionary(grouping: restored, by: { Int($0.group) }).keys)
        let initial = try ParquetFooter.subset(footer, groups: layout.groups, present: included)
        try writeFooter(fd: fd, size: manifest.size, payload: initial)

        manifest.lastAccess = Date()
        manifest.save(manifestURL)

        // Pruning walks every cached file, so it stays off the path that opens the document.
        Task.detached(priority: .utility) { RemoteParquet.pruneCache(root: root, keeping: directory) }

        return RemoteParquet(dataURL: dataURL, cacheDirectory: directory, fd: fd,
                             totalBytes: manifest.size, totalRows: layout.rows, originURL: origin,
                             client: client, manifestURL: manifestURL, manifest: manifest,
                             footerData: footerData, layout: layout, present: restored)
    }

    private static func restoredChunks(_ manifest: RemoteCacheManifest, layout: ParquetLayout) -> Set<ChunkKey> {
        var result = Set<ChunkKey>()
        for index in manifest.complete where layout.groups.indices.contains(index) {
            for (leaf, range) in layout.groups[index].chunks.enumerated() where !range.isEmpty {
                result.insert(ChunkKey(group: Int32(index), leaf: Int32(leaf)))
            }
        }
        for entry in manifest.partial where layout.groups.indices.contains(entry.group) {
            let chunks = layout.groups[entry.group].chunks
            for leaf in entry.leaves where chunks.indices.contains(leaf) && !chunks[leaf].isEmpty {
                result.insert(ChunkKey(group: Int32(entry.group), leaf: Int32(leaf)))
            }
        }
        return result
    }

    /// Reads the footer, using the bytes already fetched from the end of the file when they
    /// cover it, so a normal open needs no further request.
    private static func readFooter(client: HTTPRangeClient, size: Int64, tail: Data?) async throws -> Data {
        guard size >= 12 else { throw RemoteParquetError.malformed("The file is too small to be Parquet.") }
        let trailer: Data
        if let tail, tail.count >= 8 {
            trailer = Data(tail.suffix(8))
        } else {
            trailer = try await client.read((size - 8)..<size)
        }
        guard trailer.count == 8, trailer[4] == 0x50, trailer[5] == 0x41, trailer[6] == 0x52, trailer[7] == 0x31 else {
            throw RemoteParquetError.notParquet
        }
        let length = Int(trailer[0]) | Int(trailer[1]) << 8 | Int(trailer[2]) << 16 | Int(trailer[3]) << 24
        guard length > 0, Int64(length) <= size - 12 else {
            throw RemoteParquetError.malformed("The footer length is invalid.")
        }
        if let tail, tail.count >= length + 8 {
            return Data(tail[(tail.count - 8 - length)..<(tail.count - 8)])
        }
        return try await client.read((size - 8 - Int64(length))..<(size - 8))
    }

    private static func writeFooter(fd: Int32, size: Int64, payload: Data) throws {
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw RemoteParquetError.disk(String(cString: strerror(errno)))
        }
        try pwriteAll(fd, payload, at: size)
        var trailer = Data(capacity: 8)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { trailer.append(contentsOf: $0) }
        trailer.append(contentsOf: [0x50, 0x41, 0x52, 0x31])
        try pwriteAll(fd, trailer, at: size + Int64(payload.count))
    }

    // MARK: Paging

    /// Downloads the columns of the row groups that cover `rows`, then returns the ranges to
    /// query by `file_row_number`. `columns` names the columns the caller will read; nil means
    /// all of them. Groups are addressed in the original file order.
    public func ensureRows(_ rows: Range<Int>, columns: Set<String>? = nil) async throws -> [RemoteRowSegment] {
        let clamped = rows.clamped(to: 0..<Int(totalRows))
        guard !clamped.isEmpty else { return [] }
        let lower = Int64(clamped.lowerBound)
        let upper = Int64(clamped.upperBound)
        let needed = groups.filter { $0.startRow < upper && $0.startRow + $0.numRows > lower }.map(\.index)
        let leaves = leafIndices(for: columns)
        try await fetch(chunkKeys(groups: needed, leaves: leaves))
        if footerDirty { try flushFooter() }
        if let first = needed.first, let last = needed.last {
            // Scrolling forward through the file: fetch the next row group while the user reads this one.
            if let previous = lastRequestedGroup, first == previous || first == previous + 1 {
                prefetch(group: last + 1, leaves: leaves)
            }
            lastRequestedGroup = last
        }
        return segments(for: clamped)
    }

    /// Downloads every column of every row group. Used before a filter, sort, pivot, export or
    /// aggregate, all of which need to read the whole file.
    public func ensureAll() async throws {
        let all = Array(0..<leafCount)
        try await fetch(chunkKeys(groups: groups.map(\.index), leaves: all))
        if footerDirty { try flushFooter() }
    }

    public func status() -> RemoteParquetStatus {
        RemoteParquetStatus(cachedBytes: cachedBytes, totalBytes: totalBytes,
                            rowGroupsCached: touchedGroups, rowGroupsTotal: groups.count,
                            complete: isComplete)
    }

    public var isComplete: Bool { present.count == totalChunks }

    private func leafIndices(for columns: Set<String>?) -> [Int] {
        let all = Array(0..<leafCount)
        guard let columns else { return all }
        var result = Set<Int>()
        for name in columns {
            guard let leaves = columnLeaves[name] ?? columnLeavesFolded[name.lowercased()] else { return all }
            result.formUnion(leaves)
        }
        return result.sorted()
    }

    private func chunkKeys(groups indices: [Int], leaves: [Int]) -> [ChunkKey] {
        var result: [ChunkKey] = []
        for index in indices where groups.indices.contains(index) {
            let chunks = groups[index].chunks
            var found = false
            for leaf in leaves where chunks.indices.contains(leaf) && !chunks[leaf].isEmpty {
                result.append(ChunkKey(group: Int32(index), leaf: Int32(leaf)))
                found = true
            }
            // A row group is only readable once it has at least one chunk in the cache.
            if !found, groupCounts[index] == 0, let leaf = chunks.firstIndex(where: { !$0.isEmpty }) {
                result.append(ChunkKey(group: Int32(index), leaf: Int32(leaf)))
            }
        }
        return result
    }

    private func range(of key: ChunkKey) -> Range<Int64> {
        groups[Int(key.group)].chunks[Int(key.leaf)]
    }

    private func segments(for rows: Range<Int>) -> [RemoteRowSegment] {
        var fileStarts: [Int: Int64] = [:]
        var offset: Int64 = 0
        for group in groups where groupCounts[group.index] > 0 {
            fileStarts[group.index] = offset
            offset += group.numRows
        }
        let lower = Int64(rows.lowerBound)
        let upper = Int64(rows.upperBound)
        var result: [RemoteRowSegment] = []
        for group in groups {
            guard groupCounts[group.index] > 0 else { continue }
            let groupEnd = group.startRow + group.numRows
            if groupEnd <= lower { continue }
            if group.startRow >= upper { break }
            let start = max(lower, group.startRow)
            let end = min(upper, groupEnd)
            guard end > start, let fileStart = fileStarts[group.index] else { continue }
            result.append(RemoteRowSegment(fileRow: fileStart + (start - group.startRow), count: Int(end - start)))
        }
        return result
    }

    // MARK: Downloads

    /// Makes sure every chunk in `keys` is in the cache. A chunk that another caller is already
    /// downloading is awaited rather than requested again, so overlapping page requests while
    /// scrolling share their downloads.
    private func fetch(_ keys: [ChunkKey]) async throws {
        defer { saveManifestIfNeeded(force: true) }
        while true {
            try Task.checkCancellation()
            var waiting: [Task<Void, Error>] = []
            var fresh: [ChunkKey] = []
            for key in keys where !present.contains(key) && !range(of: key).isEmpty {
                if let task = inFlight[key] { waiting.append(task) } else { fresh.append(key) }
            }
            if waiting.isEmpty && fresh.isEmpty { return }

            var created: [Task<Void, Error>] = []
            for job in plan(fresh) {
                let task = Task { try await self.run(job) }
                for key in job.keys { inFlight[key] = task }
                created.append(task)
            }
            let owned = created
            let all = waiting + created
            do {
                try await withTaskCancellationHandler {
                    for task in all { try await task.value }
                } onCancel: {
                    owned.forEach { $0.cancel() }
                }
            } catch is CancellationError {
                if Task.isCancelled { throw CancellationError() }
                // Another caller cancelled a download this one was waiting for. Ask again.
            } catch {
                owned.forEach { $0.cancel() }
                throw error
            }
        }
    }

    /// Groups neighbouring chunks into as few requests as is reasonable.
    private func plan(_ keys: [ChunkKey]) -> [DownloadJob] {
        let sorted = keys.map { (key: $0, range: range(of: $0)) }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var jobs: [DownloadJob] = []
        var current: DownloadJob?
        for item in sorted {
            if var job = current,
               item.range.lowerBound - job.range.upperBound <= Self.coalesceGap,
               max(job.range.upperBound, item.range.upperBound) - job.range.lowerBound <= Self.maxRequestBytes {
                job.range = job.range.lowerBound..<max(job.range.upperBound, item.range.upperBound)
                job.keys.append(item.key)
                current = job
            } else {
                if let job = current { jobs.append(job) }
                current = DownloadJob(range: item.range, keys: [item.key])
            }
        }
        if let job = current { jobs.append(job) }
        return jobs
    }

    private func run(_ job: DownloadJob) async throws {
        defer { for key in job.keys { inFlight[key] = nil } }
        await acquireDownloadSlot()
        defer { releaseDownloadSlot() }
        try Task.checkCancellation()
        try await client.download(job.range, into: fd)
        for key in job.keys { markPresent(key) }
        saveManifestIfNeeded(force: false)
    }

    private func acquireDownloadSlot() async {
        if activeDownloads < Self.maxConcurrentDownloads {
            activeDownloads += 1
        } else {
            await withCheckedContinuation { downloadWaiters.append($0) }
        }
    }

    /// Hands the slot straight to the next waiter, or frees it.
    private func releaseDownloadSlot() {
        if downloadWaiters.isEmpty { activeDownloads -= 1 } else { downloadWaiters.removeFirst().resume() }
    }

    private func markPresent(_ key: ChunkKey) {
        guard present.insert(key).inserted else { return }
        let index = Int(key.group)
        cachedBytes += Int64(range(of: key).count)
        groupCounts[index] += 1
        if groupCounts[index] == 1 {
            // The first chunk of a row group adds the group to the footer.
            touchedGroups += 1
            footerDirty = true
        }
        manifestDirty = true
    }

    private func prefetch(group: Int, leaves: [Int]) {
        guard groups.indices.contains(group) else { return }
        let keys = chunkKeys(groups: [group], leaves: leaves)
            .filter { !present.contains($0) && inFlight[$0] == nil && !range(of: $0).isEmpty }
        let bytes = keys.reduce(Int64(0)) { $0 + Int64(range(of: $1).count) }
        guard !keys.isEmpty, bytes <= Self.prefetchLimitBytes else { return }
        Task(priority: .utility) { [weak self] in try? await self?.fetch(keys) }
    }

    private func saveManifestIfNeeded(force: Bool) {
        guard manifestDirty else { return }
        let now = ContinuousClock.now
        if !force, now - lastManifestSave < .seconds(2) { return }
        var perGroup: [Int: [Int]] = [:]
        for key in present { perGroup[Int(key.group), default: []].append(Int(key.leaf)) }
        var complete: [Int] = []
        var partial: [RemoteCacheManifest.PartialGroup] = []
        for (index, leaves) in perGroup.sorted(by: { $0.key < $1.key }) {
            if leaves.count == groupTotals[index] { complete.append(index) }
            else { partial.append(.init(group: index, leaves: leaves.sorted())) }
        }
        manifest.complete = complete
        manifest.partial = partial
        manifest.lastAccess = Date()
        manifest.save(manifestURL)
        manifestDirty = false
        lastManifestSave = now
    }

    private func flushFooter() throws {
        var reader = ThriftCompactReader(footerData)
        let root = try reader.readStruct()
        let included = Set(groups.indices.filter { groupCounts[$0] > 0 })
        let payload = try ParquetFooter.subset(root, groups: groups, present: included)
        try Self.writeFooter(fd: fd, size: totalBytes, payload: payload)
        footerDirty = false
        // The view over the cache file must be rebuilt only when the footer actually changed.
        generation += 1
    }

    // MARK: Cache management

    public static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("dev.scan.app/RemoteParquet", isDirectory: true)
    }

    private static let cacheLimitBytes: Int64 = 5 << 30

    public static func cacheSize(root: URL? = nil) -> Int64 {
        allocatedSize(of: root ?? defaultCacheDirectory())
    }

    @discardableResult
    public static func clearCache() -> Bool {
        let root = defaultCacheDirectory()
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        return (try? FileManager.default.removeItem(at: root)) != nil
    }

    fileprivate static func pruneCache(root: URL, keeping current: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        var items: [(url: URL, size: Int64, access: Date)] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let manifest = RemoteCacheManifest.load(entry.appendingPathComponent("manifest.json"))
            items.append((entry, allocatedSize(of: entry), manifest?.lastAccess ?? .distantPast))
        }
        var total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total > cacheLimitBytes else { return }
        let keep = current.standardizedFileURL.path
        for item in items.sorted(by: { $0.access < $1.access }) {
            guard total > cacheLimitBytes else { break }
            guard item.url.standardizedFileURL.path != keep else { continue }
            if (try? FileManager.default.removeItem(at: item.url)) != nil { total -= item.size }
        }
    }

    /// Disk space a file or a whole directory tree occupies. A sparse cache file counts only
    /// the blocks that were written, not its apparent length.
    fileprivate static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        func size(_ item: URL) -> (bytes: Int64, directory: Bool) {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return (0, false) }
            return (Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0), values.isDirectory == true)
        }
        let root = size(url)
        guard root.directory else { return root.bytes }
        var total = root.bytes
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return total }
        for case let item as URL in walker { total += size(item).bytes }
        return total
    }

    /// Normalizes a Parquet URL. Other remote files go through `RemoteFile.normalizedURL`.
    public static func normalizedURL(_ url: URL) throws -> URL {
        let result = try RemoteFile.normalizedURL(url)
        guard result.pathExtension.lowercased() == "parquet" else { throw RemoteParquetError.notParquet }
        return result
    }

    fileprivate static func normalizedAnyURL(_ url: URL) throws -> URL {
        if let provider = CloudProvider.provider(scheme: url.scheme) {
            // One canonical form per object, so the cache key does not depend on how it was typed.
            let object = try CloudObject(url)
            guard let result = URL(string: "\(provider.scheme)://\(SigV4Signer.encode(object.bucket))/\(SigV4Signer.encode(object.key, keepSlash: true))") else {
                throw RemoteParquetError.invalidURL
            }
            return result
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host != nil else {
            throw RemoteParquetError.invalidURL
        }
        components.fragment = nil
        let host = components.host?.lowercased() ?? ""
        if host == "huggingface.co" || host == "www.huggingface.co" || host == "hf.co" {
            // Never send a token over plain HTTP, and use one canonical host so redirects and
            // cache keys are stable.
            if components.scheme?.lowercased() == "http" { components.scheme = "https" }
            if host != "huggingface.co" { components.host = "huggingface.co" }
            // The URL shown in a browser is a /blob/ page (HTML). The file is served from /resolve/.
            var parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if let blob = parts.firstIndex(of: "blob") {
                parts[blob] = "resolve"
                components.path = parts.joined(separator: "/")
            }
        }
        guard let result = components.url else { throw RemoteParquetError.invalidURL }
        return result
    }

    fileprivate static func cacheKey(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Whole-file downloads

/// Downloads remote files that cannot be read by range, such as CSV or JSON Lines, into the
/// remote cache. They are fetched again on every open, so a changed file is never stale.
public enum RemoteFile {
    /// Whether a URL names a remote file Scan can open: HTTP(S), or an s3://, gs:// or r2:// object.
    public static func isRemote(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https" || CloudProvider.provider(scheme: scheme) != nil
    }

    /// Normalizes an HTTPS URL to any file Scan can open, rewriting Hugging Face /blob/ links.
    public static func normalizedURL(_ url: URL) throws -> URL {
        let result = try RemoteParquet.normalizedAnyURL(url)
        let name = result.lastPathComponent
        guard result.pathExtension.lowercased() == "parquet" || FileKind.guess(name: name) != nil else {
            throw RemoteParquetError.unsupported("Scan cannot open .\(result.pathExtension) files from a URL. Open Parquet, CSV, TSV, JSON, JSONL, GeoJSON, Excel, SQLite or DuckDB files.")
        }
        return result
    }

    /// Downloads the whole file and returns its local copy, which keeps the original file name.
    static func download(_ url: URL, cacheRoot: URL?) async throws -> URL {
        let origin = try normalizedURL(url)
        let root = cacheRoot ?? RemoteParquet.defaultCacheDirectory()
        let directory = root.appendingPathComponent(RemoteParquet.cacheKey(origin), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(origin.lastPathComponent)
        let endpoint = try await RemoteEndpoint.resolve(origin)
        var request = URLRequest(url: endpoint.url)
        request.setValue("Scan/1.0 (+https://github.com/anudit/scan)", forHTTPHeaderField: "User-Agent")
        endpoint.authorize(&request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: StripAuthorizationOnRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let downloaded: URL, response: URLResponse
        do { (downloaded, response) = try await session.download(for: request) }
        catch let error as URLError { throw HTTPRangeClient.map(error) }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let http = response as? HTTPURLResponse else { throw RemoteParquetError.http(0, "The response was not HTTP.") }
        if http.statusCode == 401 || http.statusCode == 403 { throw endpoint.accessError }
        guard (200..<300).contains(http.statusCode) else { throw RemoteParquetError.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode)) }
        try? FileManager.default.removeItem(at: target)
        do { try FileManager.default.moveItem(at: downloaded, to: target) }
        catch { throw RemoteParquetError.disk(error.localizedDescription) }
        RemoteParquet.pruneCache(root: root, keeping: directory)
        return target
    }

    /// The token goes only to the host it was meant for, never to a redirect target such as a CDN.
    private final class StripAuthorizationOnRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var next = request
            if next.url?.host?.lowercased() != task.originalRequest?.url?.host?.lowercased() {
                next.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(next)
        }
    }
}

// MARK: - File helpers

private func pwriteAll(_ fd: Int32, _ data: Data, at offset: Int64) throws {
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var written = 0
        while written < buffer.count {
            let result = pwrite(fd, base.advanced(by: written), buffer.count - written,
                                off_t(offset) + off_t(written))
            if result < 0 {
                if errno == EINTR { continue }
                throw RemoteParquetError.disk(String(cString: strerror(errno)))
            }
            guard result > 0 else { throw RemoteParquetError.disk("The file accepted no bytes.") }
            written += result
        }
    }
}
