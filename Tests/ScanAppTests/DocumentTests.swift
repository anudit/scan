import Foundation
import XCTest
import ScanQuery
@testable import ScanApp

@MainActor final class DocumentTests: XCTestCase {
    private func waitUntilIdle(_ model: DocumentModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(model.busy)
    }
    func testFailedSortRestoresPreviousViewAndStillLoadsPagesAfter768() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-view-\(UUID().uuidString).csv")
        try ("id,name\n"+(0..<1200).map { "\($0),row\($0)\n" }.joined()).write(to:url,atomically:true,encoding:.utf8)
        defer { try? FileManager.default.removeItem(at:url) }
        let model = DocumentModel(url:url); defer { model.close() }
        model.open(); try await waitUntilIdle(model)
        XCTAssertNil(model.error); XCTAssertEqual(model.rowCount,1200)
        model.state.sorts = [SortKey("missing_column")]
        model.reload(); try await waitUntilIdle(model)
        XCTAssertNotNil(model.error); XCTAssertTrue(model.state.sorts.isEmpty)
        XCTAssertEqual(model.rowCount,1200)
        model.request(3)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.cache.page(3) == nil && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        let page = try XCTUnwrap(model.cache.page(3))
        XCTAssertEqual(page.offset,768); XCTAssertEqual(page.count,256)
        XCTAssertEqual(page.columns[0].first,"768")
    }
}
