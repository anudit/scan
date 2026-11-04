import XCTest
import Foundation
import Network
@testable import ScanEngine
import ScanQuery

/// A tiny HTTP/1.1 server that serves one file with byte-range support, so the remote
/// Parquet reader can be tested without the network.
final class RangeServer: @unchecked Sendable {
    private let data: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.scan.tests.range-server")
    private let lock = NSLock()
    private var served: Int64 = 0
    private var requests = 0
    private(set) var port: UInt16 = 0

    var bytesServed: Int64 { lock.lock(); defer { lock.unlock() }; return served }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }

    init(fileURL: URL) throws {
        data = try Data(contentsOf: fileURL)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
        try start()
    }

    private func start() throws {
        let ready = DispatchSemaphore(value: 0)
        final class PortBox: @unchecked Sendable { let lock = NSLock(); var value: UInt16 = 0 }
        let assigned = PortBox()
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                assigned.lock.lock(); assigned.value = self.listener.port?.rawValue ?? 0; assigned.lock.unlock()
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "RangeServer", code: 1)
        }
        assigned.lock.lock(); port = assigned.value; assigned.lock.unlock()
        guard port != 0 else { throw NSError(domain: "RangeServer", code: 2) }
    }

    deinit { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, request: buffer[..<headerEnd.lowerBound])
                return
            }
            if complete || error != nil || buffer.count > (1 << 20) { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else { connection.cancel(); return }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = parts[0]
        var rangeStart = 0
        var rangeEnd = data.count - 1
        var partial = false
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, pieces[0].lowercased() == "range" else { continue }
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("bytes=") else { continue }
            let bounds = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if let start = Int(bounds[0]) { rangeStart = start; partial = true }
            else if bounds.count > 1, let suffix = Int(bounds[1]) {
                // A suffix range: the last `suffix` bytes.
                rangeStart = max(0, data.count - suffix); rangeEnd = data.count - 1; partial = true
            }
            if bounds.count > 1, !bounds[0].isEmpty, let end = Int(bounds[1]) { rangeEnd = end }
        }
        rangeStart = max(0, min(rangeStart, data.count))
        rangeEnd = max(rangeStart - 1, min(rangeEnd, data.count - 1))
        let body = method == "HEAD" ? Data() : data.subdata(in: rangeStart..<(rangeEnd + 1))
        lock.lock()
        requests += 1
        served += Int64(body.count)
        lock.unlock()
        var head = ""
        if partial && method != "HEAD" {
            head = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(rangeStart)-\(rangeEnd)/\(data.count)\r\n"
        } else {
            head = "HTTP/1.1 200 OK\r\n"
        }
        let contentLength = method == "HEAD" ? (partial ? rangeEnd - rangeStart + 1 : data.count) : body.count
        head += "Content-Length: \(contentLength)\r\nAccept-Ranges: bytes\r\nETag: \"test-file\"\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

