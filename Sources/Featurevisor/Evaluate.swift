import Foundation

public struct EvaluateDependencies: Sendable {
    public var context: Context
    var reportDiagnostic: @Sendable (FeaturevisorDiagnostic) -> Void
    var modulesManager: ModulesManager
    var evaluationData: InstanceEvaluationDataProvider
    public var stickyFeatures: StickyFeatures?
    public var stickyVariables: StickyVariables?
    public var defaultVariationValue: VariationValue?
    public var defaultVariableValue: VariableValue?

    init(
        context: Context,
        reportDiagnostic: @escaping @Sendable (FeaturevisorDiagnostic) -> Void,
        modulesManager: ModulesManager,
        evaluationData: InstanceEvaluationDataProvider,
        stickyFeatures: StickyFeatures? = nil,
        stickyVariables: StickyVariables? = nil,
        defaultVariationValue: VariationValue? = nil,
        defaultVariableValue: VariableValue? = nil
    ) {
        self.context = context
        self.reportDiagnostic = reportDiagnostic
        self.modulesManager = modulesManager
        self.evaluationData = evaluationData
        self.stickyFeatures = stickyFeatures
        self.stickyVariables = stickyVariables
        self.defaultVariationValue = defaultVariationValue
        self.defaultVariableValue = defaultVariableValue
    }
}

public struct EvaluateOptions: Sendable {
    public var type: EvaluationType
    public var featureKey: FeatureKey
    public var variableKey: VariableKey?
    public var globalVariable: Bool
    public var dependencies: EvaluateDependencies

    init(type: EvaluationType, featureKey: FeatureKey = "", variableKey: VariableKey? = nil, globalVariable: Bool = false, dependencies: EvaluateDependencies) {
        self.type = type
        self.featureKey = featureKey
        self.variableKey = variableKey
        self.globalVariable = globalVariable
        self.dependencies = dependencies
    }
}

func evaluateWithModules(_ options: EvaluateOptions) -> Evaluation {
    var updated = options
    for module in updated.dependencies.modulesManager.getAll() {
        if !updated.globalVariable, let before = module.before { updated = before(updated) }
    }
    for module in updated.dependencies.modulesManager.getAll() {
        if let before = module.beforeEvaluation { updated = before(updated) }
    }

    var evaluation = evaluate(updated)

    if evaluation.type == .variation, evaluation.variationValue == nil, evaluation.variation == nil,
       let defaultVariation = updated.dependencies.defaultVariationValue {
        evaluation.variationValue = defaultVariation
    }

    if evaluation.type == .variable, evaluation.variableValue == nil,
       let defaultVariable = updated.dependencies.defaultVariableValue {
        evaluation.variableValue = defaultVariable
    }

    for module in updated.dependencies.modulesManager.getAll() {
        if let after = module.afterEvaluation {
            evaluation = after(evaluation, updated)
        }
    }
    for module in updated.dependencies.modulesManager.getAll() {
        if !updated.globalVariable, let after = module.after { evaluation = after(evaluation, updated) }
    }

    return evaluation
}

private func reportEvaluationDiagnostic(
    _ reportDiagnostic: FeaturevisorDiagnosticHandler,
    evaluation: Evaluation,
    message: String,
    level: LogLevel = .debug,
    code: String? = nil
) {
    var details: [String: AnyValue] = ["reason": .string(evaluation.reason.rawValue)]
    if let featureKey = evaluation.featureKey { details["featureKey"] = .string(featureKey) }
    if let variableKey = evaluation.variableKey {
        details["variableKey"] = .string(variableKey)
    }
    if let data = try? JSONEncoder().encode(evaluation),
       let encodedEvaluation = try? JSONDecoder().decode(AnyValue.self, from: data) {
        details["evaluation"] = encodedEvaluation
    }

    reportDiagnostic(FeaturevisorDiagnostic(
        level: level,
        code: code ?? evaluation.reason.rawValue,
        message: message,
        originalError: evaluation.error,
        details: details
    ))
}

