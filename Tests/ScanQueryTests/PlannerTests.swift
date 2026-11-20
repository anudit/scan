import XCTest
import AppKit
@testable import ScanQuery
import ScanTheme
final class PlannerTests: XCTestCase {
    func testIdentifierAndLiteralEscaping() {
        XCTAssertEqual(Planner.identifier("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(Planner.literal("O'Brien"), "'O''Brien'")
    }
    func testBuilderBindsValuesAndDoesNotTreatWildcardsAsSQL() {
        let sql = Planner.predicate([FilterRule(column:"a\"b",value:"%'; DROP TABLE x; --"), FilterRule(column:"value",op:.isNull)],any:true)
        XCTAssertEqual(sql.parameters,["%'; DROP TABLE x; --"])
        XCTAssertTrue(sql.text.contains(" OR ")); XCTAssertFalse(sql.text.contains("DROP")); XCTAssertTrue(sql.text.contains("\"a\"\"b\""))
    }
    func testFilterRejectsMultipleStatementsAndComments() {
        for value in ["1=1; DROP TABLE source", "true -- hi", "true /* hi */", "name = 'oops"] { XCTAssertThrowsError(try Planner.validateFilter(value)) }
        for value in ["name='O''Brien'", "name = ';--'", "x > 10 AND y IS NULL", "\"a;b\" = 1"] { XCTAssertNoThrow(try Planner.validateFilter(value)) }
    }
    func testTypesAndWideProjection() {
        XCTAssertEqual(Column("x","FLOAT[]").kind,.nested)
        XCTAssertEqual(Column("x","DECIMAL(10,2)").kind,.number)
        XCTAssertEqual(Column("x","TIMESTAMP").kind,.temporal)
        XCTAssertTrue(Planner.display(Column("vector","FLOAT[]")).contains("list_slice"))
        XCTAssertFalse(Planner.display(Column("maker","STRUCT(handle VARCHAR, links VARCHAR[])")).contains("list_slice"))
    }
    func testCSVQuotesMultilineAndDistinguishesNullFromEmptyInMemory() {
        XCTAssertEqual(Planner.csv([["a,b","x\"y","line\nnext",nil,""]]),"\"a,b\",\"x\"\"y\",\"line\nnext\",,")
    }
    func testPivotFlattening() {
        var root = PivotNode(path:["a"],values:["a"]); root.children = [PivotNode(path:["a",nil],values:[nil])]
        XCTAssertEqual(root.flattened.count,1); root.expanded = true; XCTAssertEqual(root.flattened.count,2)
    }
    func testTextContrast() {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB)!
            func channel(_ n: CGFloat)->Double { let v = Double(n); return v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
            return 0.2126*channel(c.redComponent)+0.7152*channel(c.greenComponent)+0.0722*channel(c.blueComponent)
        }
        let colors = [ScanTheme.primary,ScanTheme.muted,ScanTheme.faint,ScanTheme.danger] + [CellKind.number,.boolean,.temporal,.nested].map { ScanTheme.color(for:$0,value:"true") }
        for color in colors { XCTAssertGreaterThanOrEqual((luminance(color)+0.05)/(luminance(ScanTheme.grid)+0.05),4.5) }
    }
    func testAskOnlyReadsTheOpenTable() {
        XCTAssertEqual(try AskQuery.validate("SELECT count(*) FROM scan_data"), "SELECT count(*) FROM scan_data")
        for sql in ["DELETE FROM scan_data", "SELECT * FROM other_table", "SELECT * FROM scan_data JOIN other_table USING (id)", "SELECT * FROM read_csv('/tmp/x.csv')", "SELECT * FROM scan_data; DROP TABLE scan_data"] {
            XCTAssertThrowsError(try AskQuery.validate(sql), sql)
        }
        XCTAssertEqual(ScanTheme.color(for:.text,value:nil),ScanTheme.null)
    }
    func testAskNormalizesModelFormattingWithoutAcceptingExtraStatements() throws {
        let sql = "SELECT * FROM scan_data WHERE contains(lower(\"title\"), 'play') LIMIT 200"
        XCTAssertEqual(try AskQuery.validate(sql + ";"),sql)
        XCTAssertEqual(try AskQuery.validate("```sql\n" + sql + ";\n```"),sql)
        XCTAssertEqual(try AskQuery.validate("SELECT * FROM scan_data WHERE title = 'it''s;--play';"),"SELECT * FROM scan_data WHERE title = 'it''s;--play'")
        for value in [sql + "; SELECT * FROM scan_data;", sql + ";;", sql + " -- comment", "```sql\nDELETE FROM scan_data;\n```"] {
            XCTAssertThrowsError(try AskQuery.validate(value),value)
        }
        do { _ = try AskQuery.validate(sql + ";;"); XCTFail("Extra statements accepted") }
        catch { XCTAssertFalse(error.localizedDescription.contains("WHERE expression")) }
    }

    func testSQLTokenizerColorsKeywordsStringsAndComments() {
        let text = "SELECT count(*), \"a b\" FROM t WHERE x = 'sele''ct' AND y > 1.5 -- where\n"
        let tokens = SQLTokenizer.tokens(in: text)
        func kinds(_ word: String) -> [SQLTokenizer.Kind] {
            let range = (text as NSString).range(of: word)
            return tokens.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.kind)
        }
        XCTAssertEqual(kinds("SELECT"), [.keyword])
        XCTAssertEqual(kinds("count"), [.function])
        XCTAssertEqual(kinds("\"a b\"").last, .quotedIdentifier)
        // A keyword inside a string or comment is painted over by the string or comment.
        XCTAssertEqual(kinds("sele'").last, .string)
        XCTAssertEqual(kinds("-- where").last, .comment)
        XCTAssertEqual(kinds("1.5"), [.number])
        XCTAssertTrue(SQLTokenizer.tokens(in: "").isEmpty)
        // An unfinished string or block comment is still colored while it is being typed.
        XCTAssertEqual(SQLTokenizer.tokens(in: "WHERE a = 'abc").last?.kind, .string)
        XCTAssertEqual(SQLTokenizer.tokens(in: "/* abc").last?.kind, .comment)
    }
}
