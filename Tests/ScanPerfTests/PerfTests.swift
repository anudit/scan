import XCTest
import Foundation
import ScanQuery
import ScanEngine
@MainActor final class PerfTests: XCTestCase {
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
