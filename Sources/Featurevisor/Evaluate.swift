import Foundation

public struct EvaluateDependencies: Sendable {
    public var context: Context
    public var logger: Logger
    public var hooksManager: HooksManager
    public var datafileReader: DatafileReader
    public var sticky: StickyFeatures?
    public var defaultVariationValue: VariationValue?
    public var defaultVariableValue: VariableValue?

    public init(
        context: Context,
        logger: Logger,
        hooksManager: HooksManager,
        datafileReader: DatafileReader,
        sticky: StickyFeatures? = nil,
        defaultVariationValue: VariationValue? = nil,
        defaultVariableValue: VariableValue? = nil
    ) {
        self.context = context
        self.logger = logger
        self.hooksManager = hooksManager
        self.datafileReader = datafileReader
        self.sticky = sticky
        self.defaultVariationValue = defaultVariationValue
        self.defaultVariableValue = defaultVariableValue
    }
}

public struct EvaluateOptions: Sendable {
    public var type: EvaluationType
    public var featureKey: FeatureKey
    public var variableKey: VariableKey?
    public var dependencies: EvaluateDependencies

    public init(type: EvaluationType, featureKey: FeatureKey, variableKey: VariableKey? = nil, dependencies: EvaluateDependencies) {
        self.type = type
        self.featureKey = featureKey
        self.variableKey = variableKey
        self.dependencies = dependencies
    }
}

public func evaluateWithHooks(_ options: EvaluateOptions) -> Evaluation {
    var input = EvaluateInput(
        type: options.type,
        featureKey: options.featureKey,
        variableKey: options.variableKey,
        context: options.dependencies.context
    )

    input = options.dependencies.hooksManager.runBefore(input)
    var updated = options
    updated.dependencies.context = input.context

    var evaluation = evaluate(updated)

    if evaluation.type == .variation, evaluation.variationValue == nil,
       let defaultVariation = updated.dependencies.defaultVariationValue {
        evaluation.variationValue = defaultVariation
    }

    if evaluation.type == .variable, evaluation.variableValue == nil,
       let defaultVariable = updated.dependencies.defaultVariableValue {
        evaluation.variableValue = defaultVariable
    }

    return updated.dependencies.hooksManager.runAfter(evaluation, input: input)
}

public func evaluate(_ options: EvaluateOptions) -> Evaluation {
    let type = options.type
    let featureKey = options.featureKey
    let variableKey = options.variableKey
    let context = options.dependencies.context
    let datafileReader = options.dependencies.datafileReader
    let hooksManager = options.dependencies.hooksManager

    if let sticky = options.dependencies.sticky?[featureKey] {
        var stickyEvaluation = Evaluation(type: type, featureKey: featureKey, reason: .sticky)
        stickyEvaluation.sticky = sticky
        stickyEvaluation.enabled = sticky.enabled
        stickyEvaluation.variationValue = sticky.variation
        if type == .variable, let variableKey {
            stickyEvaluation.variableKey = variableKey
            stickyEvaluation.variableValue = sticky.variables?[variableKey]
        }
        return stickyEvaluation
    }

    guard let feature = datafileReader.getFeature(featureKey) else {
        return Evaluation(type: type, featureKey: featureKey, reason: .featureNotFound)
    }

    let matchedForce = datafileReader.getMatchedForce(feature, context: context)
    if let force = matchedForce.force {
        var forced = Evaluation(type: type, featureKey: featureKey, reason: .forced)
        forced.forceIndex = matchedForce.index
        forced.enabled = force.enabled ?? true
        forced.variationValue = force.variation
        if type == .variable, let variableKey {
            forced.variableKey = variableKey
            forced.variableValue = force.variables?[variableKey]
        }
        return forced
    }

    guard let bucketKey = getBucketKey(featureKey: featureKey, bucketBy: feature.bucketBy, context: context) else {
        return Evaluation(type: type, featureKey: featureKey, reason: .noMatch)
    }

    let transformedBucketKey = hooksManager.transformBucketKey(bucketKey)
    let baseBucket = getBucketedNumber(transformedBucketKey)
    let bucketValue = hooksManager.transformBucketValue(baseBucket)

    guard let traffic = datafileReader.getMatchedTraffic(feature.traffic, context: context) else {
        return Evaluation(type: type, featureKey: featureKey, reason: .noMatch)
    }

    var inRange = bucketValue <= traffic.percentage
    if let enabled = traffic.enabled {
        inRange = inRange && enabled
    }

    if type == .flag {
        var out = Evaluation(type: .flag, featureKey: featureKey, reason: inRange ? .allocated : .noMatch)
        out.bucketKey = transformedBucketKey
        out.bucketValue = bucketValue
        out.ruleKey = traffic.key
        out.enabled = inRange
        return out
    }

    guard inRange else {
        var out = Evaluation(type: type, featureKey: featureKey, reason: .disabled)
        out.enabled = false
        return out
    }

    var variation: VariationValue?
    if let direct = traffic.variation {
        variation = direct
    } else if let allocation = datafileReader.getMatchedAllocation(traffic, bucketValue: bucketValue) {
        variation = allocation.variation
    }

    if type == .variation {
        var out = Evaluation(type: .variation, featureKey: featureKey, reason: .allocated)
        out.bucketKey = transformedBucketKey
        out.bucketValue = bucketValue
        out.ruleKey = traffic.key
        out.variationValue = variation
        out.enabled = true
        return out
    }

    guard let variableKey else {
        var out = Evaluation(type: .variable, featureKey: featureKey, reason: .variableNotFound)
        out.enabled = true
        return out
    }

    var out = Evaluation(type: .variable, featureKey: featureKey, reason: .variableDefault)
    out.variableKey = variableKey
    out.bucketKey = transformedBucketKey
    out.bucketValue = bucketValue
    out.ruleKey = traffic.key
    out.enabled = true

    if let schema = feature.variablesSchema?[variableKey] {
        out.variableSchema = schema
        out.variableValue = schema.defaultValue
    }

    if let trafficValue = traffic.variables?[variableKey] {
        out.variableValue = trafficValue
        out.reason = .rule
    }

    if let selected = variation,
       let variationDef = feature.variations?.first(where: { $0.value == selected }),
       let value = variationDef.variables?[variableKey] {
        out.variableValue = value
        out.reason = .variableOverrideVariation
    }

    return out
}
