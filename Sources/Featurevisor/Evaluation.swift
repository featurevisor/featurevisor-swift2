import Foundation

public enum EvaluationType: String, Codable, Sendable {
    case flag
    case variation
    case variable
}

public enum EvaluationReason: String, Codable, Sendable {
    case featureNotFound = "feature_not_found"
    case disabled = "disabled"
    case required = "required"
    case outOfRange = "out_of_range"
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

public struct Evaluation: Codable, Sendable {
    public var type: EvaluationType
    public var featureKey: FeatureKey
    public var reason: EvaluationReason

    public var bucketKey: String?
    public var bucketValue: Int?
    public var ruleKey: RuleKey?
    public var enabled: Bool?
    public var forceIndex: Int?
    public var force: Force?
    public var required: [RequiredValue]?
    public var traffic: Traffic?
    public var variation: Variation?
    public var variationValue: VariationValue?
    public var variableKey: VariableKey?
    public var variableValue: VariableValue?
    public var variableSchema: ResolvedVariableSchema?
    public var variableOverrideIndex: Int?
    public var sticky: EvaluatedFeature?
    public var error: String?

    public init(type: EvaluationType, featureKey: FeatureKey, reason: EvaluationReason) {
        self.type = type
        self.featureKey = featureKey
        self.reason = reason
    }
}

public struct OverrideOptions: Sendable {
    public var sticky: StickyFeatures?
    public var defaultVariationValue: VariationValue?
    public var defaultVariableValue: VariableValue?

    public init(
        sticky: StickyFeatures? = nil,
        defaultVariationValue: VariationValue? = nil,
        defaultVariableValue: VariableValue? = nil
    ) {
        self.sticky = sticky
        self.defaultVariationValue = defaultVariationValue
        self.defaultVariableValue = defaultVariableValue
    }
}
