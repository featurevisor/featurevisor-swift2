import Foundation

public typealias FeatureKey = String
public typealias SegmentKey = String
public typealias RuleKey = String
public typealias VariableKey = String
public typealias VariationValue = String
public typealias Context = [String: AnyValue]
public typealias VariableValue = AnyValue
public typealias StickyFeatures = [FeatureKey: EvaluatedFeature]
public typealias EvaluatedFeatures = [FeatureKey: EvaluatedFeature]

public struct DatafileContent: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var revision: String
    public var segments: [SegmentKey: Segment]
    public var features: [FeatureKey: Feature]

    public init(
        schemaVersion: String,
        revision: String,
        segments: [SegmentKey: Segment],
        features: [FeatureKey: Feature]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.segments = segments
        self.features = features
    }

    public static func fromJSON(_ json: String) throws -> DatafileContent {
        try fromData(Data(json.utf8))
    }

    public static func fromData(_ data: Data) throws -> DatafileContent {
        try JSONDecoder().decode(DatafileContent.self, from: data)
    }

    public func toJSON(pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct Segment: Codable, Equatable, Sendable {
    public var key: SegmentKey?
    public var conditions: SegmentConditions
}

public enum SegmentConditions: Codable, Equatable, Sendable {
    case tree(Condition)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        self = .tree(try container.decode(Condition.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .tree(let condition): try container.encode(condition)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct Feature: Codable, Equatable, Sendable {
    public var key: FeatureKey?
    public var hash: String?
    public var deprecated: Bool?
    public var required: [RequiredValue]?
    public var variablesSchema: [VariableKey: ResolvedVariableSchema]?
    public var disabledVariationValue: VariationValue?
    public var variations: [Variation]?
    public var bucketBy: BucketBy
    public var traffic: [Traffic]
    public var force: [Force]?
    public var ranges: [Range]?
}

public enum RequiredValue: Codable, Equatable, Sendable {
    case key(FeatureKey)
    case withVariation(RequiredWithVariation)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let key = try? container.decode(String.self) {
            self = .key(key)
            return
        }
        self = .withVariation(try container.decode(RequiredWithVariation.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .key(let key): try container.encode(key)
        case .withVariation(let value): try container.encode(value)
        }
    }
}

public struct RequiredWithVariation: Codable, Equatable, Sendable {
    public var key: FeatureKey
    public var variation: VariationValue
}

public enum BucketBy: Codable, Equatable, Sendable {
    case single(String)
    case and([String])
    case or(BucketByOr)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            self = .single(single)
            return
        }
        if let and = try? container.decode([String].self) {
            self = .and(and)
            return
        }
        self = .or(try container.decode(BucketByOr.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let value): try container.encode(value)
        case .and(let values): try container.encode(values)
        case .or(let value): try container.encode(value)
        }
    }
}

public struct BucketByOr: Codable, Equatable, Sendable {
    public var or: [String]
}

public struct Variation: Codable, Equatable, Sendable {
    public var description: String?
    public var value: VariationValue
    public var weight: Double?
    public var variables: [VariableKey: VariableValue]?
    public var variableOverrides: [VariableKey: [VariableOverride]]?
}

public struct VariableOverride: Codable, Equatable, Sendable {
    public var value: VariableValue
    public var conditions: Condition?
    public var segments: GroupSegment?
}

public struct ResolvedVariableSchema: Codable, Equatable, Sendable {
    public var deprecated: Bool?
    public var key: VariableKey?
    public var type: String
    public var defaultValue: VariableValue
    public var description: String?
    public var useDefaultWhenDisabled: Bool?
    public var disabledValue: VariableValue?
}

public struct Traffic: Codable, Equatable, Sendable {
    public var key: RuleKey
    public var segments: GroupSegment
    public var percentage: Int
    public var enabled: Bool?
    public var variation: VariationValue?
    public var variables: [String: VariableValue]?
    public var variationWeights: [String: Double]?
    public var variableOverrides: [VariableKey: [VariableOverride]]?
    public var allocation: [Allocation]?
}

public struct Allocation: Codable, Equatable, Sendable {
    public var variation: VariationValue
    public var range: Range
}

public typealias Range = [Int]

public struct Force: Codable, Equatable, Sendable {
    public var conditions: Condition?
    public var segments: GroupSegment?
    public var enabled: Bool?
    public var variation: VariationValue?
    public var variables: [String: VariableValue]?
}

public indirect enum GroupSegment: Codable, Equatable, Sendable {
    case all
    case key(String)
    case list([GroupSegment])
    case and([GroupSegment])
    case or([GroupSegment])
    case not([GroupSegment])

    private enum CodingKeys: String, CodingKey {
        case and, or, not
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let star = try? container.decode(String.self) {
            self = (star == "*") ? .all : .key(star)
            return
        }

        if let array = try? container.decode([GroupSegment].self) {
            self = .list(array)
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if let and = try keyed.decodeIfPresent([GroupSegment].self, forKey: .and) {
            self = .and(and)
        } else if let or = try keyed.decodeIfPresent([GroupSegment].self, forKey: .or) {
            self = .or(or)
        } else if let not = try keyed.decodeIfPresent([GroupSegment].self, forKey: .not) {
            self = .not(not)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid GroupSegment")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .all:
            var container = encoder.singleValueContainer()
            try container.encode("*")
        case .key(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .list(let values):
            var container = encoder.singleValueContainer()
            try container.encode(values)
        case .and(let values):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(values, forKey: .and)
        case .or(let values):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(values, forKey: .or)
        case .not(let values):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(values, forKey: .not)
        }
    }
}

public struct EvaluatedFeature: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var variation: VariationValue?
    public var variables: [VariableKey: VariableValue]?

    public init(enabled: Bool, variation: VariationValue? = nil, variables: [VariableKey: VariableValue]? = nil) {
        self.enabled = enabled
        self.variation = variation
        self.variables = variables
    }
}
