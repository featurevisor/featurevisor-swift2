import Foundation

public typealias FeatureKey = String
public typealias SegmentKey = String
public typealias RuleKey = String
public typealias VariableKey = String
public typealias VariationValue = String
public typealias Context = [String: AnyValue]
public typealias VariableValue = AnyValue
public typealias StickyFeatures = [FeatureKey: EvaluatedFeature]
public typealias StickyVariables = [VariableKey: VariableValue]
public typealias EvaluatedFeatures = [FeatureKey: EvaluatedFeature]
public typealias EvaluatedVariables = [VariableKey: VariableValue]

public struct DatafileContent: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var revision: String
    public var featurevisorVersion: String?
    public var segments: [SegmentKey: Segment]
    public var features: [FeatureKey: Feature]
    public var variables: [VariableKey: GlobalVariable]?

    public init(
        schemaVersion: String,
        revision: String,
        featurevisorVersion: String? = nil,
        segments: [SegmentKey: Segment],
        features: [FeatureKey: Feature],
        variables: [VariableKey: GlobalVariable]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.featurevisorVersion = featurevisorVersion
        self.segments = segments
        self.features = features
        self.variables = variables
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
    public var conditions: Condition?
    public var requiredFeatures: [RequiredFeature]?
    public var variablesSchema: [VariableKey: ResolvedVariableSchema]?
    public var disabledVariationValue: VariationValue?
    public var variations: [Variation]?
    public var bucketBy: BucketBy
    public var traffic: [Traffic]
    public var force: [Force]?
}

public enum RequiredFeature: Codable, Equatable, Sendable {
    case feature(FeatureKey)
    case options(FeatureCondition)
    case and([RequiredFeature])
    case or([RequiredFeature])
    case not([RequiredFeature])

    private enum CodingKeys: String, CodingKey {
        case and, or, not
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let key = try? container.decode(String.self) {
            self = .feature(key)
            return
        }
        if let options = try? container.decode(FeatureCondition.self) {
            self = .options(options)
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if let values = try keyed.decodeIfPresent([RequiredFeature].self, forKey: .and) {
            self = .and(values)
        } else if let values = try keyed.decodeIfPresent([RequiredFeature].self, forKey: .or) {
            self = .or(values)
        } else if let values = try keyed.decodeIfPresent([RequiredFeature].self, forKey: .not) {
            self = .not(values)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid required feature")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .feature(let key): try container.encode(key)
        case .options(let options): try container.encode(options)
        case .and(let values): try container.encode(["and": values])
        case .or(let values): try container.encode(["or": values])
        case .not(let values): try container.encode(["not": values])
        }
    }
}

public struct FeatureCondition: Codable, Equatable, Sendable {
    public var feature: FeatureKey
    public var enabled: Bool?
    public var variation: VariationValue?

    public init(feature: FeatureKey, enabled: Bool? = nil, variation: VariationValue? = nil) {
        self.feature = feature
        self.enabled = enabled
        self.variation = variation
    }
}

public enum VariableConditionPathPart: Codable, Equatable, Sendable {
    case key(String)
    case index(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .index(value)
        } else {
            self = .key(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .key(let value): try container.encode(value)
        case .index(let value): try container.encode(value)
        }
    }
}

public struct VariableCondition: Codable, Equatable, Sendable {
    public var feature: FeatureKey?
    public var variable: VariableKey
    public var path: [VariableConditionPathPart]?
    public var `operator`: String
    public var value: AnyValue?
    public var regexFlags: String?

    private enum CodingKeys: String, CodingKey {
        case feature, variable, path, `operator`, value, regexFlags
    }

