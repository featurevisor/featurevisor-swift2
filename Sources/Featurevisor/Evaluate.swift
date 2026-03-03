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
    let logger = options.dependencies.logger

    do {
        if type != .flag {
            let flagEvaluation = evaluate(EvaluateOptions(type: .flag, featureKey: featureKey, dependencies: options.dependencies))

            if flagEvaluation.enabled == false {
                var disabled = Evaluation(type: type, featureKey: featureKey, reason: .disabled)
                disabled.enabled = false

                if let feature = datafileReader.getFeature(featureKey) {
                    if type == .variation, let disabledVariationValue = feature.disabledVariationValue {
                        disabled.reason = .variationDisabled
                        disabled.variationValue = disabledVariationValue
                    }

                    if type == .variable,
                       let variableKey,
                       let variableSchema = feature.variablesSchema?[variableKey] {
                        if let disabledValue = variableSchema.disabledValue {
                            disabled.reason = .variableDisabled
                            disabled.variableKey = variableKey
                            disabled.variableSchema = variableSchema
                            disabled.variableValue = disabledValue
                        } else if variableSchema.useDefaultWhenDisabled == true {
                            disabled.reason = .variableDefault
                            disabled.variableKey = variableKey
                            disabled.variableSchema = variableSchema
                            disabled.variableValue = variableSchema.defaultValue
                        }
                    }
                }

                logger.debug("feature is disabled", details: ["featureKey": featureKey])
                return disabled
            }
        }

        if let sticky = options.dependencies.sticky?[featureKey] {
            if type == .flag {
                var stickyEvaluation = Evaluation(type: type, featureKey: featureKey, reason: .sticky)
                stickyEvaluation.sticky = sticky
                stickyEvaluation.enabled = sticky.enabled
                return stickyEvaluation
            }

            if type == .variation, let stickyVariation = sticky.variation {
                var stickyEvaluation = Evaluation(type: type, featureKey: featureKey, reason: .sticky)
                stickyEvaluation.sticky = sticky
                stickyEvaluation.variationValue = stickyVariation
                return stickyEvaluation
            }

            if type == .variable, let variableKey, let stickyValue = sticky.variables?[variableKey] {
                var stickyEvaluation = Evaluation(type: type, featureKey: featureKey, reason: .sticky)
                stickyEvaluation.sticky = sticky
                stickyEvaluation.variableKey = variableKey
                stickyEvaluation.variableValue = stickyValue
                return stickyEvaluation
            }
        }

        guard let feature = datafileReader.getFeature(featureKey) else {
            return Evaluation(type: type, featureKey: featureKey, reason: .featureNotFound)
        }

        var variableSchema: ResolvedVariableSchema?
        if let variableKey {
            variableSchema = feature.variablesSchema?[variableKey]
            if variableSchema == nil {
                var out = Evaluation(type: type, featureKey: featureKey, reason: .variableNotFound)
                out.variableKey = variableKey
                return out
            }
        }

        if type == .variation, (feature.variations ?? []).isEmpty {
            return Evaluation(type: type, featureKey: featureKey, reason: .noVariations)
        }

        let matchedForce = datafileReader.getMatchedForce(feature, context: context)
        if let force = matchedForce.force {
            if type == .flag, let enabled = force.enabled {
                var forced = Evaluation(type: type, featureKey: featureKey, reason: .forced)
                forced.enabled = enabled
                forced.force = force
                forced.forceIndex = matchedForce.index
                return forced
            }

            if type == .variation, let forcedVariationValue = force.variation,
               let variation = feature.variations?.first(where: { $0.value == forcedVariationValue }) {
                var forced = Evaluation(type: type, featureKey: featureKey, reason: .forced)
                forced.force = force
                forced.forceIndex = matchedForce.index
                forced.variation = variation
                forced.variationValue = variation.value
                return forced
            }

            if type == .variable, let variableKey, let forcedValue = force.variables?[variableKey] {
                var forced = Evaluation(type: type, featureKey: featureKey, reason: .forced)
                forced.force = force
                forced.forceIndex = matchedForce.index
                forced.variableKey = variableKey
                forced.variableSchema = variableSchema
                forced.variableValue = forcedValue
                return forced
            }
        }

        if type == .flag, let required = feature.required, !required.isEmpty {
            let requiredEnabled = required.allSatisfy { requiredValue in
                let requiredKey: String
                let requiredVariation: String?

                switch requiredValue {
                case .key(let key):
                    requiredKey = key
                    requiredVariation = nil
                case .withVariation(let value):
                    requiredKey = value.key
                    requiredVariation = value.variation
                }

                let requiredFlag = evaluate(EvaluateOptions(type: .flag, featureKey: requiredKey, dependencies: options.dependencies))
                guard requiredFlag.enabled == true else { return false }

                if let requiredVariation {
                    let requiredVariationEval = evaluate(EvaluateOptions(type: .variation, featureKey: requiredKey, dependencies: options.dependencies))
                    return requiredVariationEval.variationValue == requiredVariation
                }

                return true
            }

            if !requiredEnabled {
                var out = Evaluation(type: type, featureKey: featureKey, reason: .required)
                out.required = required
                out.enabled = false
                return out
            }
        }

        let rawBucketKey = getBucketKey(featureKey: featureKey, bucketBy: feature.bucketBy, context: context) ?? featureKey
        let bucketKey = hooksManager.transformBucketKey(rawBucketKey)
        let bucketValue = hooksManager.transformBucketValue(getBucketedNumber(bucketKey))
        let matchedTraffic = datafileReader.getMatchedTraffic(feature.traffic, context: context)
        let matchedAllocation = matchedTraffic.flatMap { datafileReader.getMatchedAllocation($0, bucketValue: bucketValue) }

        if let matchedTraffic {
            if matchedTraffic.percentage == 0 {
                var out = Evaluation(type: type, featureKey: featureKey, reason: .rule)
                out.bucketKey = bucketKey
                out.bucketValue = bucketValue
                out.ruleKey = matchedTraffic.key
                out.traffic = matchedTraffic
                out.enabled = false
                return out
            }

            if type == .flag {
                if let ranges = feature.ranges, !ranges.isEmpty {
                    let matchedRange = ranges.first { range in
                        guard range.count == 2 else { return false }
                        return bucketValue >= range[0] && bucketValue < range[1]
                    }

                    if matchedRange != nil {
                        var out = Evaluation(type: type, featureKey: featureKey, reason: .allocated)
                        out.bucketKey = bucketKey
                        out.bucketValue = bucketValue
                        out.ruleKey = matchedTraffic.key
                        out.traffic = matchedTraffic
                        out.enabled = matchedTraffic.enabled ?? true
                        return out
                    }

                    var out = Evaluation(type: type, featureKey: featureKey, reason: .outOfRange)
                    out.bucketKey = bucketKey
                    out.bucketValue = bucketValue
                    out.enabled = false
                    return out
                }

                if let enabled = matchedTraffic.enabled {
                    var out = Evaluation(type: type, featureKey: featureKey, reason: .rule)
                    out.bucketKey = bucketKey
                    out.bucketValue = bucketValue
                    out.ruleKey = matchedTraffic.key
                    out.traffic = matchedTraffic
                    out.enabled = enabled
                    return out
                }

                if bucketValue <= matchedTraffic.percentage {
                    var out = Evaluation(type: type, featureKey: featureKey, reason: .rule)
                    out.bucketKey = bucketKey
                    out.bucketValue = bucketValue
                    out.ruleKey = matchedTraffic.key
                    out.traffic = matchedTraffic
                    out.enabled = true
                    return out
                }
            }

            if type == .variation, let variations = feature.variations {
                if let matchedVariation = matchedTraffic.variation,
                   let variation = variations.first(where: { $0.value == matchedVariation }) {
                    var out = Evaluation(type: type, featureKey: featureKey, reason: .rule)
                    out.bucketKey = bucketKey
                    out.bucketValue = bucketValue
                    out.ruleKey = matchedTraffic.key
                    out.traffic = matchedTraffic
                    out.variation = variation
                    out.variationValue = variation.value
                    return out
                }

                if let allocated = matchedAllocation,
                   let variation = variations.first(where: { $0.value == allocated.variation }) {
                    var out = Evaluation(type: type, featureKey: featureKey, reason: .allocated)
                    out.bucketKey = bucketKey
                    out.bucketValue = bucketValue
                    out.ruleKey = matchedTraffic.key
                    out.traffic = matchedTraffic
                    out.variation = variation
                    out.variationValue = variation.value
                    return out
                }
            }
        }

        if type == .variable, let variableKey {
            if let matchedTraffic {
                if let overrides = matchedTraffic.variableOverrides?[variableKey],
                   let overrideIndex = firstMatchedOverrideIndex(overrides: overrides, context: context, datafileReader: datafileReader) {
                    let override = overrides[overrideIndex]
                    var out = Evaluation(type: type, featureKey: featureKey, reason: .variableOverrideRule)
                    out.bucketKey = bucketKey
                    out.bucketValue = bucketValue
                    out.ruleKey = matchedTraffic.key
                    out.traffic = matchedTraffic
                    out.variableKey = variableKey
                    out.variableSchema = variableSchema
                    out.variableValue = override.value
                    out.variableOverrideIndex = overrideIndex
                    return out
                }

                if let variableValue = matchedTraffic.variables?[variableKey] {
                    var out = Evaluation(type: type, featureKey: featureKey, reason: .rule)
                    out.bucketKey = bucketKey
                    out.bucketValue = bucketValue
                    out.ruleKey = matchedTraffic.key
                    out.traffic = matchedTraffic
                    out.variableKey = variableKey
                    out.variableSchema = variableSchema
                    out.variableValue = variableValue
                    return out
                }
            }

            var variationValue: String?
            if let forceVariation = matchedForce.force?.variation {
                variationValue = forceVariation
            } else if let matchedRuleVariation = matchedTraffic?.variation {
                variationValue = matchedRuleVariation
            } else if let allocatedVariation = matchedAllocation?.variation {
                variationValue = allocatedVariation
            }

            if let variationValue,
               let variation = feature.variations?.first(where: { $0.value == variationValue }) {
                if let overrides = variation.variableOverrides?[variableKey],
                   let overrideIndex = firstMatchedOverrideIndex(overrides: overrides, context: context, datafileReader: datafileReader) {
                    let override = overrides[overrideIndex]
                    var out = Evaluation(type: type, featureKey: featureKey, reason: .variableOverrideVariation)
                    out.bucketKey = bucketKey
                    out.bucketValue = bucketValue
                    out.ruleKey = matchedTraffic?.key
                    out.traffic = matchedTraffic
                    out.variableKey = variableKey
                    out.variableSchema = variableSchema
                    out.variableValue = override.value
                    out.variableOverrideIndex = overrideIndex
                    return out
                }

                if let variableValue = variation.variables?[variableKey] {
                    var out = Evaluation(type: type, featureKey: featureKey, reason: .allocated)
                    out.bucketKey = bucketKey
                    out.bucketValue = bucketValue
                    out.ruleKey = matchedTraffic?.key
                    out.traffic = matchedTraffic
                    out.variableKey = variableKey
                    out.variableSchema = variableSchema
                    out.variableValue = variableValue
                    return out
                }
            }
        }

        if type == .variation {
            var out = Evaluation(type: type, featureKey: featureKey, reason: .noMatch)
            out.bucketKey = bucketKey
            out.bucketValue = bucketValue
            return out
        }

        if type == .variable, let variableKey {
            if let variableSchema {
                var out = Evaluation(type: type, featureKey: featureKey, reason: .variableDefault)
                out.bucketKey = bucketKey
                out.bucketValue = bucketValue
                out.variableKey = variableKey
                out.variableSchema = variableSchema
                out.variableValue = variableSchema.defaultValue
                return out
            }

            var out = Evaluation(type: type, featureKey: featureKey, reason: .variableNotFound)
            out.bucketKey = bucketKey
            out.bucketValue = bucketValue
            out.variableKey = variableKey
            return out
        }

        var out = Evaluation(type: type, featureKey: featureKey, reason: .noMatch)
        out.bucketKey = bucketKey
        out.bucketValue = bucketValue
        out.enabled = false
        return out
    } catch {
        var out = Evaluation(type: type, featureKey: featureKey, reason: .error)
        out.variableKey = variableKey
        out.error = error.localizedDescription
        return out
    }
}

private func firstMatchedOverrideIndex(overrides: [VariableOverride], context: Context, datafileReader: DatafileReader) -> Int? {
    for (index, override) in overrides.enumerated() {
        if let conditions = override.conditions {
            if datafileReader.allConditionsAreMatched(parseConditionIfStringified(conditions), context: context) {
                return index
            }
        }

        if let segments = override.segments {
            if datafileReader.allSegmentsAreMatched(parseSegmentsIfStringified(segments), context: context) {
                return index
            }
        }
    }

    return nil
}

private func parseConditionIfStringified(_ condition: Condition) -> Condition {
    if case .invalidToken(let raw) = condition,
       raw != "*",
       let data = raw.data(using: .utf8),
       let parsed = try? JSONDecoder().decode(Condition.self, from: data) {
        return parsed
    }
    return condition
}

private func parseSegmentsIfStringified(_ segments: GroupSegment) -> GroupSegment {
    if case .key(let key) = segments,
       (key.hasPrefix("{") || key.hasPrefix("[")),
       let data = key.data(using: .utf8),
       let parsed = try? JSONDecoder().decode(GroupSegment.self, from: data) {
        return parsed
    }
    return segments
}
