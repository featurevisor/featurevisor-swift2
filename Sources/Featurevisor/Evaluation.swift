import Foundation

public enum EvaluationType: String, Codable, Sendable {
    case flag
    case variation
    case variable
}

public enum EvaluationReason: String, Codable, Sendable {
    case featureNotFound = "feature_not_found"
    case disabled = "disabled"
    case conditionsUnmet = "conditions_unmet"
    case variableComposed = "variable_composed"
    case noVariations = "no_variations"
    case variationDisabled = "variation_disabled"
    case variableNotFound = "variable_not_found"
    case variableDefault = "variable_default"
    case variableDisabled = "variable_disabled"
    case variableOverrideVariation = "variable_override_variation"
    case variableOverrideRule = "variable_override_rule"
    case noMatch = "no_match"
    case forced = "forced"
    case sticky = "sticky"
    case rule = "rule"
    case allocated = "allocated"
    case error
}

private struct EvaluationFields: Codable, Sendable {
    public var type: EvaluationType
    public var featureKey: FeatureKey?
    public var reason: EvaluationReason

    public var bucketKey: String?
    public var bucketValue: Int?
    public var ruleKey: RuleKey?
    public var enabled: Bool?
    public var forceIndex: Int?
    public var force: Force?
    public var conditions: Condition?
    public var traffic: Traffic?
    public var variation: Variation?
    public var variationValue: VariationValue?
    public var variableKey: VariableKey?
    public var variableValue: VariableValue?
    public var variableSchema: ResolvedVariableSchema?
    public var globalVariable: GlobalVariable?
    public var variableOverrideIndex: Int?
    public var variableOverrideKey: String?
    public var variableOverridePath: [String]?
    public var variableOverridePaths: [[String]]?
    public var stickyFeature: EvaluatedFeature?
    public var error: String?

    public init(type: EvaluationType, featureKey: FeatureKey? = nil, reason: EvaluationReason) {
        self.type = type
        self.featureKey = featureKey
        self.reason = reason
    }
}

// Copy on write storage keeps recursive getter frames small without sharing
// mutable evaluation metadata between modules or returned snapshots.
private final class EvaluationStorage: @unchecked Sendable {
    var fields: EvaluationFields
    init(_ fields: EvaluationFields) { self.fields = fields }
}

public struct Evaluation: Codable, Sendable {
    private var storage: EvaluationStorage

    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&storage) { storage = EvaluationStorage(storage.fields) }
    }

    public init(type: EvaluationType, featureKey: FeatureKey? = nil, reason: EvaluationReason) {
        storage = EvaluationStorage(EvaluationFields(type: type, featureKey: featureKey, reason: reason))
    }

    public init(from decoder: Decoder) throws {
        storage = EvaluationStorage(try EvaluationFields(from: decoder))
    }

    public func encode(to encoder: Encoder) throws { try storage.fields.encode(to: encoder) }

    public var type: EvaluationType {
        get { storage.fields.type }
        set { ensureUnique(); storage.fields.type = newValue }
    }

    public var featureKey: FeatureKey? {
        get { storage.fields.featureKey }
        set { ensureUnique(); storage.fields.featureKey = newValue }
    }

    public var reason: EvaluationReason {
        get { storage.fields.reason }
        set { ensureUnique(); storage.fields.reason = newValue }
    }

    public var bucketKey: String? {
        get { storage.fields.bucketKey }
        set { ensureUnique(); storage.fields.bucketKey = newValue }
    }

    public var bucketValue: Int? {
        get { storage.fields.bucketValue }
        set { ensureUnique(); storage.fields.bucketValue = newValue }
    }

    public var ruleKey: RuleKey? {
        get { storage.fields.ruleKey }
        set { ensureUnique(); storage.fields.ruleKey = newValue }
    }

    public var enabled: Bool? {
        get { storage.fields.enabled }
        set { ensureUnique(); storage.fields.enabled = newValue }
    }

    public var forceIndex: Int? {
        get { storage.fields.forceIndex }
        set { ensureUnique(); storage.fields.forceIndex = newValue }
    }

    public var force: Force? {
        get { storage.fields.force }
        set { ensureUnique(); storage.fields.force = newValue }
    }

    public var conditions: Condition? {
        get { storage.fields.conditions }
        set { ensureUnique(); storage.fields.conditions = newValue }
    }

    public var traffic: Traffic? {
        get { storage.fields.traffic }
        set { ensureUnique(); storage.fields.traffic = newValue }
    }

    public var variation: Variation? {
        get { storage.fields.variation }
        set { ensureUnique(); storage.fields.variation = newValue }
    }

    public var variationValue: VariationValue? {
        get { storage.fields.variationValue }
        set { ensureUnique(); storage.fields.variationValue = newValue }
    }

    public var variableKey: VariableKey? {
        get { storage.fields.variableKey }
        set { ensureUnique(); storage.fields.variableKey = newValue }
    }

    public var variableValue: VariableValue? {
        get { storage.fields.variableValue }
        set { ensureUnique(); storage.fields.variableValue = newValue }
    }

    public var variableSchema: ResolvedVariableSchema? {
        get { storage.fields.variableSchema }
        set { ensureUnique(); storage.fields.variableSchema = newValue }
    }

    public var globalVariable: GlobalVariable? {
        get { storage.fields.globalVariable }
        set { ensureUnique(); storage.fields.globalVariable = newValue }
    }

    public var variableOverrideIndex: Int? {
        get { storage.fields.variableOverrideIndex }
        set { ensureUnique(); storage.fields.variableOverrideIndex = newValue }
    }

    public var variableOverrideKey: String? {
        get { storage.fields.variableOverrideKey }
        set { ensureUnique(); storage.fields.variableOverrideKey = newValue }
    }

    public var variableOverridePath: [String]? {
        get { storage.fields.variableOverridePath }
        set { ensureUnique(); storage.fields.variableOverridePath = newValue }
    }

    public var variableOverridePaths: [[String]]? {
        get { storage.fields.variableOverridePaths }
        set { ensureUnique(); storage.fields.variableOverridePaths = newValue }
    }

    public var stickyFeature: EvaluatedFeature? {
        get { storage.fields.stickyFeature }
        set { ensureUnique(); storage.fields.stickyFeature = newValue }
    }

    public var error: String? {
        get { storage.fields.error }
        set { ensureUnique(); storage.fields.error = newValue }
    }
}

public struct OverrideOptions: Sendable {
    // Instance-internal transport for child sticky state. Sticky values are
    // configured on an instance, never supplied for an individual evaluation.
    var stickyFeatures: StickyFeatures?
    var stickyVariables: StickyVariables?
    var stickySource: StickySourceHandle?
    public var defaultVariationValue: VariationValue?
    public var defaultVariableValue: VariableValue?

    public init(
        defaultVariationValue: VariationValue? = nil,
        defaultVariableValue: VariableValue? = nil
    ) {
        self.stickyFeatures = nil
        self.stickyVariables = nil
        self.stickySource = nil
        self.defaultVariationValue = defaultVariationValue
        self.defaultVariableValue = defaultVariableValue
    }
}

public struct SpawnOptions: Sendable {
    public var stickyFeatures: StickyFeatures?
    public var stickyVariables: StickyVariables?

    public init(stickyFeatures: StickyFeatures? = nil, stickyVariables: StickyVariables? = nil) {
        self.stickyFeatures = stickyFeatures
        self.stickyVariables = stickyVariables
    }
}
