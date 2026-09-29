import XCTest
import Foundation
import ScanQuery
@testable import ScanEngine

@MainActor final class EngineTests: XCTestCase {
    private func fixture(_ text: String = "id,name,amount\n1,alpha,10.5\n2,beta,20\n3,alpha,\n4,\"comma,value\",-2\n") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let url = dir.appendingPathComponent("test's data.csv"); try text.write(to:url,atomically:true,encoding:.utf8); addTeardownBlock { try? FileManager.default.removeItem(at:dir) }; return url
    }
    func testCSVSortFilterFullValuesAndReadOnly() async throws {
        let url = try fixture(); let before = try Data(contentsOf:url); let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
        let engine = try Engine(memoryMB:128,threads:2); let info = try await engine.open(url)
        XCTAssertEqual(info.columns.map(\.name),["id","name","amount"])
        let preview = try await engine.preview(); XCTAssertEqual(preview.count,4); XCTAssertEqual(preview.columns[1][3],"comma,value")
        try await engine.materialize()
        var state = ViewState(); state.columns = info.columns; state.sorts = [SortKey("id",ascending:false)]
        let count = try await engine.apply(state,generation:1); XCTAssertEqual(count,4)
        let sorted = try await engine.page(offset:0,limit:2,generation:1); XCTAssertEqual(sorted.columns[0],["4","3"])
        state.filter = "name = 'alpha'"; let filteredCount = try await engine.apply(state,generation:2); XCTAssertEqual(filteredCount,2)
        let filtered = try await engine.page(offset:0,generation:2); XCTAssertEqual(filtered.columns[0],["3","1"])
        do { _ = try await engine.page(offset:0,generation:1); XCTFail("Stale generation accepted") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf:url),before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate] as? Date,attrs[.modificationDate] as? Date)
    }
    func testParquetExportReopenAndNoOverwrite() async throws {
        let url = try fixture(); let engine = try Engine(); let info = try await engine.open(url)
        var state = ViewState(); state.columns = info.columns
        let target = url.deletingLastPathComponent().appendingPathComponent("test.parquet")
        try await engine.export(to:target,state:state)
        do { try await engine.export(to:target,state:state); XCTFail("Overwrite accepted") } catch {}
        let parquet = try Engine(); let schema = try await parquet.open(target); XCTAssertEqual(schema.columns.count,3)
        state.columns = schema.columns; _ = try await parquet.apply(state,generation:1)
        let page = try await parquet.page(offset:2,limit:1,generation:1); XCTAssertEqual(page.columns[0],["3"]); XCTAssertNil(page.columns[2][0])
    }
    func testPivotNullsAggregatesAndChildren() async throws {
        let url = try fixture("id,groupname,sub,amount\n1,a,x,10\n2,a,y,20\n3,b,x,5\n4,,x,7\n")
        let engine = try Engine(); let info = try await engine.open(url)
        var state = ViewState(); state.columns = info.columns; state.groups = ["groupname","sub"]; state.aggregates["amount"] = .sum
        let roots = try await engine.pivot(state:state); XCTAssertEqual(roots.count,3)
        XCTAssertEqual(roots[0].path,["a"]); XCTAssertEqual(roots[0].values[3],"30"); XCTAssertEqual(roots[0].values.last!,"2")
        let children = try await engine.pivot(state:state,path:["a"]); XCTAssertEqual(children.count,2)
        let nullChildren = try await engine.pivot(state:state,path:[nil]); XCTAssertEqual(nullChildren.count,1)
    }
    func testLongTextTruncatedUntilRequested() async throws {
        let long = String(repeating:"é",count:600)
        let url = try fixture("id,text\n1,\(long)\n")
        let engine = try Engine(); let info = try await engine.open(url); var state = ViewState(); state.columns = info.columns; _ = try await engine.apply(state,generation:1)
        let page = try await engine.page(offset:0,generation:1); XCTAssertEqual(page.columns[1][0]?.count,160)
        let full = try await engine.page(offset:0,generation:1,full:true); XCTAssertEqual(full.columns[1][0],long)
    }
    func testGzipTSVAndInvalidFilter() async throws {
        let url = try fixture("id\tname\n1\talpha\n2\tbeta\n")
        let tsv = url.deletingLastPathComponent().appendingPathComponent("file.tsv")
        try FileManager.default.moveItem(at:url,to:tsv)
        let gzip = Process(); gzip.executableURL = URL(fileURLWithPath:"/usr/bin/gzip"); gzip.arguments = ["-k",tsv.path]; try gzip.run(); gzip.waitUntilExit()
        let engine = try Engine(); let info = try await engine.open(tsv.appendingPathExtension("gz")); XCTAssertEqual(info.columns.count,2)
        do { try await engine.validate(filter:"id = ; DROP TABLE source"); XCTFail("Invalid filter accepted") } catch {}
        let preview = try await engine.preview(); XCTAssertEqual(preview.count,2)
    }
    func testDuckDBReadOnlySource() async throws {
        let dir = try fixture().deletingLastPathComponent(); let database = dir.appendingPathComponent("source.duckdb")
        do {
            let connection = try Connection(memoryMB:128,threads:2)
            try connection.execute("ATTACH \(Planner.literal(database.path)) AS fixture")
            try connection.execute("CREATE TABLE fixture.values_table AS SELECT 1 AS id, 'hello' AS name")
            try connection.execute("DETACH fixture")
        }
        let before = try Data(contentsOf:database)
        let engine = try Engine(); let info = try await engine.open(database); XCTAssertEqual(info.tables,["main.values_table"])
        let preview = try await engine.preview(); XCTAssertEqual(preview.columns[1][0],"hello")
        XCTAssertEqual(try Data(contentsOf:database),before)
    }
    func testSQLiteReadOnlyImport() async throws {
        let csv = try fixture(); let url = csv.deletingLastPathComponent().appendingPathComponent("test.sqlite")
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/sqlite3")
        process.arguments = [url.path,"CREATE TABLE data(id INTEGER, name TEXT); INSERT INTO data VALUES (1,'alpha'),(2,NULL);"]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        let before = try Data(contentsOf:url)
        let engine = try Engine(); let info = try await engine.open(url)
        XCTAssertEqual(info.tables,["data"]); XCTAssertEqual(info.columns[0].kind,.number)
        let page = try await engine.preview(); XCTAssertEqual(page.count,2); XCTAssertNil(page.columns[1][1])
        XCTAssertEqual(try Data(contentsOf:url),before)
    }
    func testAskQueryReturnsResultsWithoutChangingTheSource() async throws {
        let url = try fixture()
        let before = try Data(contentsOf:url)
        let engine = try Engine()
        _ = try await engine.open(url)
        let output = try await engine.ask("SELECT name, count(*) AS records FROM scan_data GROUP BY name ORDER BY records DESC")
        XCTAssertEqual(output.columns.map(\.name),["name","records"])
        XCTAssertEqual(output.page.count,3)
        XCTAssertEqual(output.page.columns[1][0],"2")
        XCTAssertEqual(try Data(contentsOf:url),before)
        do { _ = try await engine.ask("COPY scan_data TO '/tmp/oops.csv'"); XCTFail("Unsafe Ask statement was accepted") } catch {}
    }

}
