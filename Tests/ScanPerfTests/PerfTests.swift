import XCTest
import Foundation
import ScanQuery
import ScanEngine
@MainActor final class PerfTests: XCTestCase {
    func testLargeParquetOpenAndPrefetch() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCAN_PERF_FILE"] else { throw XCTSkip("Set SCAN_PERF_FILE to the large Parquet fixture.") }
        let engine = try Engine(memoryMB:512,threads:4)
        let info = try await engine.open(URL(fileURLWithPath:path))
        let preview = try await engine.preview(limit:256)
        XCTAssertEqual(preview.count,256)
        var state = ViewState(); state.columns = info.columns
        let count = try await engine.apply(state,generation:1)
        for offset in [256,512,768,1024,4096,122624,122880,123136,count/2,count-256] {
            let page = try await engine.page(offset:offset,generation:1)
            XCTAssertEqual(page.count,256)
        }
        if info.columns.contains(where: { $0.name == "embedding" }) {
            state.sorts = [SortKey("embedding",ascending:false)]
            let sortedCount = try await engine.apply(state,generation:2)
            XCTAssertEqual(sortedCount,count)
            for offset in [0,256,512,768,1024] {
                let page = try await engine.page(offset:offset,generation:2)
                XCTAssertEqual(page.count,256)
            }
        }
    }
    func testMillionRowPaging() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCAN_PERF_FILE"] else { throw XCTSkip("Set SCAN_PERF_FILE to the large Parquet fixture for performance checks.") }
        let engine = try Engine(memoryMB:256,threads:4)
        let info = try await engine.open(URL(fileURLWithPath:path))
        var state = ViewState(); state.columns = info.columns
        let count = try await engine.apply(state,generation:1)
        XCTAssertGreaterThanOrEqual(count,1_000_000)
        let start = ContinuousClock.now
        let first = try await engine.page(offset:0,generation:1)
        XCTAssertEqual(first.count,256)
        XCTAssertLessThan(start.duration(to:.now),.milliseconds(400))
        let deep = try await engine.page(offset:count-256,generation:1)
        XCTAssertEqual(deep.count,256)
        XCTAssertLessThan(deep.byteCount,1_000_000)
    }
}
