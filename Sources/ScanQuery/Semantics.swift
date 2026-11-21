import Foundation

/// What a column's values mean, beyond their storage type. Text columns often hold UUIDs,
/// ISO 8601 timestamps, URLs or emails; detecting them lets the grid show each one in a form
/// that is easier to read. Only the display changes: filters, copies and exports use the raw value.
public enum ColumnSemantic: String, Sendable, Hashable, CaseIterable {
    case uuid, timestamp, date, url, email

    public var label: String { rawValue }
    public var glyph: String {
        switch self { case .uuid: "ID"; case .timestamp, .date: "◷"; case .url: "↗"; case .email: "@" }
    }
    /// Whether values read better in a fixed-width font.
    public var monospaced: Bool { self != .url && self != .email }

    /// How many sample values must match before a column is labeled. Fewer than this is too little evidence.
    public static let minimumSample = 3

    /// Detects the meaning of a column from a sample of its values, or nil when nothing fits every
    /// non-empty value. NULLs and empty strings are ignored.
    public static func detect(_ column: Column, sample: [String?]) -> ColumnSemantic? {
        let type = column.type.uppercased()
        if type == "UUID" { return .uuid }
        let values = sample.lazy.compactMap { $0 }.filter { !$0.isEmpty }
        if column.kind == .temporal {
            // A TIMESTAMP whose every value falls on midnight UTC is a date stored as a timestamp.
            // Other timestamps are shortened. DuckDB shows TIMESTAMPTZ in the local zone, so midnight
            // UTC can arrive as "05:30:00+05:30"; isMidnight checks the instant, not the clock.
            guard type.hasPrefix("TIMESTAMP"), values.count >= minimumSample else { return nil }
            var all = true, midnight = true
            for value in values {
                guard let stamp = Timestamp(parsing: value) else { all = false; break }
                midnight = midnight && stamp.isMidnight
            }
            return all ? (midnight ? .date : .timestamp) : nil
        }
        guard column.kind == .text, values.count >= minimumSample else { return nil }
        if values.allSatisfy(isUUID) { return .uuid }
        if values.allSatisfy(isDate) { return .date }
        var midnight = true
        if values.allSatisfy({ value in
            guard let stamp = Timestamp(parsing: value) else { return false }
            midnight = midnight && stamp.isMidnight
            return true
        }) { return midnight ? .date : .timestamp }
        if values.allSatisfy(isURL) { return .url }
        if values.allSatisfy(isEmail) { return .email }
        return nil
    }

    /// The text to show for a value of this meaning. Values that do not parse are shown unchanged.
    public func display(_ value: String) -> String {
        switch self {
        case .uuid: return value.lowercased()
        case .date:
            if Self.isDate(value) { return value }
            return Timestamp(parsing: value)?.utcDate ?? value
        case .timestamp: return Timestamp(parsing: value)?.formatted ?? value
        case .url:
            var text = Substring(value)
            for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text = text.dropFirst(prefix.count); break }
            if text.hasPrefix("www.") { text = text.dropFirst(4) }
            if text.hasSuffix("/") && text.dropLast().contains("/") == false { text = text.dropLast() }
            return String(text)
        case .email: return value
        }
    }

    // MARK: Matchers. These run on a few hundred values per column, so they stay simple and byte-based.

    static func isUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (i, b) in bytes.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 { if b != UInt8(ascii: "-") { return false } }
            else if !isHex(b) { return false }
        }
        return true
    }
    static func isDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 10 && datePrefix(bytes)
    }
    static func isURL(_ value: String) -> Bool {
        guard value.hasPrefix("https://") || value.hasPrefix("http://") else { return false }
        return value.utf8.count > 10 && !value.utf8.contains(UInt8(ascii: " "))
    }
    static func isEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return !value.utf8.contains(UInt8(ascii: " "))
    }
    fileprivate static func isHex(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...70).contains(b) || (97...102).contains(b) }
    fileprivate static func isDigit(_ b: UInt8) -> Bool { (48...57).contains(b) }
    /// "YYYY-MM-DD" at the start of the bytes.
    fileprivate static func datePrefix(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else { return false }
        for i in [0, 1, 2, 3, 5, 6, 8, 9] where !isDigit(bytes[i]) { return false }
        return true
    }
}

/// An ISO 8601 or DuckDB timestamp split into its parts: "2024-03-01T14:05:00.000Z",
/// "2024-03-01 14:05:00+00" or "2024-03-01 14:05".
struct Timestamp {
    let date: Substring
    let time: Substring
    let fraction: Substring
    let zone: Substring

