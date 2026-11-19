import XCTest
import Foundation
import ScanQuery
@testable import ScanEngine

/// JSON arrays, GeoJSON, zstd, other delimiters, extension aliases, database sniffing,
/// folders of files, Excel workbooks and whole-file remote downloads.
@MainActor final class FormatTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name); try text.write(to: url, atomically: true, encoding: .utf8); return url
    }
    /// Opens a file, indexes it if needed and returns its column names and all rows by column.
    private func read(_ url: URL, table: String? = nil, engine: Engine? = nil) async throws -> (info: SourceInfo, rows: RowPage) {
        let engine = try engine ?? Engine(memoryMB: 128, threads: 2)
        let info = try await engine.open(url, table: table)
        if info.needsImport { try await engine.materialize() }
        var state = ViewState(); state.columns = info.columns
        let count = try await engine.apply(state, generation: 1)
        return (info, try await engine.page(offset: 0, limit: max(count, 1), generation: 1))
    }

    /// The heatmap range follows the active filter and ignores NULLs, text and infinities.
    func testColumnRangeForHeatmap() async throws {
        let dir = try directory()
        let url = try write("id,score,label\n1,-2.5,a\n2,10,b\n3,,c\n4,7,d\n5,inf,e\n", "scores.csv", in: dir)
        let engine = try Engine(memoryMB: 128, threads: 2)
        let info = try await engine.open(url)
        if info.needsImport { try await engine.materialize() }
        var state = ViewState(); state.columns = info.columns
        _ = try await engine.apply(state, generation: 1)
        let all = try await engine.range(column: "score", generation: 1)
        XCTAssertEqual(all, -2.5...10)
        state.filter = "id >= 4"
        _ = try await engine.apply(state, generation: 2)
        let filtered = try await engine.range(column: "score", generation: 2)
        XCTAssertEqual(filtered, 7...7)
        let text = try await engine.range(column: "label", generation: 2)
        XCTAssertNil(text)
    }

    func testFileKindFromNames() {
        XCTAssertEqual(FileKind.guess(name: "a.CSV.ZST")?.format, .delimited(delimiter: nil))
        XCTAssertEqual(FileKind.guess(name: "a.csv.zst")?.compression, .zstd)
        XCTAssertEqual(FileKind.guess(name: "a.tsv.gz")?.format, .delimited(delimiter: "\t"))
        XCTAssertEqual(FileKind.guess(name: "a.psv")?.format, .delimited(delimiter: "|"))
        XCTAssertEqual(FileKind.guess(name: "a.ndjson.zstd")?.format, .jsonLines)
        XCTAssertEqual(FileKind.guess(name: "a.pq")?.format, .parquet)
        XCTAssertEqual(FileKind.guess(name: "a.db3")?.format, .sqlite)
        XCTAssertEqual(FileKind.guess(name: "a.xlsx")?.format, .excel)
        XCTAssertEqual(FileKind.guess(name: "a.geojson")?.format, .geoJSON)
        XCTAssertNil(FileKind.guess(name: "a.parquet.gz")); XCTAssertNil(FileKind.guess(name: "a.gz")); XCTAssertNil(FileKind.guess(name: "a.xls"))
    }

    func testJSONArraySingleObjectAndLinesInJSONFile() async throws {
        let dir = try directory()
        let array = try write(#"[{"id":1,"name":"a","tags":[1,2]},{"id":2,"name":"b","extra":true}]"#, "array.json", in: dir)
        let (info, rows) = try await read(array)
        XCTAssertEqual(info.columns.map(\.name), ["id", "name", "tags", "extra"]); XCTAssertEqual(info.format, "json")
        XCTAssertEqual(rows.columns[1], ["a", "b"]); XCTAssertEqual(rows.columns[3], [nil, "true"])
        let lines = try write("{\"id\":1}\n{\"id\":2}\n", "lines.json", in: dir)
        let fromLines = try await read(lines); XCTAssertEqual(fromLines.rows.columns[0], ["1", "2"])
        // Quick Look streams a JSON array instead of sampling lines.
        let preview = try Engine.preview(); _ = try await preview.open(array, previewLimit: 1)
        let first = try await preview.preview(limit: 1); XCTAssertEqual(first.columns[0], ["1"])
    }

    func testGeoJSONFeaturesBecomeRows() async throws {
        let dir = try directory()
        let url = try write("""
        {"type":"FeatureCollection","features":[
          {"type":"Feature","id":"a","properties":{"name":"Paris","pop":2.1},"geometry":{"type":"Point","coordinates":[2.35,48.85]}},
          {"type":"Feature","id":"b","properties":{"name":"Lyon","pop":0.5},"geometry":{"type":"Point","coordinates":[4.83,45.76]}}]}
        """, "cities.geojson", in: dir)
        let (info, rows) = try await read(url)
        XCTAssertEqual(info.columns.map(\.name), ["feature_id", "name", "pop", "geometry"])
        XCTAssertEqual(rows.columns[1], ["Paris", "Lyon"])
        XCTAssertEqual(rows.columns[3][0], #"{"type":"Point","coordinates":[2.35,48.85]}"#)
        let notCollection = try write(#"{"type":"Point","coordinates":[1,2]}"#, "point.geojson", in: dir)
        do { _ = try await read(notCollection); XCTFail("A bare geometry opened") } catch { XCTAssertTrue(error.localizedDescription.contains("FeatureCollection")) }
    }

    func testZstdCSVAndJSONLWithPreview() async throws {
        let dir = try directory()
        let connection = try Connection(memoryMB: 128, threads: 2)
        let csv = dir.appendingPathComponent("data.csv.zst"), jsonl = dir.appendingPathComponent("data.jsonl.zst")
        try connection.execute("COPY (SELECT range AS id, 'r' || range AS name FROM range(500)) TO \(Planner.literal(csv.path)) (FORMAT CSV, HEADER true, COMPRESSION zstd)")
        try connection.execute("COPY (SELECT range AS id FROM range(500)) TO \(Planner.literal(jsonl.path)) (FORMAT JSON, COMPRESSION zstd)")
        for url in [csv, jsonl] {
            let (info, rows) = try await read(url)
            XCTAssertEqual(info.columns.first?.name, "id"); XCTAssertEqual(rows.count, 500); XCTAssertEqual(rows.columns[0][499], "499")
            let preview = try Engine.preview(); _ = try await preview.open(url, previewLimit: 10)
            let head = try await preview.preview(limit: 10); XCTAssertEqual(head.count, 10)
        }
        XCTAssertEqual(try FileKind.detect(csv).label, "csv.zst")
        // A .gz name on plain text is read as plain text.
        let mislabeled = try write("a,b\n1,2\n", "plain.csv.gz", in: dir)
        let plain = try await read(mislabeled); XCTAssertEqual(plain.rows.columns[1], ["2"])
    }

    func testOtherDelimitersAndAliases() async throws {
        let dir = try directory()
        let pipes = try await read(write("a|b\n1|x,y\n", "pipes.psv", in: dir)); XCTAssertEqual(pipes.rows.columns[1], ["x,y"])
        let tabs = try await read(write("a\tb\n1\tx,y\n", "tabs.tab", in: dir)); XCTAssertEqual(tabs.rows.columns[1], ["x,y"])
        let semi = try await read(write("a;b\n1;2\n", "semi.txt", in: dir)); XCTAssertEqual(semi.info.columns.map(\.name), ["a", "b"])
        let parquet = dir.appendingPathComponent("short.pq")
        try Connection(memoryMB: 128, threads: 2).execute("COPY (SELECT 7 AS n) TO \(Planner.literal(parquet.path)) (FORMAT PARQUET)")
        let (info, rows) = try await read(parquet)
        XCTAssertEqual(info.columns.map(\.name), ["n"]); XCTAssertEqual(rows.columns[0], ["7"])
        do { _ = try await read(write("x", "notes.md", in: dir)); XCTFail("Unknown extension opened") } catch {}
    }

    func testDatabaseFilesAreIdentifiedByHeader() async throws {
        let dir = try directory()
        // A DuckDB database named .db, and a SQLite database named .db3.
        let duck = dir.appendingPathComponent("analytics.db")
        let connection = try Connection(memoryMB: 128, threads: 2)
        try connection.execute("ATTACH \(Planner.literal(duck.path)) AS fixture")
        try connection.execute("CREATE TABLE fixture.t AS SELECT 42 AS answer")
        try connection.execute("DETACH fixture")
        XCTAssertEqual(try FileKind.detect(duck).format, .duckdb)
        let answer = try await read(duck); XCTAssertEqual(answer.rows.columns[0], ["42"])
        let lite = dir.appendingPathComponent("app.db3")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [lite.path, "CREATE TABLE things(id INTEGER); INSERT INTO things VALUES (5);"]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(try FileKind.detect(lite).format, .sqlite)
        let (info, rows) = try await read(lite); XCTAssertEqual(info.tables, ["things"]); XCTAssertEqual(rows.columns[0], ["5"])
        do { _ = try FileKind.detect(write("not a database", "fake.db", in: dir)); XCTFail("Text file accepted as a database") } catch {}
    }

    func testHivePartitionedParquetFolder() async throws {
        let dir = try directory(), folder = dir.appendingPathComponent("events")
        let connection = try Connection(memoryMB: 128, threads: 2)
        try connection.execute("COPY (SELECT range AS id, 2023 + range % 2 AS year FROM range(10)) TO \(Planner.literal(folder.path)) (FORMAT PARQUET, PARTITION_BY (year))")
        // A stray file in another format does not change the folder's format.
        _ = try write("x\n1\n", "notes.csv", in: folder)
        XCTAssertEqual(try FileKind.detect(folder).format, .dataset(.parquet))
        let engine = try Engine(memoryMB: 128, threads: 2)
        let (info, _) = try await read(folder, engine: engine)
        XCTAssertEqual(Set(info.columns.map(\.name)), ["id", "year"]); XCTAssertEqual(info.format, "parquet folder")
        var state = ViewState(); state.columns = info.columns; state.filter = "year = 2024"; state.sorts = [SortKey("id")]
        let filtered = try await engine.apply(state, generation: 2); XCTAssertEqual(filtered, 5)
        let page = try await engine.page(offset: 0, generation: 2)
        XCTAssertEqual(page.columns[info.columns.firstIndex { $0.name == "id" }!], ["1", "3", "5", "7", "9"])
    }

    func testFolderOfCSVFilesWithDifferentColumns() async throws {
        let dir = try directory(), folder = dir.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        _ = try write("id,a\n1,x\n", "one.csv", in: folder)
        _ = try write("id,b\n2,y\n", "nested/two.csv", in: folder)
        let (info, rows) = try await read(folder)
        XCTAssertEqual(Set(info.columns.map(\.name)), ["id", "a", "b"]); XCTAssertEqual(rows.count, 2)
        do { _ = try await read(directory()); XCTFail("Empty folder opened") } catch { XCTAssertTrue(error.localizedDescription.contains("folder")) }
    }

    /// Writes a workbook with DuckDB's Excel writer, then adds a second sheet by copying the first.
    private func workbook(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("book.xlsx")
        try Connection(memoryMB: 128, threads: 2).execute("""
            COPY (SELECT * FROM (VALUES (1, 'a', 2.5), (NULL, NULL, NULL), (3, 'c', NULL), (NULL, NULL, NULL)) t(id, name, amount))
            TO \(Planner.literal(url.path)) (FORMAT xlsx, HEADER true, SHEET 'First Sheet')
            """)
        let unpacked = dir.appendingPathComponent("unpacked")
        func run(_ tool: String, _ arguments: [String], in folder: URL) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
            process.currentDirectoryURL = folder; process.standardOutput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0, tool)
        }
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", url.path], in: unpacked)
        func edit(_ path: String, _ change: (String) -> String) throws {
            let file = unpacked.appendingPathComponent(path)
            try change(try String(contentsOf: file, encoding: .utf8)).write(to: file, atomically: true, encoding: .utf8)
        }
        let sheets = unpacked.appendingPathComponent("xl/worksheets")
        let first = try FileManager.default.contentsOfDirectory(atPath: sheets.path).first { $0.hasSuffix(".xml") }!
        // The second sheet has text in a numeric column, which forces the text fallback.
        let second = try String(contentsOf: sheets.appendingPathComponent(first), encoding: .utf8)
            .replacingOccurrences(of: "<v>3</v>", with: "<is><t>three</t></is>").replacingOccurrences(of: "t=\"n\"><is>", with: "t=\"inlineStr\"><is>")
        try second.write(to: sheets.appendingPathComponent("sheet_two.xml"), atomically: true, encoding: .utf8)
        try edit("xl/workbook.xml") { $0.replacingOccurrences(of: "</sheets>", with: "<sheet name=\"Second\" sheetId=\"99\" r:id=\"rIdTwo\"/></sheets>") }
        try edit("xl/_rels/workbook.xml.rels") { $0.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id=\"rIdTwo\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet_two.xml\"/></Relationships>") }
        try edit("[Content_Types].xml") { $0.replacingOccurrences(of: "</Types>", with: "<Override PartName=\"/xl/worksheets/sheet_two.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>") }
        try FileManager.default.removeItem(at: url)
        try run("/usr/bin/zip", ["-q", "-r", "-X", url.path, "."], in: unpacked)
        return url
    }

    func testExcelSheetsBlankRowsAndMixedTypes() async throws {
        let dir = try directory(), url = try workbook(in: dir)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(try XLSXSheets.names(url), ["First Sheet", "Second"])
        let engine = try Engine(memoryMB: 128, threads: 2)
        let (info, rows) = try await read(url, engine: engine)
        XCTAssertEqual(info.tables, ["First Sheet", "Second"]); XCTAssertEqual(info.format, "xlsx")
        XCTAssertEqual(info.columns.map(\.name), ["id", "name", "amount"]); XCTAssertEqual(info.columns[0].kind, .number)
        // The row after the blank row is kept; the trailing blank row is not.
        XCTAssertEqual(rows.count, 3); XCTAssertEqual(rows.columns[1], ["a", nil, "c"])
        let (second, secondRows) = try await read(url, table: "Second", engine: engine)
        XCTAssertEqual(second.columns[0].type, "VARCHAR"); XCTAssertEqual(secondRows.columns[0], ["1", nil, "three"])
        let preview = try Engine.preview(); _ = try await preview.open(url, previewLimit: 1)
        let previewed = try await preview.preview(limit: 10); XCTAssertEqual(previewed.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), before)
        do { _ = try await read(write("old binary", "legacy.xlsx", in: dir)); XCTFail("Non-zip workbook opened") } catch { XCTAssertTrue(error.localizedDescription.contains(".xlsx")) }
    }

    func testRemoteCSVIsDownloadedWhole() async throws {
        let dir = try directory()
        let csv = try write("id,name\n1,a\n2,b\n", "remote.csv", in: dir)
        let server = try RangeServer(fileURL: csv)
        let url = URL(string: "http://127.0.0.1:\(server.port)/data/remote.csv")!
        let engine = try Engine(memoryMB: 128, threads: 2, remoteCache: dir.appendingPathComponent("cache"))
        let (info, rows) = try await read(url, engine: engine)
        XCTAssertTrue(info.isRemote); XCTAssertEqual(info.format, "csv"); XCTAssertEqual(rows.columns[1], ["a", "b"])
        XCTAssertEqual(try RemoteFile.normalizedURL(URL(string: "https://hf.co/datasets/o/n/blob/main/x.jsonl.gz")!).absoluteString,
                       "https://huggingface.co/datasets/o/n/resolve/main/x.jsonl.gz")
        XCTAssertThrowsError(try RemoteFile.normalizedURL(URL(string: "https://example.com/page.html")!))
    }
}
