import SwiftUI
import AppKit
import ScanTheme

/// A JSON value that keeps object keys in document order and numbers exactly as written.
enum JSONValue {
    case object([(key: String, value: JSONValue)]), array([JSONValue]), string(String), number(String), bool(Bool), null
    /// Parses text that holds a JSON object or array. Scalars and invalid JSON give nil.
    init?(parsing text: String) {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return nil }
        var parser = JSONParser(bytes: Array(text.utf8))
        guard let value = try? parser.value(), parser.atEnd() else { return nil }
        self = value
    }
    var children: [(label: String, isIndex: Bool, value: JSONValue)]? {
        switch self {
        case .object(let members): members.map { ($0.key, false, $0.value) }
        case .array(let items): items.enumerated().map { (String($0.offset), true, $0.element) }
        default: nil
        }
    }
    func pretty() -> String { var out = ""; write(to: &out, indent: 0); return out }
    private func write(to out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += pad + Self.quote(member.key) + ": "; member.value.write(to: &out, indent: indent + 1)
                out += index < members.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: "  ", count: indent) + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad; item.write(to: &out, indent: indent + 1)
                out += index < items.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: "  ", count: indent) + "]"
        case .string(let value): out += Self.quote(value)
        case .number(let value): out += value
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        }
    }
    static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

private struct JSONParser {
    struct Invalid: Error {}
    let bytes: [UInt8]
    var i = 0, depth = 0
    mutating func skip() { while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 } }
    mutating func atEnd() -> Bool { skip(); return i == bytes.count }
    mutating func consume(_ byte: Character) -> Bool {
        skip(); guard i < bytes.count, bytes[i] == byte.asciiValue else { return false }; i += 1; return true
    }
    mutating func expect(_ byte: Character) throws { guard consume(byte) else { throw Invalid() } }
    mutating func value() throws -> JSONValue {
        skip(); guard i < bytes.count else { throw Invalid() }
        switch bytes[i] {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            let object = bytes[i] == UInt8(ascii: "{"); i += 1
            depth += 1; defer { depth -= 1 }
            guard depth < 512 else { throw Invalid() }
            var members: [(key: String, value: JSONValue)] = [], items: [JSONValue] = []
            if !consume(object ? "}" : "]") {
                repeat {
                    if object { skip(); let key = try string(); try expect(":"); members.append((key, try value())) }
                    else { items.append(try value()) }
                } while consume(",")
                try expect(object ? "}" : "]")
            }
            return object ? .object(members) : .array(items)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default:
            let start = i
            while i < bytes.count, "+-.eE0123456789".utf8.contains(bytes[i]) { i += 1 }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard !text.isEmpty, Double(text) != nil else { throw Invalid() }
            return .number(text)
        }
    }
    mutating func literal(_ word: String) throws {
        let utf8 = Array(word.utf8)
        guard i + utf8.count <= bytes.count, Array(bytes[i..<i + utf8.count]) == utf8 else { throw Invalid() }
        i += utf8.count
    }
    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { throw Invalid() }
        i += 4; return value
    }
    mutating func string() throws -> String {
        guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw Invalid() }
        i += 1
        var out: [UInt8] = []
        while i < bytes.count {
            let byte = bytes[i]; i += 1
            if byte == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
            guard byte >= 0x20 else { throw Invalid() }
            guard byte == UInt8(ascii: "\\") else { out.append(byte); continue }
            guard i < bytes.count else { throw Invalid() }
            let escape = bytes[i]; i += 1
            switch escape {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4()
                // A high surrogate combines with a following \u low surrogate.
                if (0xD800...0xDBFF).contains(scalar), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                    let mark = i; i += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) { scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00) } else { i = mark }
                }
                out.append(contentsOf: String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8)
            default: throw Invalid()
            }
        }
        throw Invalid()
    }
}

