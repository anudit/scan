import Foundation

/// A minimal implementation of the Thrift compact protocol, enough to read and rewrite
/// Parquet footers. Values keep their original wire type so unknown fields round-trip.
enum ThriftType: UInt8, Sendable {
    case booleanTrue = 1
    case booleanFalse = 2
    case byte = 3
    case i16 = 4
    case i32 = 5
    case i64 = 6
    case double = 7
    case binary = 8
    case list = 9
    case set = 10
    case map = 11
    case structure = 12

    var isBoolean: Bool { self == .booleanTrue || self == .booleanFalse }
}

indirect enum ThriftValue: Sendable {
    case bool(Bool)
    case byte(UInt8)
    case i16(Int64)
    case i32(Int64)
    case i64(Int64)
    case double(Double)
    case binary(Data)
    case list(ThriftType, [ThriftValue])
    case set(ThriftType, [ThriftValue])
    case map(ThriftType, ThriftType, [ThriftMapEntry])
    case structure(ThriftStruct)

    var type: ThriftType {
        switch self {
        case .bool(let value): return value ? .booleanTrue : .booleanFalse
        case .byte: return .byte
        case .i16: return .i16
        case .i32: return .i32
        case .i64: return .i64
        case .double: return .double
        case .binary: return .binary
        case .list: return .list
        case .set: return .set
        case .map: return .map
        case .structure: return .structure
        }
    }

    var intValue: Int64? {
        switch self {
        case .byte(let value): return Int64(value)
        case .i16(let value), .i32(let value), .i64(let value): return value
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .bool(let value): return value ? 1 : 0
        default: return intValue.map(Double.init)
        }
    }

    var binaryValue: Data? {
        if case .binary(let value) = self { return value }
        return nil
    }

    var structValue: ThriftStruct? {
        if case .structure(let value) = self { return value }
        return nil
    }

    var listValue: [ThriftValue]? {
        if case .list(_, let value) = self { return value }
        return nil
    }

    var listElementType: ThriftType? {
        if case .list(let type, _) = self { return type }
        return nil
    }
}

struct ThriftMapEntry: Sendable {
    var key: ThriftValue
    var value: ThriftValue
}

struct ThriftStruct: Sendable {
    var fields: [(id: Int16, value: ThriftValue)] = []

    init() {}
    init(fields: [(id: Int16, value: ThriftValue)]) { self.fields = fields }

    func value(_ id: Int16) -> ThriftValue? {
        for field in fields where field.id == id { return field.value }
        return nil
    }

    func int(_ id: Int16) -> Int64? { value(id)?.intValue }

    mutating func set(_ id: Int16, _ value: ThriftValue) {
        if let index = fields.firstIndex(where: { $0.id == id }) { fields[index].value = value }
        else { fields.append((id, value)) }
    }

    mutating func remove(_ id: Int16) {
        fields.removeAll { $0.id == id }
    }

    var isEmpty: Bool { fields.isEmpty }
}

enum ThriftError: Error, LocalizedError {
    case truncated
    case unsupportedType(UInt8)
    case tooDeep
    case overflow

    var errorDescription: String? {
        switch self {
        case .truncated: return "The Parquet metadata ended unexpectedly."
        case .unsupportedType(let type): return "Unknown Parquet metadata type \(type)."
        case .tooDeep: return "The Parquet metadata is nested too deeply."
        case .overflow: return "The Parquet metadata contains an invalid length."
        }
    }
}

struct ThriftCompactReader {
    private let bytes: [UInt8]
    private var offset = 0
    private var depth = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func readStruct() throws -> ThriftStruct {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 64 else { throw ThriftError.tooDeep }
        var result = ThriftStruct()
        var lastID: Int16 = 0
        while true {
            let header = try readByte()
            if header == 0 { return result }
            let delta = Int16(header >> 4)
            let type = header & 0x0f
            let id: Int16
            if delta == 0 {
                let raw = try readZigZag()
                guard raw >= Int64(Int16.min), raw <= Int64(Int16.max) else { throw ThriftError.overflow }
                id = Int16(raw)
            } else {
                let (next, overflow) = lastID.addingReportingOverflow(delta)
                guard !overflow else { throw ThriftError.overflow }
                id = next
            }
            lastID = id
            result.fields.append((id, try readValue(type: type)))
        }
    }

