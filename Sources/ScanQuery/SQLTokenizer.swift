import Foundation

/// Splits SQL into the spans a syntax highlighter colors. Plain text between spans is left out.
public enum SQLTokenizer {
    public enum Kind: Sendable, Equatable { case keyword, string, number, quotedIdentifier, function, comment }
    public struct Token: Sendable, Equatable {
        public let range: NSRange
        public let kind: Kind
    }
    private static let keywords = [
        "select", "from", "where", "group", "by", "order", "having", "limit", "offset", "distinct", "as", "and", "or", "not", "in", "is", "null",
        "like", "ilike", "between", "case", "when", "then", "else", "end", "join", "left", "right", "inner", "outer", "full", "cross", "on", "using",
        "union", "all", "intersect", "except", "with", "asc", "desc", "nulls", "first", "last", "true", "false", "cast", "over", "partition",
        "window", "filter", "exists", "any", "some", "interval", "unnest", "qualify", "similar", "to", "escape", "glob", "collate", "try_cast", "values"
    ]
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
    private static let keywordPattern = regex("\\b(?:" + keywords.joined(separator: "|") + ")\\b")
    private static let numberPattern = regex("(?<![\\w.])\\d+(?:\\.\\d+)?(?:e[+-]?\\d+)?\\b")
    private static let functionPattern = regex("\\b[a-z_][a-z0-9_]*(?=\\s*\\()")
    private static let identifierPattern = regex("\"(?:[^\"]|\"\")*\"?")
    private static let stringPattern = regex("'(?:[^']|'')*'?")
    private static let commentPattern = try! NSRegularExpression(pattern: "--[^\\n]*|/\\*[\\s\\S]*?(?:\\*/|$)")

    /// Tokens in paint order: later ones sit on top of earlier ones, so a keyword inside a string
    /// or comment ends up with the string or comment color.
    public static func tokens(in text: String) -> [Token] {
        let whole = NSRange(text.startIndex..., in: text)
        var result: [Token] = []
        func add(_ expression: NSRegularExpression, _ kind: Kind) {
            expression.enumerateMatches(in: text, range: whole) { match, _, _ in
                if let range = match?.range, range.length > 0 { result.append(Token(range: range, kind: kind)) }
            }
        }
        add(numberPattern, .number); add(functionPattern, .function); add(keywordPattern, .keyword)
        add(identifierPattern, .quotedIdentifier); add(stringPattern, .string); add(commentPattern, .comment)
        return result
    }
}