/// An outline of a JSON cell. Click a row to expand it; right-click to copy its value or path.
struct JSONTreeView: View {
    let root: JSONValue
    @State private var expanded: Set<[Int]> = []
    private struct Row: Identifiable {
        var id: [Int] { path }
        let path: [Int], label: String, isIndex: Bool, value: JSONValue, jsonPath: String
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(summary(root)).foregroundStyle(.secondary)
                Spacer()
                Button("Expand All") { expanded = allPaths() }.buttonStyle(.link)
                Button("Collapse") { expanded = [] }.buttonStyle(.link)
            }.font(.system(size: 11))
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) { ForEach(rows) { row($0) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var rows: [Row] {
        var out: [Row] = []
        func visit(_ value: JSONValue, path: [Int], jsonPath: String) {
            for (index, child) in (value.children ?? []).enumerated() {
                let childPath = path + [index]
                let next = jsonPath + (child.isIndex ? "[\(child.label)]" : Self.pathComponent(child.label))
                out.append(Row(path: childPath, label: child.label, isIndex: child.isIndex, value: child.value, jsonPath: next))
                if expanded.contains(childPath) { visit(child.value, path: childPath, jsonPath: next) }
            }
        }
        visit(root, path: [], jsonPath: "$")
        return out
    }
    /// Containers to expand for Expand All, capped so a huge value stays responsive.
    private func allPaths(limit: Int = 5_000) -> Set<[Int]> {
        var out: Set<[Int]> = [], queue: [([Int], JSONValue)] = [([], root)]
        while !queue.isEmpty && out.count < limit {
            let (path, value) = queue.removeFirst()
            for (index, child) in (value.children ?? []).enumerated() where child.value.children != nil {
                out.insert(path + [index]); queue.append((path + [index], child.value))
            }
        }
        return out
    }
    private func row(_ row: Row) -> some View {
        let container = row.value.children != nil, open = expanded.contains(row.path)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10).opacity(container ? 1 : 0)
            Text(row.label).foregroundStyle(row.isIndex ? Color(nsColor: ScanTheme.muted) : Color(nsColor: ScanTheme.primary)).fontWeight(row.isIndex ? .regular : .medium)
            Text(":").foregroundStyle(.secondary)
            leaf(row.value).padding(.leading, 2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced)).lineLimit(container ? 1 : 4)
        .padding(.leading, CGFloat(row.path.count - 1) * 14).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { guard container else { return }; if open { expanded.remove(row.path) } else { expanded.insert(row.path) } }
        .help(row.jsonPath)
        .contextMenu {
            Button("Copy Value") { copy(Self.plain(row.value)) }
            Button("Copy Key") { copy(row.label) }
            Button("Copy Path") { copy(row.jsonPath) }
        }
    }
    @ViewBuilder private func leaf(_ value: JSONValue) -> some View {
        switch value {
        case .object, .array: Text(summary(value)).foregroundStyle(.secondary)
        case .string(let text): Text(JSONValue.quote(text)).foregroundStyle(Color(nsColor: ScanTheme.color(for: .boolean, value: "true")))
        case .number(let text): Text(text).foregroundStyle(Color(nsColor: ScanTheme.color(for: .number, value: text)))
        case .bool(let flag): Text(flag ? "true" : "false").foregroundStyle(Color(nsColor: ScanTheme.color(for: .nested, value: "true")))
        case .null: Text("null").foregroundStyle(Color(nsColor: ScanTheme.null))
        }
    }
    private func summary(_ value: JSONValue) -> String {
        switch value {
        case .object(let members): "{…} \(members.count) \(members.count == 1 ? "key" : "keys")"
        case .array(let items): "[…] \(items.count) \(items.count == 1 ? "item" : "items")"
        default: ""
        }
    }
    /// A DuckDB JSON path step: `.key`, or `."key"` when the key is not a plain identifier.
    static func pathComponent(_ key: String) -> String {
        let plain = !key.isEmpty && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" } && !(key.first?.isNumber ?? true)
        return plain ? "." + key : "." + JSONValue.quote(key)
    }
    private static func plain(_ value: JSONValue) -> String { if case .string(let text) = value { text } else { value.pretty() } }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