    private mutating func readValue(type: UInt8) throws -> ThriftValue {
        guard let kind = ThriftType(rawValue: type) else { throw ThriftError.unsupportedType(type) }
        switch kind {
        case .booleanTrue: return .bool(true)
        case .booleanFalse: return .bool(false)
        case .byte: return .byte(try readByte())
        case .i16: return .i16(try readZigZag())
        case .i32:
            let value = try readZigZag()
            guard value >= Int64(Int32.min), value <= Int64(Int32.max) else { throw ThriftError.overflow }
            return .i32(value)
        case .i64: return .i64(try readZigZag())
        case .double:
            try need(8)
            var bits: UInt64 = 0
            for index in 0..<8 { bits |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
            offset += 8
            return .double(Double(bitPattern: bits))
        case .binary:
            let length = try readLength()
            try need(length)
            let data = Data(bytes[offset..<(offset + length)])
            offset += length
            return .binary(data)
        case .list, .set:
            let header = try readByte()
            var count = Int(header >> 4)
            let elementType = header & 0x0f
            if count == 15 { count = try readLength() }
            try need(count)
            var values: [ThriftValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try readValue(type: elementType)) }
            return kind == .list ? .list(ThriftType(rawValue: elementType) ?? .structure, values)
                                : .set(ThriftType(rawValue: elementType) ?? .structure, values)
        case .map:
            let count = try readLength()
            guard count > 0 else { return .map(.binary, .binary, []) }
            let header = try readByte()
            let keyType = header >> 4
            let valueType = header & 0x0f
            try need(count)
            var entries: [ThriftMapEntry] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                entries.append(ThriftMapEntry(key: try readValue(type: keyType), value: try readValue(type: valueType)))
            }
            return .map(ThriftType(rawValue: keyType) ?? .binary, ThriftType(rawValue: valueType) ?? .binary, entries)
        case .structure:
            return .structure(try readStruct())
        }
    }

    private mutating func need(_ count: Int) throws {
        guard count >= 0, count <= bytes.count - offset else { throw ThriftError.truncated }
    }

    private mutating func readByte() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readByte()
            if shift >= 64 { throw ThriftError.overflow }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func readLength() throws -> Int {
        let raw = try readVarint()
        guard raw <= UInt64(Int.max) else { throw ThriftError.overflow }
        return Int(raw)
    }

    private mutating func readZigZag() throws -> Int64 {
        let raw = try readVarint()
        return Int64(bitPattern: (raw >> 1) ^ (~(raw & 1) &+ 1))
    }
}

struct ThriftCompactWriter {
    private(set) var bytes: [UInt8] = []

    mutating func write(_ value: ThriftStruct) { writeStruct(value) }

    private mutating func writeStruct(_ value: ThriftStruct) {
        var lastID: Int16 = 0
        for field in value.fields {
            let delta = Int(field.id) - Int(lastID)
            let type = field.value.type
            if delta > 0 && delta <= 15 {
                bytes.append(UInt8(delta) << 4 | type.rawValue)
            } else {
                bytes.append(type.rawValue)
                writeZigZag(Int64(field.id))
            }
            lastID = field.id
            writeValue(field.value, type: type)
        }
        bytes.append(0)
    }

    private mutating func writeValue(_ value: ThriftValue, type: ThriftType) {
        switch value {
        case .bool:
            return
        case .byte(let byte):
            bytes.append(byte)
        case .i16(let number), .i32(let number), .i64(let number):
            writeZigZag(number)
        case .double(let number):
            let bits = number.bitPattern
            for index in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(index)))) }
        case .binary(let data):
            writeVarint(UInt64(data.count))
            bytes.append(contentsOf: data)
        case .list(let element, let values), .set(let element, let values):
            if values.count < 15 { bytes.append(UInt8(values.count) << 4 | element.rawValue) }
            else {
                bytes.append(0xf0 | element.rawValue)
                writeVarint(UInt64(values.count))
            }
            for elementValue in values { writeValue(elementValue, type: element) }
        case .map(let keyType, let valueType, let entries):
            writeVarint(UInt64(entries.count))
            if !entries.isEmpty {
                bytes.append(keyType.rawValue << 4 | valueType.rawValue)
                for entry in entries {
                    writeValue(entry.key, type: keyType)
                    writeValue(entry.value, type: valueType)
                }
            }
        case .structure(let structure):
            writeStruct(structure)
        }
    }

    private mutating func writeVarint(_ value: UInt64) {
        var remaining = value
        while true {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
            if remaining == 0 { return }
        }
    }

    private mutating func writeZigZag(_ value: Int64) {
        writeVarint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }
}