    public init(
        feature: FeatureKey? = nil,
        variable: VariableKey,
        path: [VariableConditionPathPart]? = nil,
        operator op: String,
        value: AnyValue? = nil,
        regexFlags: String? = nil
    ) {
        self.feature = feature
        self.variable = variable
        self.path = path
        self.operator = op
        self.value = value
        self.regexFlags = regexFlags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feature = try container.decodeIfPresent(String.self, forKey: .feature)
        variable = try container.decode(String.self, forKey: .variable)
        path = try container.decodeIfPresent([VariableConditionPathPart].self, forKey: .path)
        `operator` = try container.decode(String.self, forKey: .operator)
        value = container.contains(.value)
            ? (try container.decodeIfPresent(AnyValue.self, forKey: .value) ?? .null)
            : nil
        regexFlags = try container.decodeIfPresent(String.self, forKey: .regexFlags)
    }
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
    public var key: String?
    public var keyPath: [String]?
    public var value: VariableValue
    public var conditions: Condition?
    public var segments: GroupSegment?
    public var requiredFeatures: [RequiredFeature]?
}

public struct VariableMutationSelector: Codable, Equatable, Sendable {
    public var property: String
    public var values: [AnyValue]
}

public struct VariableMutationSelection: Codable, Equatable, Sendable {
    public var select: VariableMutationSelector
}

public enum VariableMutationPathPart: Codable, Equatable, Sendable {
    case key(String)
    case index(Int)
    case selector(VariableMutationSelector)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .index(value)
        } else if let value = try? container.decode(String.self) {
            self = .key(value)
        } else {
            self = .selector(try container.decode(VariableMutationSelection.self).select)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .key(let value): try container.encode(value)
        case .index(let value): try container.encode(value)
        case .selector(let value): try container.encode(VariableMutationSelection(select: value))
        }
    }
}

public struct VariableMutationOperation: Codable, Equatable, Sendable {
    public var op: String
    public var path: [VariableMutationPathPart]
    public var value: AnyValue?

    private enum CodingKeys: String, CodingKey {
        case op, path, value
    }

    public init(op: String, path: [VariableMutationPathPart], value: AnyValue? = nil) {
        self.op = op
        self.path = path
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(String.self, forKey: .op)
        path = try container.decode([VariableMutationPathPart].self, forKey: .path)
        value = container.contains(.value)
            ? (try container.decodeIfPresent(AnyValue.self, forKey: .value) ?? .null)
            : nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(op, forKey: .op)
        try container.encode(path, forKey: .path)
        if let value { try container.encode(value, forKey: .value) }
    }
}

public struct VariableOverrideProgramStep: Codable, Equatable, Sendable {
    public var key: String
    public var keyPath: [String]?
    public var operations: [VariableMutationOperation]
    public var onMatch: Int
    public var onMiss: Int
    public var conditions: Condition?
    public var segments: GroupSegment?
    public var requiredFeatures: [RequiredFeature]?
}

public struct GlobalVariable: Codable, Equatable, Sendable {
    public var conditions: Condition?
    public var hash: String?
    public var type: String
    public var defaultValue: VariableValue?
    public var compose: Composition?
    public var deprecated: Bool?
    public var disabledValue: VariableValue?
    public var useDefaultWhenDisabled: Bool?
    public var requiredFeatures: [RequiredFeature]?
    public var overrides: [VariableOverride]?
    public var overrideProgram: [VariableOverrideProgramStep]?

    private enum CodingKeys: String, CodingKey {
        case hash, type, defaultValue, disabledValue, useDefaultWhenDisabled, conditions, compose, deprecated
        case requiredFeatures, overrides, overrideProgram
    }

    public init(
        hash: String? = nil,
        type: String,
        defaultValue: VariableValue? = nil,
        conditions: Condition? = nil,
        compose: Composition? = nil,
        disabledValue: VariableValue? = nil,
        useDefaultWhenDisabled: Bool? = nil,
        requiredFeatures: [RequiredFeature]? = nil,
        overrides: [VariableOverride]? = nil,
        overrideProgram: [VariableOverrideProgramStep]? = nil
    ) {
        self.conditions = conditions
        self.compose = compose
        self.hash = hash
        self.type = type
        self.defaultValue = defaultValue
        self.disabledValue = disabledValue
        self.useDefaultWhenDisabled = useDefaultWhenDisabled
        self.requiredFeatures = requiredFeatures
        self.overrides = overrides
        self.overrideProgram = overrideProgram
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decodeIfPresent(String.self, forKey: .hash)
        type = try container.decode(String.self, forKey: .type)
        defaultValue = container.contains(.defaultValue)
            ? (try container.decodeIfPresent(AnyValue.self, forKey: .defaultValue) ?? .null)
            : nil
        conditions = container.contains(.conditions)
            ? (try container.decodeIfPresent(Condition.self, forKey: .conditions) ?? .null)
            : nil
        compose = try container.decodeIfPresent(Composition.self, forKey: .compose)
        deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
        disabledValue = container.contains(.disabledValue)
            ? (try container.decodeIfPresent(AnyValue.self, forKey: .disabledValue) ?? .null)
            : nil
        useDefaultWhenDisabled = try container.decodeIfPresent(Bool.self, forKey: .useDefaultWhenDisabled)
        requiredFeatures = try container.decodeIfPresent([RequiredFeature].self, forKey: .requiredFeatures)
        overrides = try container.decodeIfPresent([VariableOverride].self, forKey: .overrides)
        overrideProgram = try container.decodeIfPresent([VariableOverrideProgramStep].self, forKey: .overrideProgram)
    }
}

