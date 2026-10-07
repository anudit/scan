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
    func testExportFormatsRoundTrip() async throws {
        let url = try fixture(); let engine = try Engine(); let info = try await engine.open(url)
        var state = ViewState(); state.columns = info.columns; state.sorts = [SortKey("id",ascending:false)]
        for format in ExportFormat.allCases {
            let target = url.deletingLastPathComponent().appendingPathComponent("export.\(format.rawValue)")
            try await engine.export(to:target,state:state)
            guard format != .json else { continue } // Scan opens JSON Lines, not JSON arrays; checked below.
            let reopened = try Engine(); let schema = try await reopened.open(target).columns
            XCTAssertEqual(schema.map(\.name),["id","name","amount"],"\(format)")
            let first = try await reopened.preview(limit:1); XCTAssertEqual(first.columns[0],["4"],"\(format)")
        }
        // JSON is a single array; JSON Lines has one object per line.
        let json = try String(contentsOf:url.deletingLastPathComponent().appendingPathComponent("export.json"),encoding:.utf8)
        XCTAssertTrue(json.hasPrefix("[")); XCTAssertTrue(json.contains("\"comma,value\""))
        let lines = try String(contentsOf:url.deletingLastPathComponent().appendingPathComponent("export.jsonl"),encoding:.utf8).split(separator:"\n")
        XCTAssertEqual(lines.count,4); XCTAssertTrue(lines[0].hasPrefix("{"))
        do { try await engine.export(to:url.deletingLastPathComponent().appendingPathComponent("export.xlsx"),state:state); XCTFail("Unknown format accepted") } catch {}
    }
    func testColumnSubsetPagesAndSingleCell() async throws {
        let url = try fixture("id,tags,note\n1,\"[1, 2]\",\(String(repeating:"x",count:300))\n2,\"[3]\",short\n")
        let engine = try Engine(); let info = try await engine.open(url); try await engine.materialize()
        var state = ViewState(); state.columns = info.columns; _ = try await engine.apply(state,generation:1)
        let light = try await engine.page(offset:0,generation:1,only:["id"])
        XCTAssertEqual(light.columns[0],["1","2"]); XCTAssertEqual(light.columns[1],[]); XCTAssertEqual(light.count,2)
        XCTAssertTrue(light.isLoaded(0)); XCTAssertFalse(light.isLoaded(1)); XCTAssertFalse(light.isComplete)
        let rest = try await engine.page(offset:0,generation:1,only:["tags","note"])
        let merged = light.merging(rest); XCTAssertTrue(merged.isComplete); XCTAssertEqual(merged.columns[2][1],"short")
        XCTAssertEqual(merged.columns[2][0]?.count,Planner.displayLimit)
        let full = try await engine.cell(row:0,column:"note",generation:1); XCTAssertEqual(full?.count,300)
    }
    func testPreviewSamplesHeadOfLargeTextFiles() async throws {
        // A quoted field spans lines; the sample must not cut inside it.
        var text = "id,body\n"
        for i in 0..<5000 { text += "\(i),\"line one\nline \"\"two\"\" of \(i)\"\n" }
        let url = try fixture(text)
        let engine = try Engine.preview(); let info = try await engine.open(url,previewLimit:10)
        XCTAssertEqual(info.columns.map(\.name),["id","body"]); XCTAssertFalse(info.needsImport)
        let rows = try await engine.preview(limit:10)
        XCTAssertEqual(rows.columns[0],(0..<10).map { String($0) })
        XCTAssertEqual(rows.columns[1][9],"line one\nline \"two\" of 9")
        // gzip samples are inflated incrementally and give the same rows.
        let gz = url.deletingLastPathComponent().appendingPathComponent("big.csv.gz")
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/gzip"); process.arguments = ["-k","-c",url.path]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); try data.write(to:gz)
        let gzEngine = try Engine.preview(); _ = try await gzEngine.open(gz,previewLimit:10)
        let gzRows = try await gzEngine.preview(limit:10); XCTAssertEqual(gzRows.columns[1],rows.columns[1])
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
    func testJSONLAndGzipPreviewSortFilterAndReadOnly() async throws {
        let fixtureURL = try fixture("""
        {"id":1,"name":"alpha","amount":10.5,"active":true,"tags":["a","b"],"details":{"city":"Paris","zips":["75001"]}}
        {"id":2,"name":"comma,value","amount":20,"active":false,"tags":[],"details":{"city":"London"}}
        {"id":3,"name":"alpha","active":true,"tags":null,"details":null}

        """)
        let url = fixtureURL.deletingLastPathComponent().appendingPathComponent("test's data.JSONL")
        try FileManager.default.moveItem(at:fixtureURL,to:url)
        let gzip = Process(); gzip.executableURL = URL(fileURLWithPath:"/usr/bin/gzip"); gzip.arguments = ["-k",url.path]
        try gzip.run(); gzip.waitUntilExit(); XCTAssertEqual(gzip.terminationStatus,0)
        let compressed = url.appendingPathExtension("GZ")
        try FileManager.default.moveItem(at:url.appendingPathExtension("gz"),to:compressed)
        let ndjson = url.deletingPathExtension().appendingPathExtension("ndjson"); try FileManager.default.copyItem(at:url,to:ndjson)
        let ndjsonGzip = ndjson.appendingPathExtension("gz"); try FileManager.default.copyItem(at:compressed,to:ndjsonGzip)
        for input in [url,compressed,ndjson,ndjsonGzip] {
            let before = try Data(contentsOf:input)
            let modified = try FileManager.default.attributesOfItem(atPath:input.path)[.modificationDate] as? Date
            let engine = try Engine(memoryMB:128,threads:2); let info = try await engine.open(input)
            XCTAssertEqual(info.columns.map(\.name),["id","name","amount","active","tags","details"])
            XCTAssertEqual(info.columns[0].kind,.number); XCTAssertTrue(info.needsImport)
            let preview = try await engine.preview(limit:10)
            XCTAssertEqual(preview.count,3); XCTAssertEqual(preview.columns[1][1],"comma,value")
            XCTAssertEqual(preview.columns[3],["true","false","true"]); XCTAssertNil(preview.columns[2][2])
            XCTAssertTrue(preview.columns[4][0]?.contains("a") == true)
            XCTAssertTrue(preview.columns[5][0]?.contains("Paris") == true)
            let details = try await engine.cell(row:0,column:"details",generation:0); XCTAssertEqual(details,#"{"city":"Paris","zips":["75001"]}"#)
            var state = ViewState(); state.columns = info.columns; state.filter = "name = 'alpha'"
            let filteredCount = try await engine.apply(state,generation:1); XCTAssertEqual(filteredCount,2)
            let filtered = try await engine.page(offset:1,limit:1,generation:1); XCTAssertEqual(filtered.columns[0],["3"])
            state.sorts = [SortKey("id",ascending:false)]
            let sortedCount = try await engine.apply(state,generation:2); XCTAssertEqual(sortedCount,2)
            let sorted = try await engine.page(offset:0,generation:2); XCTAssertEqual(sorted.columns[0],["3","1"])
            let exportURL = input.appendingPathExtension("parquet")
            try await engine.export(to:exportURL,state:state)
            let exported = try Engine(); _ = try await exported.open(exportURL)
            let exportedPreview = try await exported.preview(); XCTAssertEqual(exportedPreview.columns[0],["3","1"])
            XCTAssertEqual(try Data(contentsOf:input),before)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:input.path)[.modificationDate] as? Date,modified)
        }
    }
    func testMalformedJSONLReportsError() async throws {
        let fixtureURL = try fixture("{\"id\":1}\n{not valid json}\n")
        let url = fixtureURL.deletingPathExtension().appendingPathExtension("jsonl")
        try FileManager.default.moveItem(at:fixtureURL,to:url)
        let engine = try Engine()
        do { _ = try await engine.open(url); _ = try await engine.preview(); XCTFail("Malformed JSONL accepted") }
        catch let error as EngineError { XCTAssertTrue(error.message.lowercased().contains("malformed json"),error.message) }
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

    func testAskTextContainsHandlesCaseAndModelFormatting() async throws {
        let url = try fixture("id,title\n1,Play time\n2,Other\n3,gameplay\n")
        let before = try Data(contentsOf:url)
        let engine = try Engine()
        _ = try await engine.open(url)
        let output = try await engine.ask("```sql\nSELECT title FROM scan_data WHERE contains(lower(CAST(\"title\" AS VARCHAR)), lower('play')) ORDER BY id LIMIT 200;\n```")
        XCTAssertEqual(output.page.columns[0],["Play time","gameplay"])
        XCTAssertEqual(try Data(contentsOf:url),before)
    }

}