@MainActor final class RemoteParquetTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Builds a local Parquet file with several row groups: id and name for 300,000 rows.
    private func fixture(in directory: URL) async throws -> URL {
        let csv = directory.appendingPathComponent("input.csv")
        var text = "id,name\n"
        text.reserveCapacity(300_000 * 16)
        for index in 0..<300_000 { text += "\(index),row \(index)\n" }
        try text.write(to: csv, atomically: true, encoding: .utf8)
        let engine = try Engine(memoryMB: 256, threads: 2)
        let info = try await engine.open(csv)
        var state = ViewState(); state.columns = info.columns
        let parquet = directory.appendingPathComponent("input.parquet")
        try await engine.export(to: parquet, state: state)
        return parquet
    }

    func testHuggingFaceBlobURLIsRewrittenToResolve() throws {
        let blob = URL(string: "https://huggingface.co/datasets/org/name/blob/main/file.parquet")!
        XCTAssertEqual(try RemoteParquet.normalizedURL(blob).absoluteString,
                       "https://huggingface.co/datasets/org/name/resolve/main/file.parquet")
        let resolve = URL(string: "https://huggingface.co/datasets/org/name/resolve/main/file.parquet")!
        XCTAssertEqual(try RemoteParquet.normalizedURL(resolve), resolve)
        let plain = URL(string: "http://huggingface.co/datasets/org/name/blob/main/file.parquet")!
        XCTAssertEqual(try RemoteParquet.normalizedURL(plain).absoluteString,
                       "https://huggingface.co/datasets/org/name/resolve/main/file.parquet")
        let short = URL(string: "https://hf.co/datasets/org/name/blob/main/file.parquet")!
        XCTAssertEqual(try RemoteParquet.normalizedURL(short).absoluteString,
                       "https://huggingface.co/datasets/org/name/resolve/main/file.parquet")
        XCTAssertThrowsError(try RemoteParquet.normalizedURL(URL(string: "file:///tmp/a.parquet")!))
        XCTAssertThrowsError(try RemoteParquet.normalizedURL(URL(string: "https://example.com/a.csv")!))
    }

    func testRemotePreviewStreamsRowGroupsAndReusesCache() async throws {
        let directory = try temporaryDirectory()
        let parquet = try await fixture(in: directory)
        let fullSize = (try FileManager.default.attributesOfItem(atPath: parquet.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fullSize, 0)

        let server = try RangeServer(fileURL: parquet)
        let url = URL(string: "http://127.0.0.1:\(server.port)/input.parquet")!
        let cache = directory.appendingPathComponent("cache")

        let engine = try Engine(memoryMB: 256, threads: 2, remoteCache: cache)
        let info = try await engine.open(url)
        XCTAssertTrue(info.isRemote)
        XCTAssertEqual(info.columns.map(\.name), ["id", "name"])
        var state = ViewState(); state.columns = info.columns
        let total = try await engine.apply(state, generation: 1)
        XCTAssertEqual(total, 300_000)
        // Opening only reads the footer.
        XCTAssertLessThan(server.bytesServed, fullSize / 4)

        let first = try await engine.preview(limit: 256)
        XCTAssertEqual(first.count, 256)
        XCTAssertEqual(first.columns[0].first, "0")
        XCTAssertLessThan(server.bytesServed, fullSize, "A preview must not download the whole file")

        // Typing a filter validates it against the schema, which is already available from the
        // footer, so validation must not fetch the remaining row groups.
        let beforeValidate = server.bytesServed
        try await engine.validate(filter: "id >= 1")
        XCTAssertEqual(server.bytesServed, beforeValidate, "Filter validation must not download row groups")

        // Jump past the first row group. Only groups 0 and 2 are present in the local view,
        // so this also checks the mapping from global rows to file_row_number.
        let deep = try await engine.page(offset: 250_000, generation: 1)
        XCTAssertEqual(deep.count, 256)
        XCTAssertEqual(deep.columns[0].first, "250000")
        let status = await engine.remoteStatus()
        XCTAssertEqual(status?.complete, false)
        let afterDeep = server.bytesServed
        XCTAssertLessThan(afterDeep, fullSize)

        // Filling the gap downloads the missing row group, not the whole file again.
        let middle = try await engine.page(offset: 125_000, generation: 1)
        XCTAssertEqual(middle.columns[0].first, "125000")

        // A filter must scan every row, so the rest of the file is downloaded first.
        var filtered = state; filtered.filter = "id >= 299998"
        let filteredCount = try await engine.apply(filtered, generation: 2)
        XCTAssertEqual(filteredCount, 2)
        let filteredPage = try await engine.page(offset: 0, generation: 2)
        XCTAssertEqual(filteredPage.columns[0], ["299998", "299999"])
        XCTAssertGreaterThanOrEqual(server.bytesServed, fullSize - 1024)
        let complete = await engine.remoteStatus()
        XCTAssertEqual(complete?.complete, true)

        // A new engine with the same URL reuses the cached sparse file.
        let before = server.bytesServed
        let reopened = try Engine(memoryMB: 256, threads: 2, remoteCache: cache)
        let reopenedInfo = try await reopened.open(url)
        var reopenedState = ViewState(); reopenedState.columns = reopenedInfo.columns
        let reopenedCount = try await reopened.apply(reopenedState, generation: 1)
        XCTAssertEqual(reopenedCount, 300_000)
        let cachedPage = try await reopened.page(offset: 250_000, generation: 1)
        XCTAssertEqual(cachedPage.columns[0].first, "250000")
        XCTAssertLessThan(server.bytesServed - before, 64, "Reopening a cached file only re-checks its size and validators")
    }

    func testOpenNeedsOneRequestAndSkipsUnreadColumns() async throws {
        let directory = try temporaryDirectory()
        let parquet = try await fixture(in: directory)
        let server = try RangeServer(fileURL: parquet)
        let url = URL(string: "http://127.0.0.1:\(server.port)/input.parquet")!
        let cache = directory.appendingPathComponent("cache")

        let remote = try await RemoteParquet.open(url: url, cacheRoot: cache)
        XCTAssertEqual(server.requestCount, 1, "Size, validators and footer come from one suffix-range request")
        XCTAssertEqual(remote.totalRows, 300_000)

        // Reading only `id` must not download `name`.
        _ = try await remote.ensureRows(0..<100, columns: ["id"])
        let idOnly = await remote.status().cachedBytes
        XCTAssertGreaterThan(idOnly, 0)
        _ = try await remote.ensureRows(0..<100, columns: ["name"])
        let both = await remote.status().cachedBytes
        XCTAssertGreaterThan(both, idOnly)
        XCTAssertEqual(server.requestCount, 3, "Each column chunk is one request")

        // Case-insensitive names resolve, and an unknown name falls back to every column.
        _ = try await remote.ensureRows(0..<100, columns: ["ID"])
        XCTAssertEqual(server.requestCount, 3)
        _ = try await remote.ensureRows(130_000..<130_010, columns: ["missing"])
        let sparse = await remote.status()
        XCTAssertFalse(sparse.complete)
        XCTAssertEqual(sparse.rowGroupsCached, 2)
    }

    func testPagesReadOnlyRequestedColumnsThroughEngine() async throws {
        let directory = try temporaryDirectory()
        let parquet = try await fixture(in: directory)
        let server = try RangeServer(fileURL: parquet)
        let url = URL(string: "http://127.0.0.1:\(server.port)/input.parquet")!
        let engine = try Engine(memoryMB: 256, threads: 2, remoteCache: directory.appendingPathComponent("cache"))
        let info = try await engine.open(url)
        var state = ViewState(); state.columns = info.columns
        _ = try await engine.apply(state, generation: 1)

        let ids = try await engine.page(offset: 200_000, generation: 1, only: ["id"])
        XCTAssertEqual(ids.columns[0].first, "200000")
        XCTAssertEqual(ids.columns[1], [])
        let idBytes = await engine.remoteStatus()?.cachedBytes ?? 0
        let full = try await engine.page(offset: 200_000, generation: 1)
        XCTAssertEqual(full.columns[1].first, "row 200000")
        let fullBytes = await engine.remoteStatus()?.cachedBytes ?? 0
        XCTAssertGreaterThan(fullBytes, idBytes)
        let cell = try await engine.cell(row: 200_001, column: "name", generation: 1)
        XCTAssertEqual(cell, "row 200001")
    }

    func testOverlappingRequestsShareOneDownload() async throws {
        let directory = try temporaryDirectory()
        let parquet = try await fixture(in: directory)
        let server = try RangeServer(fileURL: parquet)
        let url = URL(string: "http://127.0.0.1:\(server.port)/input.parquet")!
        let remote = try await RemoteParquet.open(url: url, cacheRoot: directory.appendingPathComponent("cache"))
        let before = server.requestCount
        async let a = remote.ensureRows(0..<50)
        async let b = remote.ensureRows(10..<60)
        async let c = remote.ensureRows(0..<256)
        let results = try await [a, b, c]
        XCTAssertEqual(results.map { $0.first?.count }, [50, 50, 256])
        // The neighbouring id and name chunks of the row group are fetched with a single request.
        XCTAssertEqual(server.requestCount - before, 1)
    }

    func testCacheSizeIncludesFilesInsideEachCachedDirectory() async throws {
        let directory = try temporaryDirectory()
        let parquet = try await fixture(in: directory)
        let server = try RangeServer(fileURL: parquet)
        let url = URL(string: "http://127.0.0.1:\(server.port)/input.parquet")!
        let cache = directory.appendingPathComponent("cache")
        let remote = try await RemoteParquet.open(url: url, cacheRoot: cache)
        _ = try await remote.ensureRows(0..<10, columns: ["id"])
        let cached = await remote.status().cachedBytes
        // A directory's own entry is tiny; the size has to come from the files inside it.
        XCTAssertGreaterThanOrEqual(RemoteParquet.cacheSize(root: cache), cached)
    }

    /// Live smoke test against a public Parquet URL, skipped unless SCAN_REMOTE_URL is set.
    /// Example: SCAN_REMOTE_URL='https://huggingface.co/…/0000.parquet' swift test --filter testLiveRemoteURL
    func testLiveRemoteURL() async throws {
        guard let raw = ProcessInfo.processInfo.environment["SCAN_REMOTE_URL"],
              let input = URL(string: raw) else {
            throw XCTSkip("Set SCAN_REMOTE_URL to a public Parquet URL.")
        }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-live-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let url = try RemoteParquet.normalizedURL(input)
        let engine = try Engine(memoryMB: 512, threads: 4, remoteCache: cache)
        let info = try await engine.open(url)
        XCTAssertTrue(info.isRemote)
        XCTAssertFalse(info.columns.isEmpty)
        var state = ViewState(); state.columns = info.columns
        let total = try await engine.apply(state, generation: 1)
        XCTAssertGreaterThan(total, 0)
        let first = try await engine.preview(limit: 10)
        XCTAssertGreaterThan(first.count, 0)
        let status = await engine.remoteStatus()
        XCTAssertNotNil(status)
        print("Remote OK: \(info.columns.count) columns, \(total) rows, \(status?.cachedBytes ?? 0)/\(status?.totalBytes ?? 0) bytes cached")
    }

    func testThriftCompactRoundTrip() throws {
        let original = ThriftStruct(fields: [
            (1, .i32(7)),
            (2, .binary(Data([1, 2, 3, 4]))),
            (3, .i64(1_234_567_890_123)),
            (4, .list(.structure, [
                .structure(ThriftStruct(fields: [
                    (1, .i64(42)),
                    (2, .list(.i32, [.i32(1), .i32(2), .i32(3)])),
                    (3, .bool(true)),
                ])),
            ])),
            (5, .binary(Data())),
            (20, .double(3.5)),
        ])
        var writer = ThriftCompactWriter()
        writer.write(original)
        var reader = ThriftCompactReader(Data(writer.bytes))
        let decoded = try reader.readStruct()
        XCTAssertEqual(decoded.int(1), 7)
        XCTAssertEqual(decoded.int(3), 1_234_567_890_123)
        XCTAssertEqual(decoded.value(2)?.binaryValue, Data([1, 2, 3, 4]))
        XCTAssertEqual(decoded.value(20)?.doubleValue, 3.5)
        let nested = decoded.value(4)?.listValue?.first?.structValue
        XCTAssertEqual(nested?.int(1), 42)
        XCTAssertEqual(nested?.value(2)?.listValue?.compactMap(\.intValue), [1, 2, 3])
        if case .bool(let value)? = nested?.value(3) { XCTAssertTrue(value) } else { XCTFail("Boolean did not survive") }
    }
}
