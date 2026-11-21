import XCTest
@testable import ScanQuery

final class SemanticsTests: XCTestCase {
    private let text = Column("c", "VARCHAR")
    private func detect(_ values: [String?], _ column: Column? = nil) -> ColumnSemantic? { ColumnSemantic.detect(column ?? text, sample: values) }

    func testDetectsUUIDs() {
        XCTAssertEqual(detect(["3f2504e0-4f89-11d3-9a0c-0305e82c3301", "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", nil, "", "00000000-0000-0000-0000-000000000000"]), .uuid)
        XCTAssertNil(detect(["3f2504e0-4f89-11d3-9a0c-0305e82c3301", "not-a-uuid", "6ba7b810-9dad-11d1-80b4-00c04fd430c8"]))
        XCTAssertEqual(ColumnSemantic.detect(Column("id", "UUID"), sample: []), .uuid)
        XCTAssertEqual(ColumnSemantic.uuid.display("6BA7B810-9DAD-11D1-80B4-00C04FD430C8"), "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
    }
    func testMidnightTimestampsBecomeDates() {
        let values = ["1978-01-01T00:00:00Z", "1925-01-01T00:00:00Z", "1973-06-20T00:00:00Z"]
        XCTAssertEqual(detect(values), .date)
        XCTAssertEqual(ColumnSemantic.date.display("1978-01-01T00:00:00Z"), "1978-01-01")
        XCTAssertEqual(detect(["2024-01-01", "2024-02-29", "1999-12-31"]), .date)
    }
    func testTimestampsAreShortened() {
        XCTAssertEqual(detect(["2024-03-01T14:05:00Z", "2024-03-01T00:00:00Z", "2024-03-02 09:10:11.250+02:00"]), .timestamp)
        XCTAssertEqual(ColumnSemantic.timestamp.display("2024-03-01T14:05:00Z"), "2024-03-01 14:05 UTC")
        XCTAssertEqual(ColumnSemantic.timestamp.display("2024-03-01T14:05:07.120Z"), "2024-03-01 14:05:07.12 UTC")
        XCTAssertEqual(ColumnSemantic.timestamp.display("2024-03-02 09:10:11+02:00"), "2024-03-02 09:10:11 +02:00")
        XCTAssertEqual(ColumnSemantic.timestamp.display("not a time"), "not a time")
        XCTAssertNil(detect(["2024-03-01T14:05:00Z", "2024-03-01T14:05:00Zulu", "2024-03-01T14:05:00Z"]))
    }
    func testNativeTimestampColumnsAtMidnightShowDates() {
        let column = Column("d", "TIMESTAMP")
        XCTAssertEqual(ColumnSemantic.detect(column, sample: ["2008-01-01 00:00:00", "2011-05-02 00:00:00", "1999-01-01 00:00:00"]), .date)
        XCTAssertEqual(ColumnSemantic.detect(column, sample: ["2008-01-01 00:00:00", "2011-05-02 10:00:00", "1999-01-01 00:00:00"]), .timestamp)
    }
    func testZonedMidnightIsADateInUTC() {
        let column = Column("d", "TIMESTAMP WITH TIME ZONE")
        XCTAssertEqual(ColumnSemantic.detect(column, sample: ["1978-01-01 05:30:00+05:30", "1925-01-01 05:30:00+05:30", "1973-06-20 05:30:00+05:30"]), .date)
        XCTAssertEqual(ColumnSemantic.date.display("1978-01-01 05:30:00+05:30"), "1978-01-01")
        XCTAssertEqual(ColumnSemantic.date.display("1977-12-31 19:00:00-05"), "1978-01-01")
        XCTAssertEqual(ColumnSemantic.timestamp.display("2024-03-01 19:35:00+05:30"), "2024-03-01 19:35 +05:30")
        XCTAssertNil(ColumnSemantic.detect(Column("d", "DATE"), sample: ["2024-01-01", "2024-01-02", "2024-01-03"]))
    }
    func testURLsAndEmails() {
        XCTAssertEqual(detect(["https://en.wikipedia.org/wiki/Gazprom", "http://www.example.com/", "https://a.io/x"]), .url)
        XCTAssertEqual(ColumnSemantic.url.display("https://www.example.com/"), "example.com")
        XCTAssertEqual(ColumnSemantic.url.display("https://en.wikipedia.org/wiki/Gazprom"), "en.wikipedia.org/wiki/Gazprom")
        XCTAssertEqual(detect(["a@b.co", "first.last@example.org", "x@y.io"]), .email)
        XCTAssertNil(detect(["a@b.co", "plain text", "x@y.io"]))
    }
    func testNeedsEnoughEvidence() {
        XCTAssertNil(detect(["3f2504e0-4f89-11d3-9a0c-0305e82c3301", nil, ""]))
        XCTAssertNil(ColumnSemantic.detect(Column("n", "BIGINT"), sample: ["1", "2", "3"]))
    }
}