    init?(parsing value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count >= 16, ColumnSemantic.datePrefix(bytes), bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " ") else { return nil }
        // HH:MM, then optional :SS.
        guard ColumnSemantic.isDigit(bytes[11]), ColumnSemantic.isDigit(bytes[12]), bytes[13] == UInt8(ascii: ":"),
              ColumnSemantic.isDigit(bytes[14]), ColumnSemantic.isDigit(bytes[15]) else { return nil }
        var end = 16
        if bytes.count >= 19, bytes[16] == UInt8(ascii: ":"), ColumnSemantic.isDigit(bytes[17]), ColumnSemantic.isDigit(bytes[18]) { end = 19 }
        var fractionEnd = end
        if fractionEnd < bytes.count, bytes[fractionEnd] == UInt8(ascii: ".") {
            fractionEnd += 1
            while fractionEnd < bytes.count, ColumnSemantic.isDigit(bytes[fractionEnd]) { fractionEnd += 1 }
        }
        let rest = bytes[fractionEnd...]
        // The zone is Z, or a sign with up to four digits and an optional colon.
        if !rest.isEmpty {
            if rest.count == 1 && rest.first == UInt8(ascii: "Z") {}
            else {
                guard let sign = rest.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-"), rest.count <= 6,
                      rest.dropFirst().allSatisfy({ ColumnSemantic.isDigit($0) || $0 == UInt8(ascii: ":") }) else { return nil }
            }
        }
        let scalars = value.utf8
        func slice(_ a: Int, _ b: Int) -> Substring { Substring(scalars[scalars.index(scalars.startIndex, offsetBy: a)..<scalars.index(scalars.startIndex, offsetBy: b)]) }
        date = slice(0, 10); time = slice(11, end); fraction = slice(end, fractionEnd); zone = slice(fractionEnd, bytes.count)
    }

    /// Whether the instant is midnight UTC. A value with no zone is read as UTC.
    var isMidnight: Bool {
        guard let minutes = clockMinutes, let offset = offsetMinutes, fraction.dropFirst().allSatisfy({ $0 == "0" }),
              time.count == 5 || time.hasSuffix(":00") else { return false }
        return (minutes - offset) % 1440 == 0
    }
    var isUTC: Bool { offsetMinutes == 0 }
    /// Minutes since local midnight on the clock, ignoring seconds.
    private var clockMinutes: Int? {
        guard let h = Int(time.prefix(2)), let m = Int(time.dropFirst(3).prefix(2)) else { return nil }
        return h * 60 + m
    }
    /// The zone's offset from UTC in minutes: "+05:30" is 330, "Z" or no zone is 0.
    var offsetMinutes: Int? {
        if zone.isEmpty || zone == "Z" { return 0 }
        let digits = zone.dropFirst().filter { $0 != ":" }
        guard let sign = zone.first, digits.count == 2 || digits.count == 4, let h = Int(digits.prefix(2)) else { return nil }
        let m = digits.count == 4 ? Int(digits.suffix(2)) ?? 0 : 0
        return (sign == "-" ? -1 : 1) * (h * 60 + m)
    }
    /// The calendar date in UTC, "YYYY-MM-DD". The local date can differ by a day when the zone is not UTC.
    var utcDate: String {
        guard let minutes = clockMinutes, let offset = offsetMinutes, offset != 0 else { return String(date) }
        let shift = Int(((Double(minutes - offset)) / 1440).rounded(.down))
        guard shift != 0, let y = Int(date.prefix(4)), let mo = Int(date.dropFirst(5).prefix(2)), let d = Int(date.suffix(2)) else { return String(date) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let start = calendar.date(from: DateComponents(year: y, month: mo, day: d)),
              let moved = calendar.date(byAdding: .day, value: shift, to: start) else { return String(date) }
        let c = calendar.dateComponents([.year, .month, .day], from: moved)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2024-03-01 14:05 UTC": seconds only when set, fractions without trailing zeros.
    var formatted: String {
        var clock = time.hasSuffix(":00") && time.count == 8 && fraction.dropFirst().allSatisfy({ $0 == "0" }) ? String(time.prefix(5)) : String(time)
        var digits = fraction.dropFirst()
        while digits.last == "0" { digits = digits.dropLast() }
        if !digits.isEmpty { clock += "." + digits }
        let suffix: String
        if zone.isEmpty { suffix = "" }
        else if isUTC { suffix = " UTC" }
        else { suffix = " " + zone }
        return "\(date) \(clock)\(suffix)"
    }
}
