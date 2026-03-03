import Foundation

public func getValueByType(_ value: AnyValue?, fieldType: String) -> AnyValue? {
    guard let value else { return nil }

    switch fieldType {
    case "string":
        return value.asString().map(AnyValue.string)
    case "integer":
        if let int = value.asInt() { return .int(int) }
        if case .string(let str) = value {
            if let parsed = Int(str) { return .int(parsed) }
            if let asDouble = Double(str) { return .int(Int(asDouble)) }
        }
        return nil
    case "double":
        if let double = value.asDouble() { return .double(double) }
        if case .string(let str) = value, let parsed = Double(str) { return .double(parsed) }
        return nil
    case "boolean":
        return .bool(value.asBool() == true)
    case "array":
        return value.asArray().map(AnyValue.array)
    case "object":
        return value.asObject().map(AnyValue.object)
    default:
        return value
    }
}
