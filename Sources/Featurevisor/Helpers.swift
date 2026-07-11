import Foundation

public func getValueByType(_ value: AnyValue?, fieldType: String) -> AnyValue? {
    guard let value else { return nil }

    switch fieldType {
    case "string":
        return value.asString().map(AnyValue.string)
    case "integer":
        if case .int(let int) = value { return .int(int) }
        if case .double(let double) = value, double.isFinite, double.rounded(.towardZero) == double {
            return .int(Int(double))
        }
        return nil
    case "double":
        if case .double(let double) = value, double.isFinite { return .double(double) }
        if case .int(let int) = value { return .double(Double(int)) }
        return nil
    case "boolean":
        return value.asBool().map(AnyValue.bool)
    case "array":
        return value.asArray().map(AnyValue.array)
    case "object":
        return value.asObject().map(AnyValue.object)
    default:
        return value
    }
}
