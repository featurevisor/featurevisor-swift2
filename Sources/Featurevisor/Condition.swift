import Foundation

public indirect enum Condition: Codable, Equatable, Sendable {
    case all
    case null
    case invalid
    case feature(FeatureCondition)
    case variable(VariableCondition)
    case invalidToken(String)
    case predicate(ConditionPredicate)
    case and([Condition])
    case or([Condition])
    case not([Condition])
    case list([Condition])

    private enum CodingKeys: String, CodingKey {
        case and, or, not, variable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let token = try? container.decode(String.self) {
            self = token == "*" ? .all : .invalidToken(token)
            return
        }

        if let keyed = try? decoder.container(keyedBy: CodingKeys.self), keyed.contains(.variable) {
            self = .variable(try container.decode(VariableCondition.self))
            return
        }
        if let value = try? container.decode(FeatureCondition.self) {
            self = .feature(value)
            return
        }
        if let predicate = try? container.decode(ConditionPredicate.self) {
            self = .predicate(predicate)
            return
        }

        if let array = try? container.decode([Condition].self) {
            self = .list(array)
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if let and = try keyed.decodeIfPresent([Condition].self, forKey: .and) {
            self = .and(and)
        } else if let or = try keyed.decodeIfPresent([Condition].self, forKey: .or) {
            self = .or(or)
        } else if let not = try keyed.decodeIfPresent([Condition].self, forKey: .not) {
            self = .not(not)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid condition")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .invalid:
            var container = encoder.singleValueContainer()
            try container.encode(["or": [Condition]()])
        case .feature(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .variable(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .all:
            var container = encoder.singleValueContainer()
            try container.encode("*")
        case .invalidToken(let token):
            var container = encoder.singleValueContainer()
            try container.encode(token)
        case .predicate(let predicate):
            var container = encoder.singleValueContainer()
            try container.encode(predicate)
        case .list(let items):
            var container = encoder.singleValueContainer()
            try container.encode(items)
        case .and(let items):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(items, forKey: .and)
        case .or(let items):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(items, forKey: .or)
        case .not(let items):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(items, forKey: .not)
        }
    }
}

public struct ConditionPredicate: Codable, Equatable, Sendable {
    public var attribute: String
    public var `operator`: String
    public var value: AnyValue?
    public var regexFlags: String?

    private enum CodingKeys: String, CodingKey {
        case attribute, `operator`, value, regexFlags
    }

    public init(attribute: String, operator op: String, value: AnyValue? = nil, regexFlags: String? = nil) {
        self.attribute = attribute
        self.operator = op
        self.value = value
        self.regexFlags = regexFlags
    }


    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attribute = try container.decode(String.self, forKey: .attribute)
        `operator` = try container.decode(String.self, forKey: .operator)
        value = container.contains(.value)
            ? (try container.decodeIfPresent(AnyValue.self, forKey: .value) ?? .null)
            : nil
        regexFlags = try container.decodeIfPresent(String.self, forKey: .regexFlags)
    }
}