func evaluate(_ options: EvaluateOptions) -> Evaluation {
    let type = options.type
    let featureKey = options.featureKey
    let variableKey = options.variableKey
    let context = options.dependencies.context
    let evaluationData = options.dependencies.evaluationData
    let modulesManager = options.dependencies.modulesManager
    let reportDiagnostic = options.dependencies.reportDiagnostic

    if options.globalVariable, let variableKey {
        return evaluateGlobalVariable(variableKey, options: options)
    }

    if type != .flag {
            let flagEvaluation = evaluate(EvaluateOptions(type: .flag, featureKey: featureKey, dependencies: options.dependencies))

            if flagEvaluation.enabled == false {
                var disabled = Evaluation(type: type, featureKey: featureKey, reason: .disabled)
                disabled.enabled = false

                if let feature = evaluationData.getFeature(featureKey) {
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

                reportEvaluationDiagnostic(
                    reportDiagnostic,
                    evaluation: disabled,
                    message: "Feature is disabled"
                )
                return disabled
            }
        }

        if let sticky = options.dependencies.stickyFeatures?[featureKey] {
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

        guard let feature = evaluationData.getFeature(featureKey) else {
            let notFound = Evaluation(type: type, featureKey: featureKey, reason: .featureNotFound)
            reportEvaluationDiagnostic(
                reportDiagnostic,
                evaluation: notFound,
                message: "Feature not found",
                level: .warn
            )
            return notFound
        }

        if type == .flag, feature.deprecated == true {
            reportDiagnostic(FeaturevisorDiagnostic(
                level: .warn,
                code: "deprecated_feature",
                message: "Feature is deprecated",
                details: ["featureKey": .string(featureKey)]
            ))
        }

        var variableSchema: ResolvedVariableSchema?
        if let variableKey {
            variableSchema = feature.variablesSchema?[variableKey]
            if variableSchema == nil {
                var out = Evaluation(type: type, featureKey: featureKey, reason: .variableNotFound)
                out.variableKey = variableKey
                reportEvaluationDiagnostic(
                    reportDiagnostic,
                    evaluation: out,
                    message: "Variable schema not found",
                    level: .warn
                )
                return out
            }
            if variableSchema?.deprecated == true {
                reportDiagnostic(FeaturevisorDiagnostic(
                    level: .warn,
                    code: "deprecated_variable",
                    message: "Variable is deprecated",
                    details: [
                        "featureKey": .string(featureKey),
                        "variableKey": .string(variableKey),
                    ]
                ))
            }
        }

        if type == .variation, (feature.variations ?? []).isEmpty {
            let noVariations = Evaluation(type: type, featureKey: featureKey, reason: .noVariations)
            reportEvaluationDiagnostic(
                reportDiagnostic,
                evaluation: noVariations,
                message: "No variations",
                level: .warn
            )
            return noVariations
        }

        let matchedForce = evaluationData.getMatchedForce(feature, context: context)
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

        if type == .flag, let requiredFeatures = feature.requiredFeatures, !requiredFeatures.isEmpty {
            if !requiredFeaturesAreMatched(requiredFeatures, options: options) {
                var out = Evaluation(type: type, featureKey: featureKey, reason: .required)
                out.requiredFeatures = requiredFeatures
                out.enabled = false
                return out
            }
        } else if type == .flag, let required = feature.required, !required.isEmpty {
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
        var bucketKey = rawBucketKey
        for module in modulesManager.getAll() {
            if let transform = module.bucketKey {
                bucketKey = transform(ConfigureBucketKeyOptions(
                    featureKey: featureKey,
                    context: context,
                    bucketBy: feature.bucketBy,
                    bucketKey: bucketKey
                ))
            }
        }

        var bucketValue = getBucketedNumber(bucketKey)
        for module in modulesManager.getAll() {
            if let transform = module.bucketValue {
                bucketValue = transform(ConfigureBucketValueOptions(
                    featureKey: featureKey,
                    bucketKey: bucketKey,
                    context: context,
                    bucketValue: bucketValue
                ))
            }
        }
        let matchedTraffic = evaluationData.getMatchedTraffic(feature.traffic, context: context)
        let matchedAllocation = matchedTraffic.flatMap { evaluationData.getMatchedAllocation($0, bucketValue: bucketValue) }

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
                   let overrideIndex = firstMatchedOverrideIndex(overrides: overrides, options: options) {
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
                    out.variableOverrideKey = override.key
                    out.variableOverridePath = override.keyPath
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
                   let overrideIndex = firstMatchedOverrideIndex(overrides: overrides, options: options) {
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
                    out.variableOverrideKey = override.key
                    out.variableOverridePath = override.keyPath
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
}

private func firstMatchedOverrideIndex(overrides: [VariableOverride], options: EvaluateOptions) -> Int? {
    let context = options.dependencies.context
    let evaluationData = options.dependencies.evaluationData
    for (index, override) in overrides.enumerated() {
        if let conditions = override.conditions,
           !evaluationData.allConditionsAreMatched(parseConditionIfStringified(conditions), context: context) { continue }
        if let segments = override.segments,
           !evaluationData.allSegmentsAreMatched(parseSegmentsIfStringified(segments), context: context) { continue }
        if let required = override.requiredFeatures,
           !requiredFeaturesAreMatched(required, options: options) { continue }
        if override.conditions != nil || override.segments != nil || override.requiredFeatures != nil { return index }
    }

    return nil
}

private func cleanDependencies(_ dependencies: EvaluateDependencies) -> EvaluateDependencies {
    EvaluateDependencies(
        context: dependencies.context,
        reportDiagnostic: dependencies.reportDiagnostic,
        modulesManager: dependencies.modulesManager,
        evaluationData: dependencies.evaluationData,
        stickyFeatures: dependencies.stickyFeatures
    )
}

private func requiredFeaturesAreMatched(_ requirements: [RequiredFeature], options: EvaluateOptions) -> Bool {
    let dependencies = cleanDependencies(options.dependencies)
    return requirements.allSatisfy { requirement in
        let key: FeatureKey
        let enabled: Bool
        let variation: VariationValue?
        switch requirement {
        case .feature(let value):
            key = value
            enabled = true
            variation = nil
        case .options(let value):
            key = value.feature
            enabled = value.enabled ?? true
            variation = value.variation
        }
        let flag = evaluateWithModules(EvaluateOptions(type: .flag, featureKey: key, dependencies: dependencies))
        guard (flag.enabled == true) == enabled else { return false }
        guard let variation else { return true }
        return evaluateWithModules(EvaluateOptions(type: .variation, featureKey: key, dependencies: dependencies)).variationValue == variation
    }
}

private func evaluateGlobalVariable(_ variableKey: VariableKey, options: EvaluateOptions) -> Evaluation {
    let dependencies = options.dependencies
    if let sticky = dependencies.stickyVariables?[variableKey] {
        var out = Evaluation(type: .variable, reason: .sticky)
        out.variableKey = variableKey
        out.variableValue = sticky
        return out
    }

    guard let variable = dependencies.evaluationData.getGlobalVariable(variableKey) else {
        var out = Evaluation(type: .variable, reason: .variableNotFound)
        out.variableKey = variableKey
        return out
    }

    if let required = variable.requiredFeatures,
       !requiredFeaturesAreMatched(required, options: options) {
        var out = Evaluation(type: .variable, reason: .requiredFeaturesUnmet)
        out.variableKey = variableKey
        out.globalVariable = variable
        out.requiredFeatures = required
        if variable.useDefaultWhenDisabled == true { out.variableValue = variable.defaultValue }
        else { out.variableValue = variable.disabledValue }
        return out
    }

    if let overrides = variable.overrides,
       let index = firstMatchedOverrideIndex(overrides: overrides, options: options) {
        let matched = overrides[index]
        var out = Evaluation(type: .variable, reason: .variableOverrideRule)
        out.variableKey = variableKey
        out.variableValue = matched.value
        out.globalVariable = variable
        out.variableOverrideIndex = index
        out.variableOverrideKey = matched.key
        out.variableOverridePath = matched.keyPath
        return out
    }

    var out = Evaluation(type: .variable, reason: .variableDefault)
    out.variableKey = variableKey
    out.variableValue = variable.defaultValue
    out.globalVariable = variable
    return out
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
