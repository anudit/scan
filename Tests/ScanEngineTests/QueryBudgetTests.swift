import XCTest
import ScanQuery
@testable import ScanEngine

final class QueryBudgetTests: XCTestCase {
    func testOOMRetriesQueryWithMoreMemory() throws {
        let connection = try Connection(memoryMB:64,threads:4)
        let result = try connection.query(SQL("SELECT CAST(length(list(i)) AS VARCHAR) FROM range(10000000) t(i)"))
        XCTAssertEqual(result.columns[0],["10000000"])
        XCTAssertGreaterThan(connection.memoryMB,64)
        XCTAssertLessThanOrEqual(connection.memoryMB,4096)
    }
    func testRecoveryReducesThreadsBeforeGrowingAndStopsAtCeiling() {
        var budget = QueryBudget(memoryMB:512,threads:4,physicalMemory:64_000_000_000)
        XCTAssertTrue(budget.recover()); XCTAssertEqual(budget.threads,1); XCTAssertEqual(budget.memoryMB,512)
        for expected in [1024,2048,4096] {
            XCTAssertTrue(budget.recover()); XCTAssertEqual(budget.memoryMB,expected)
        }
        XCTAssertFalse(budget.recover()); XCTAssertEqual(budget.memoryMB,4096)
    }
    func testRecoveryRespectsRAMAndExplicitStartingBudget() {
        var small = QueryBudget(memoryMB:512,threads:1,physicalMemory:8_000_000_000)
        XCTAssertTrue(small.recover()); XCTAssertEqual(small.memoryMB,1000)
        XCTAssertFalse(small.recover())
        var explicit = QueryBudget(memoryMB:2048,threads:1,physicalMemory:8_000_000_000)
        XCTAssertEqual(explicit.ceilingMB,2048); XCTAssertFalse(explicit.recover())
    }
}