public struct ResolvedVariableSchema: Codable, Equatable, Sendable {
    public var deprecated: Bool?
    public var key: VariableKey?
    public var type: String
    public var defaultValue: VariableValue
    public var description: String?
    public var useDefaultWhenDisabled: Bool?
    public var disabledValue: VariableValue?

    private enum CodingKeys: String, CodingKey {
        case deprecated, key, type, defaultValue, description, useDefaultWhenDisabled, disabledValue
    }

    public init(
        deprecated: Bool? = nil,
        key: VariableKey? = nil,
        type: String,
        defaultValue: VariableValue,
        description: String? = nil,
        useDefaultWhenDisabled: Bool? = nil,
        disabledValue: VariableValue? = nil
    ) {
        self.deprecated = deprecated
        self.key = key
        self.type = type
        self.defaultValue = defaultValue
        self.description = description
        self.useDefaultWhenDisabled = useDefaultWhenDisabled
        self.disabledValue = disabledValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        type = try container.decode(String.self, forKey: .type)
        defaultValue = try container.decode(AnyValue.self, forKey: .defaultValue)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        useDefaultWhenDisabled = try container.decodeIfPresent(Bool.self, forKey: .useDefaultWhenDisabled)
        disabledValue = container.contains(.disabledValue)
            ? (try container.decodeIfPresent(AnyValue.self, forKey: .disabledValue) ?? .null)
            : nil
    }
}

public struct Traffic: Codable, Equatable, Sendable {
    public var key: RuleKey
    public var segments: GroupSegment?
    public var conditions: Condition?
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

public struct CompositionEntry: Codable, Equatable, Sendable {
    public var key: String
    public var feature: String?
    public var variable: String?
    public var variation: Bool?

    public init(key: String, feature: String? = nil, variable: String? = nil, variation: Bool? = nil) {
        self.key = key
        self.feature = feature
        self.variable = variable
        self.variation = variation
    }
}

public enum Composition: Codable, Equatable, Sendable {
    case alias(String)
    case members([CompositionEntry])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let key = try? container.decode(String.self) { self = .alias(key) }
        else { self = .members(try container.decode([CompositionEntry].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .alias(let key): try container.encode(key)
        case .members(let entries): try container.encode(entries)
        }
    }
}

extension Feature {
    private enum DecodeKeys: String, CodingKey {
        case key, hash, deprecated, conditions, requiredFeatures, variablesSchema, disabledVariationValue, variations, bucketBy, traffic, force
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodeKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        hash = try container.decodeIfPresent(String.self, forKey: .hash)
        deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
        conditions = container.contains(.conditions)
            ? (try container.decodeIfPresent(Condition.self, forKey: .conditions) ?? .null)
            : nil
        requiredFeatures = try container.decodeIfPresent([RequiredFeature].self, forKey: .requiredFeatures)
        variablesSchema = try container.decodeIfPresent([String: ResolvedVariableSchema].self, forKey: .variablesSchema)
        disabledVariationValue = try container.decodeIfPresent(String.self, forKey: .disabledVariationValue)
        variations = try container.decodeIfPresent([Variation].self, forKey: .variations)
        bucketBy = try container.decodeIfPresent(BucketBy.self, forKey: .bucketBy) ?? .single("userId")
        traffic = try container.decodeIfPresent([Traffic].self, forKey: .traffic) ?? []
        force = try container.decodeIfPresent([Force].self, forKey: .force)
    }
}
