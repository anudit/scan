import XCTest
import Foundation
import ScanQuery
@testable import ScanEngine

final class ProfileCloudTests: XCTestCase {
    private func open(_ text: String) async throws -> (Engine, ViewState) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("data.csv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let engine = try Engine(memoryMB: 128, threads: 2)
        let info = try await engine.open(url)
        if info.needsImport { try await engine.materialize() }
        var state = ViewState(); state.columns = info.columns
        _ = try await engine.apply(state, generation: 1)
        return (engine, state)
    }

    func testProfileOfNumbersAndText() async throws {
        let (engine, _) = try await open("n,s\n1,a\n2,a\n3,b\n4,\n,a\n10,c\n")
        let numbers = try await engine.profile(column: "n", generation: 1, bins: 3)
        XCTAssertEqual(numbers.rows, 6)
        XCTAssertEqual(numbers.nulls, 1)
        XCTAssertEqual(numbers.distinct, 5)
        XCTAssertEqual(numbers.minimum, "1"); XCTAssertEqual(numbers.maximum, "10")
        XCTAssertEqual(numbers.mean ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(numbers.bins, [3, 1, 1])
        XCTAssertEqual(numbers.binRange, 1...10)
        let text = try await engine.profile(column: "s", generation: 1)
        XCTAssertEqual(text.top.first, ValueCount(value: "a", count: 3))
        XCTAssertTrue(text.top.contains(ValueCount(value: nil, count: 1)))
        XCTAssertTrue(text.bins.isEmpty)
        let facets = try await engine.topValues(column: "s", limit: 2, generation: 1)
        XCTAssertEqual(facets.count, 2)
        let lines = try await engine.sparklines(columns: ["n", "s"], bins: 3, generation: 1)
        XCTAssertEqual(lines, ["n": [3, 1, 1]])
    }

    func testValueFiltersRoundTrip() async throws {
        var (engine, state) = try await open("n,s,d\n1.5,it's,2024-01-02\n2,b,2024-03-04\n,b,\n")
        func count(_ filter: String) async throws -> Int {
            state.filter = filter
            return try await engine.apply(state, generation: 1)
        }
        let n = state.columns[0], s = state.columns[1], d = state.columns[2]
        var total = try await count(Planner.predicate(.only, column: s, value: "it's")); XCTAssertEqual(total, 1)
        total = try await count(Planner.predicate(.exclude, column: n, value: "1.5")); XCTAssertEqual(total, 2)
        total = try await count(Planner.predicate(.greater, column: n, value: "1.5")); XCTAssertEqual(total, 1)
        total = try await count(Planner.predicate(.lessOrEqual, column: d, value: "2024-01-02")); XCTAssertEqual(total, 1)
        total = try await count(Planner.predicate(.only, column: n, value: nil)); XCTAssertEqual(total, 1)
        total = try await count(Planner.and(Planner.predicate(.only, column: s, value: "b"), Planner.predicate(.isNotNull, column: n, value: nil)))
        XCTAssertEqual(total, 1)
        XCTAssertEqual(Planner.and("a = 1 OR b = 2", "c = 3"), "(a = 1 OR b = 2) AND c = 3")
        XCTAssertEqual(Planner.and("c = 3", "c = 3"), "c = 3")
    }

    /// The GET Object example from the AWS Signature Version 4 documentation.
    func testSigV4MatchesAWSExample() throws {
        let signer = SigV4Signer(CloudCredentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                                                  secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"), region: "us-east-1")
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        signer.sign(&request, date: Date(timeIntervalSince1970: 1369353600))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testCloudURLs() async throws {
        XCTAssertTrue(RemoteFile.isRemote(URL(string: "s3://bucket/a.parquet")!))
        XCTAssertTrue(RemoteFile.isRemote(URL(string: "gs://bucket/a.csv")!))
        XCTAssertFalse(RemoteFile.isRemote(URL(fileURLWithPath: "/tmp/a.csv")))
        XCTAssertEqual(try RemoteParquet.normalizedURL(URL(string: "S3://bucket/dir/a%20b.parquet#x")!).absoluteString, "s3://bucket/dir/a%20b.parquet")
        XCTAssertEqual(try RemoteFile.normalizedURL(URL(string: "gcs://bucket/x.csv")!).absoluteString, "gs://bucket/x.csv")
        XCTAssertThrowsError(try RemoteFile.normalizedURL(URL(string: "s3://bucket/")!))
        // Without keys, public objects are read unsigned over HTTPS.
        let gcs = try await RemoteEndpoint.resolve(URL(string: "gs://my-bucket/dir/a b.csv")!)
        XCTAssertEqual(gcs.url.absoluteString, "https://storage.googleapis.com/my-bucket/dir/a%20b.csv")
        if ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] == nil, CloudCredentials.load(.s3) == nil {
            let s3 = try await RemoteEndpoint.resolve(URL(string: "s3://my-bucket/k.parquet")!)
            XCTAssertEqual(s3.url.absoluteString, "https://my-bucket.s3.amazonaws.com/k.parquet")
            XCTAssertNil(s3.signer)
            let dotted = try await RemoteEndpoint.resolve(URL(string: "s3://my.bucket/k.parquet")!)
            XCTAssertEqual(dotted.url.absoluteString, "https://s3.amazonaws.com/my.bucket/k.parquet")
        }
    }
}
