import Foundation

public struct Column: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public var name: String
    public var type: String
    public init(_ name: String, _ type: String) { self.name = name; self.type = type }
    public var kind: CellKind { CellKind(type: type) }
}
public enum CellKind: String, Sendable {
    case number, text, boolean, temporal, nested, binary
    public init(type: String) {
        let t = type.uppercased()
        if t.contains("[") || t.hasPrefix("STRUCT") || t.hasPrefix("MAP") || t == "JSON" { self = .nested }
        else if ["INT", "DECIMAL", "FLOAT", "DOUBLE", "REAL", "HUGEINT", "UBIGINT"].contains(where: t.contains) { self = .number }
        else if t == "BOOLEAN" { self = .boolean }
        else if t.contains("DATE") || t.contains("TIME") || t == "INTERVAL" { self = .temporal }
        else if t == "BLOB" { self = .binary }
        else { self = .text }
    }
    public var glyph: String { switch self { case .number: "#"; case .text: "Aa"; case .boolean: "◐"; case .temporal: "◷"; case .nested: "{}"; case .binary: "01" } }
}
public struct SortKey: Hashable, Sendable { public var column: String; public var ascending: Bool
    public init(_ column: String, ascending: Bool = true) { self.column = column; self.ascending = ascending }
}
public enum Aggregate: String, CaseIterable, Sendable { case sum, avg, min, max, count, distinct, uniq, nulls }
public enum FilterOperator: String, CaseIterable, Sendable { case equals = "=", notEquals = "!=", greater = ">", less = "<", contains, startsWith, isNull, isNotNull }
public struct FilterRule: Identifiable, Sendable {
    public let id = UUID()
    public var column: String; public var op: FilterOperator; public var value: String
    public init(column: String, op: FilterOperator = .contains, value: String = "") { self.column = column; self.op = op; self.value = value }
}
public struct ViewState: Sendable {
    public var filter = ""
    public var sorts: [SortKey] = []
    public var columns: [Column] = []
    public var groups: [String] = []
    public var aggregates: [String: Aggregate] = [:]
    public init() {}
}
public struct SQL: Sendable, Equatable {
    public var text: String; public var parameters: [String?]
    public init(_ text: String, _ parameters: [String?] = []) { self.text = text; self.parameters = parameters }
}
public enum QueryError: Error, LocalizedError { case invalidFilter
    public var errorDescription: String? { "Enter a single WHERE expression; statements and comments are not allowed." }
}
public enum Planner {
    public static func identifier(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    public static func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    public static func validateFilter(_ text: String) throws {
        // A WHERE expression is embedded inside a SELECT. Reject statement/comment delimiters outside literals.
        var quote: Character?; var previous: Character?; var closed = false
        for char in text {
            if let q = quote { if char == q { quote = nil }; previous = char; continue }
            if char == "'" || char == "\"" { quote = char }
            if char == ";" || (previous == "-" && char == "-") || (previous == "/" && char == "*") { closed = true }
            previous = char
        }
        if closed || quote != nil { throw QueryError.invalidFilter }
    }
    public static func predicate(_ rules: [FilterRule], any: Bool) -> SQL {
        var values: [String?] = []
        let parts = rules.map { r -> String in
            let c = identifier(r.column)
            switch r.op {
            case .isNull: return "\(c) IS NULL"
            case .isNotNull: return "\(c) IS NOT NULL"
            case .contains: values.append(r.value); return "contains(lower(CAST(\(c) AS VARCHAR)), lower(?))"
            case .startsWith: values.append(r.value); return "starts_with(lower(CAST(\(c) AS VARCHAR)), lower(?))"
            default: values.append(r.value); return "\(c) \(r.op.rawValue) ?"
            }
        }
        return SQL(parts.map { "(\($0))" }.joined(separator: any ? " OR " : " AND "), values)
    }
    public static func display(_ column: Column, alias: String? = nil, full: Bool = false) -> String {
        let c = (alias.map { identifier($0) + "." } ?? "") + identifier(column.name)
        let expression: String
        if full { expression = "CAST(\(c) AS VARCHAR)" }
        else if column.type.contains("[") { expression = "left(CAST(list_slice(\(c), 1, 8) AS VARCHAR), 160)" }
        else if column.kind == .binary { expression = "concat('⟨', octet_length(\(c)), ' bytes⟩')" }
        else { expression = "left(CAST(\(c) AS VARCHAR), 160)" }
        return "\(expression) AS \(identifier(column.name))"
    }
    public static func order(_ keys: [SortKey]) -> String { keys.isEmpty ? "" : " ORDER BY " + keys.map { identifier($0.column) + ($0.ascending ? " ASC" : " DESC") + " NULLS LAST" }.joined(separator: ", ") }
    public static func aggregate(_ op: Aggregate, column: String) -> String {
        let c = identifier(column)
        switch op {
        case .distinct: return "approx_count_distinct(\(c))"
        case .uniq: return "CASE WHEN min(\(c)) = max(\(c)) THEN min(\(c)) END"
        case .nulls: return "count(*) - count(\(c))"
        default: return "\(op.rawValue)(\(c))"
        }
    }
    public static func csv(_ rows: [[String?]], separator: String = ",") -> String {
        rows.map { row in row.map { cell in
            guard let cell else { return "" }
            return cell.contains(separator) || cell.contains("\"") || cell.contains("\n") || cell.contains("\r") ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
        }.joined(separator: separator) }.joined(separator: "\n")
    }
}

public enum AskQuery {
    public static func validate(_ sql: String) throws -> String {
        var value = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models often wrap otherwise valid SQL in a code block or add the
        // conventional terminating semicolon. Normalize only that outer syntax.
        if value.hasPrefix("```"), value.hasSuffix("```"), let newline = value.firstIndex(of:"\n") {
            let language = value[value.index(value.startIndex,offsetBy:3)..<newline].lowercased()
            if ["", "sql", "duckdb"].contains(language) {
                value = String(value[value.index(after:newline)..<value.index(value.endIndex,offsetBy:-3)])
                    .trimmingCharacters(in:.whitespacesAndNewlines)
            }
        }
        if value.hasSuffix(";") { value.removeLast(); value = value.trimmingCharacters(in:.whitespacesAndNewlines) }
        guard value.utf8.count <= 20_000 else { throw EngineQueryError.invalidAsk("The generated query is too long.") }
        do { try Planner.validateFilter(value) }
        catch { throw EngineQueryError.invalidAsk("Ask needs one SELECT query without extra statements or SQL comments.") }
        // Remove literals before checking SQL syntax. String values cannot supply
        // a relation name, function, or statement keyword.
        var outside = ""; var inString = false
        for char in value {
            if char == "'" { inString.toggle(); outside.append(" ") }
            else { outside.append(inString ? " " : char) }
        }
        guard outside.range(of: #"^\s*SELECT\b"#, options:[.regularExpression,.caseInsensitive]) != nil else {
            throw EngineQueryError.invalidAsk("Ask can run SELECT queries only.")
        }
        let relationPattern = #"\b(?:FROM|JOIN)\s+([\w\"]+)"#
        let regex = try NSRegularExpression(pattern:relationPattern,options:[.caseInsensitive])
        let range = NSRange(outside.startIndex..<outside.endIndex,in:outside)
        let relations = regex.matches(in:outside,range:range).compactMap { match -> String? in
            guard let r = Range(match.range(at:1),in:outside) else { return nil }
            return String(outside[r]).replacingOccurrences(of:"\"",with:"").lowercased()
        }
        guard !relations.isEmpty, relations.allSatisfy({ $0 == "scan_data" }) else {
            throw EngineQueryError.invalidAsk("The query must read only the open table, scan_data.")
        }
        if outside.range(of:#"\b(?:read_csv|read_parquet|read_json|read_text|sqlite_scan|query|attach|copy|install|load)\s*\("#,options:[.regularExpression,.caseInsensitive]) != nil {
            throw EngineQueryError.invalidAsk("The query calls a function that can read other files.")
        }
        return value
    }
}
public enum EngineQueryError: Error, LocalizedError {
    case invalidAsk(String)
    public var errorDescription: String? { if case let .invalidAsk(message) = self { message } else { nil } }
}
public struct RowPage: Sendable {
    public let offset: Int; public let columns: [[String?]]
    public var count: Int { columns.first?.count ?? 0 }
    public var byteCount: Int { columns.reduce(0) { $0 + $1.reduce(0) { $0 + ($1?.utf8.count ?? 0) + 24 } } }
    public init(offset: Int, columns: [[String?]]) { self.offset = offset; self.columns = columns }
    public func row(_ index: Int) -> [String?] { columns.map { $0[index] } }
}
public struct PivotNode: Identifiable, Sendable {
    public var id: UUID = UUID(); public var path: [String?]; public var values: [String?]; public var children: [PivotNode]?; public var expanded = false
    public init(path: [String?], values: [String?]) { self.path = path; self.values = values }
    public var flattened: [PivotNode] { [self] + (expanded ? (children ?? []).flatMap(\.flattened) : []) }
}
