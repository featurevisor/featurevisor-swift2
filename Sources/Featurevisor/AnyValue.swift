import Foundation

public enum AnyValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyValue])
    case object([String: AnyValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var rawValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map(\ .rawValue)
        case .object(let value): return value.mapValues(\ .rawValue)
        case .null: return NSNull()
        }
    }

    public func asString() -> String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public func asBool() -> Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public func asInt() -> Int? {
        if case .int(let value) = self { return value }
        if case .double(let value) = self { return Int(value) }
        return nil
    }

    public func asDouble() -> Double? {
        if case .double(let value) = self { return value }
        if case .int(let value) = self { return Double(value) }
        return nil
    }

    public func asArray() -> [AnyValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public func asObject() -> [String: AnyValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
