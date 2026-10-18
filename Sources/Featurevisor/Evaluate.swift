import Foundation

struct StickyStateSnapshot: Sendable {
    let features: StickyFeatures?
    let variables: StickyVariables?
    let generation: String
    var evaluationData: InstanceEvaluationDataProvider? = nil
}

final class StickySourceHandle: @unchecked Sendable {
    private let lock = FeaturevisorLock()
    private var read: (@Sendable () -> StickyStateSnapshot)?

    init(_ read: @escaping @Sendable () -> StickyStateSnapshot) { self.read = read }
    func current() -> StickyStateSnapshot? { lock.withLock { read?() } }
    func clear() { lock.withLock { read = nil } }
}

public struct EvaluateDependencies: Sendable {
    public var context: Context
    var reportDiagnostic: @Sendable (FeaturevisorDiagnostic) -> Void
    var diagnosticAudience: EvaluationDiagnosticAudience
    var modulesManager: ModulesManager
    var evaluationData: InstanceEvaluationDataProvider
    var inheritedEvaluationData = true
    public var stickyFeatures: StickyFeatures? { didSet { if !refreshingSticky { stickyFeaturesToken = UUID() } } }
    public var stickyVariables: StickyVariables? { didSet { if !refreshingSticky { stickyVariablesToken = UUID() } } }
    var stickyFeaturesToken: UUID
    var stickyVariablesToken: UUID
    private var refreshingSticky = false
    var stickySource: StickySourceHandle?
    var inheritedStickyFeatures = false
    var inheritedStickyVariables = false
    public var defaultVariationValue: VariationValue?
    public var defaultVariableValue: VariableValue?
    var session: EvaluationSession

    init(
        context: Context,
        reportDiagnostic: @escaping @Sendable (FeaturevisorDiagnostic) -> Void,
        diagnosticAudience: EvaluationDiagnosticAudience,
        modulesManager: ModulesManager,
        evaluationData: InstanceEvaluationDataProvider,
        stickyFeatures: StickyFeatures? = nil,
        stickyVariables: StickyVariables? = nil,
        defaultVariationValue: VariationValue? = nil,
        defaultVariableValue: VariableValue? = nil,
        session: EvaluationSession = EvaluationSession(),
        stickySource: StickySourceHandle? = nil,
        inheritedStickyFeatures: Bool = false,
        inheritedStickyVariables: Bool = false,
        stickyFeaturesToken: UUID = UUID(),
        stickyVariablesToken: UUID? = nil
    ) {
        self.context = context
        self.reportDiagnostic = reportDiagnostic
        self.diagnosticAudience = diagnosticAudience
        self.modulesManager = modulesManager
        self.evaluationData = evaluationData
        self.stickyFeatures = stickyFeatures
        self.stickyVariables = stickyVariables
        self.stickyFeaturesToken = stickyFeaturesToken
        // Tokens are compared only within their own sticky domain. One fresh
        // identity can seed both domains until either property is replaced.
        self.stickyVariablesToken = stickyVariablesToken ?? stickyFeaturesToken
        self.stickySource = stickySource
        self.inheritedStickyFeatures = inheritedStickyFeatures
        self.inheritedStickyVariables = inheritedStickyVariables
        self.defaultVariationValue = defaultVariationValue
        self.defaultVariableValue = defaultVariableValue
        self.session = session
    }

    mutating func refreshSticky() {
        guard let state = stickySource?.current() else { return }
        if inheritedEvaluationData, let currentData = state.evaluationData { evaluationData = currentData }
        // Refresh owner values without treating the refresh as a module replacement.
        refreshingSticky = true
        defer { refreshingSticky = false }
        if inheritedStickyFeatures { stickyFeatures = state.features }
        if inheritedStickyVariables { stickyVariables = state.variables }
    }
}

public struct EvaluateOptions: Sendable {
    public var type: EvaluationType
    public var featureKey: FeatureKey
    public var variableKey: VariableKey?
    public var globalVariable: Bool
    public var dependencies: EvaluateDependencies
    public var dependencyOf: DependencyOf?
    public var dependencyPurpose: String?

    init(type: EvaluationType, featureKey: FeatureKey = "", variableKey: VariableKey? = nil, globalVariable: Bool = false, dependencies: EvaluateDependencies, dependencyOf: DependencyOf? = nil) {
        self.type = type
        self.featureKey = featureKey
        self.variableKey = variableKey
        self.globalVariable = globalVariable
        self.dependencies = dependencies
        self.dependencyOf = dependencyOf
    }
}

func evaluateWithModules(_ options: EvaluateOptions) -> Evaluation {
    let session = options.dependencies.session
    let ownsRoot = session.beginRoot(DependencyOf(options))
    defer {
        if ownsRoot {
            session.endRoot()
            options.dependencies.stickySource?.clear()
        }
    }
    do {
        var updated = options
        for module in updated.dependencies.modulesManager.getAll() {
            if let before = module.beforeEvaluation {
                let previousData = updated.dependencies.evaluationData
                let previousFeaturesToken = updated.dependencies.stickyFeaturesToken
                let previousVariablesToken = updated.dependencies.stickyVariablesToken
                updated = before(updated)
                updated.dependencies.session = session
                updated.dependencyOf = options.dependencyOf
                updated.dependencyPurpose = options.dependencyPurpose
                if previousData !== updated.dependencies.evaluationData { updated.dependencies.inheritedEvaluationData = false }
                if updated.dependencies.stickyFeaturesToken != previousFeaturesToken { updated.dependencies.inheritedStickyFeatures = false }
                if updated.dependencies.stickyVariablesToken != previousVariablesToken { updated.dependencies.inheritedStickyVariables = false }
            }
        }
        if updated.globalVariable || updated.dependencyOf != nil { updated.dependencies.refreshSticky() }
        session.updateCurrent(DependencyOf(updated))

        var evaluation = try evaluate(updated)
        try session.throwIfFatal()
        if evaluation.type == .variation, evaluation.variationValue == nil, evaluation.variation == nil,
           let defaultVariation = updated.dependencies.defaultVariationValue {
            evaluation.variationValue = defaultVariation
        }
        if evaluation.type == .variable, evaluation.variableValue == nil,
           !(evaluation.reason == .conditionsUnmet && evaluation.globalVariable?.compose != nil),
           let defaultVariable = updated.dependencies.defaultVariableValue {
            evaluation.variableValue = defaultVariable
        }
        for module in updated.dependencies.modulesManager.getAll() {
            if let after = module.afterEvaluation { evaluation = after(evaluation, updated) }
        }
        return evaluation
    } catch {
        return evaluationFailure(error, options: options, report: ownsRoot)
    }
}

/// A dependency failure fails the complete public call, so only the call that owns
/// the session reports it. Nested getters pass the recorded failure upwards.
@inline(never)
private func evaluationFailure(_ error: Error, options: EvaluateOptions, report: Bool) -> Evaluation {
    let session = options.dependencies.session
    if let requirementError = error as? RequirementEvaluationError {
        session.recordRequirementFailure(requirementError)
    }
    var evaluation = Evaluation(
        type: options.type,
        featureKey: options.globalVariable ? nil : options.featureKey,
        reason: .error
    )
    evaluation.variableKey = options.variableKey
    evaluation.error = error.localizedDescription
    let dependencyFailure = error is RequirementEvaluationError || error is RequirementCycleError
    if report || !dependencyFailure {
        reportEvaluationDiagnostic(
            options.dependencies,
            evaluation: evaluation,
            message: options.globalVariable ? "Global variable evaluation failed" : "Error during evaluation",
            level: .error,
            code: "evaluation_error"
        )
    }
    return evaluation
}

// Diagnostics are rare and build large temporaries. Keeping them out of line keeps
// the recursive evaluation frames small enough for 512 KB secondary threads.
@inline(never)
private func reportEvaluationDiagnostic(
    _ dependencies: EvaluateDependencies,
    evaluation: Evaluation,
    message: String,
    level: LogLevel = .debug,
    code: String? = nil
) {
    guard dependencies.diagnosticAudience.shouldReport(level) else { return }
    var details: [String: AnyValue] = ["reason": .string(evaluation.reason.rawValue)]
    if let featureKey = evaluation.featureKey { details["featureKey"] = .string(featureKey) }
    if let variableKey = evaluation.variableKey {
        details["variableKey"] = .string(variableKey)
    }
    if let data = try? JSONEncoder().encode(evaluation),
       let encodedEvaluation = try? JSONDecoder().decode(AnyValue.self, from: data) {
        details["evaluation"] = encodedEvaluation
    }

    dependencies.reportDiagnostic(FeaturevisorDiagnostic(
        level: level,
        code: code ?? evaluation.reason.rawValue,
        message: message,
        originalError: evaluation.error,
        details: details
    ))
}

func evaluate(_ options: EvaluateOptions) throws -> Evaluation {
    if options.globalVariable, let variableKey = options.variableKey {
        return try evaluateGlobalVariable(variableKey, options: options)
    }
    if options.type == .flag { return try evaluateFeatureFlag(options) }
    return try evaluateFeature(options)
}

@inline(never)
private func bucketFeature(_ feature: Feature, options: EvaluateOptions) -> (String, Int) {
    let featureKey = options.featureKey
    let context = options.dependencies.context
    let modulesManager = options.dependencies.modulesManager
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

    return (bucketKey, bucketValue)
}

@inline(never)
private func reportDeprecatedFeature(_ key: FeatureKey, _ dependencies: EvaluateDependencies) {
    dependencies.reportDiagnostic(FeaturevisorDiagnostic(level: .warn, code: "deprecated_feature", message: "Feature is deprecated", details: ["featureKey": .string(key)]))
}

private func evaluateFeatureFlag(_ options: EvaluateOptions) throws -> Evaluation {
    let key = options.featureKey
    let data = options.dependencies.evaluationData
    var out = Evaluation(type: .flag, featureKey: key, reason: .noMatch)
    if let sticky = options.dependencies.stickyFeatures?[key] {
        out.reason = .sticky
        out.stickyFeature = sticky
        out.enabled = sticky.enabled
        return out
    }
    guard let feature = data.getFeature(key) else {
        out.reason = .featureNotFound
        reportEvaluationDiagnostic(options.dependencies, evaluation: out, message: "Feature not found", level: .warn)
        return out
    }
    if feature.deprecated == true { reportDeprecatedFeature(key, options.dependencies) }
    for (index, force) in (feature.force ?? []).enumerated() {
        if let conditions = force.conditions, try conditionsAreMatched(conditions, options: options) {
            if let enabled = force.enabled {
                out.reason = .forced
                out.enabled = enabled
                out.force = force
                out.forceIndex = index
                return out
            }
            break
        }
    }
    if let conditions = feature.conditions, try !conditionsAreMatched(conditions, options: options) {
        out.reason = .conditionsUnmet
        out.conditions = conditions
        out.enabled = false
        return out
    }
    let (bucketKey, bucketValue) = bucketFeature(feature, options: options)
    out.bucketKey = bucketKey
    out.bucketValue = bucketValue
    for traffic in feature.traffic {
        guard let conditions = traffic.conditions, try conditionsAreMatched(conditions, options: options) else { continue }
        if traffic.percentage == 0 || traffic.enabled != nil || bucketValue <= traffic.percentage {
            out.reason = .rule
            out.ruleKey = traffic.key
            out.traffic = traffic
            out.enabled = traffic.percentage == 0 ? false : traffic.enabled ?? true
            return out
        }
        break
    }
    out.enabled = false
    return out
}

private func evaluateFeature(_ options: EvaluateOptions) throws -> Evaluation {
    let type = options.type
    let featureKey = options.featureKey
    let variableKey = options.variableKey
    let evaluationData = options.dependencies.evaluationData
    let reportDiagnostic = options.dependencies.reportDiagnostic

    var out = Evaluation(type: type, featureKey: featureKey, reason: .noMatch)
    if type != .flag {
            let flagEvaluation = try evaluate(EvaluateOptions(type: .flag, featureKey: featureKey, dependencies: options.dependencies))

            if flagEvaluation.enabled == false {
                out = Evaluation(type: type, featureKey: featureKey, reason: .disabled)
                out.enabled = false

                if let feature = evaluationData.getFeature(featureKey) {
                    if type == .variation, let disabledVariationValue = feature.disabledVariationValue {
                        out.reason = .variationDisabled
                        out.variationValue = disabledVariationValue
                    }

                    if type == .variable,
                       let variableKey,
                       let variableSchema = feature.variablesSchema?[variableKey] {
                        if let disabledValue = variableSchema.disabledValue {
                            out.reason = .variableDisabled
                            out.variableKey = variableKey
                            out.variableSchema = variableSchema
                            out.variableValue = disabledValue
                        } else if variableSchema.useDefaultWhenDisabled == true {
                            out.reason = .variableDefault
                            out.variableKey = variableKey
                            out.variableSchema = variableSchema
                            out.variableValue = variableSchema.defaultValue
                        }
                    }
                }

                reportEvaluationDiagnostic(
                    options.dependencies,
                    evaluation: out,
                    message: "Feature is disabled"
                )
                return out
            }
        }

        if let sticky = options.dependencies.stickyFeatures?[featureKey] {


            if type == .variation, let stickyVariation = sticky.variation {
                out = Evaluation(type: type, featureKey: featureKey, reason: .sticky)
                out.stickyFeature = sticky
                out.variationValue = stickyVariation
                return out
            }

            if type == .variable, let variableKey, let stickyValue = sticky.variables?[variableKey] {
                out = Evaluation(type: type, featureKey: featureKey, reason: .sticky)
                out.stickyFeature = sticky
                out.variableKey = variableKey
                out.variableValue = stickyValue
                out.variableSchema = evaluationData.getFeature(featureKey)?.variablesSchema?[variableKey]
                return out
            }
        }

        guard let feature = evaluationData.getFeature(featureKey) else {
            out = Evaluation(type: type, featureKey: featureKey, reason: .featureNotFound)
            reportEvaluationDiagnostic(
                options.dependencies,
                evaluation: out,
                message: "Feature not found",
                level: .warn
            )
            return out
        }



        var variableSchema: ResolvedVariableSchema?
        if let variableKey {
            variableSchema = feature.variablesSchema?[variableKey]
            if variableSchema == nil {
                out = Evaluation(type: type, featureKey: featureKey, reason: .variableNotFound)
                out.variableKey = variableKey
                reportEvaluationDiagnostic(
                    options.dependencies,
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
            out = Evaluation(type: type, featureKey: featureKey, reason: .noVariations)
            reportEvaluationDiagnostic(
                options.dependencies,
                evaluation: out,
                message: "No variations",
                level: .warn
            )
            return out
        }

        let matchedForce: (force: Force?, index: Int?) = try {
            for (index, force) in (feature.force ?? []).enumerated() {
                if let conditions = force.conditions, try conditionsAreMatched(conditions, options: options) { return (force, index) }
            }
            return (nil, nil)
        }()
        if let force = matchedForce.force {


            if type == .variation, let forcedVariationValue = force.variation,
               let variation = feature.variations?.first(where: { $0.value == forcedVariationValue }) {
                out = Evaluation(type: type, featureKey: featureKey, reason: .forced)
                out.force = force
                out.forceIndex = matchedForce.index
                out.variation = variation
                out.variationValue = variation.value
                return out
            }

            if type == .variable, let variableKey, let forcedValue = force.variables?[variableKey] {
                out = Evaluation(type: type, featureKey: featureKey, reason: .forced)
                out.force = force
                out.forceIndex = matchedForce.index
                out.variableKey = variableKey
                out.variableSchema = variableSchema
                out.variableValue = forcedValue
                return out
            }
        }



        let (bucketKey, bucketValue) = bucketFeature(feature, options: options)
        let matchedTraffic = try feature.traffic.first { traffic in
            guard let conditions = traffic.conditions else { return false }
            return try conditionsAreMatched(conditions, options: options)
        }
        let matchedAllocation = matchedTraffic.flatMap { evaluationData.getMatchedAllocation($0, bucketValue: bucketValue) }

        if let matchedTraffic {
            if matchedTraffic.percentage == 0 {
                out = Evaluation(type: type, featureKey: featureKey, reason: .rule)
                out.bucketKey = bucketKey
                out.bucketValue = bucketValue
                out.ruleKey = matchedTraffic.key
                out.traffic = matchedTraffic
                out.enabled = false
                return out
            }



            if type == .variation, let variations = feature.variations {
                if let matchedVariation = matchedTraffic.variation,
                   let variation = variations.first(where: { $0.value == matchedVariation }) {
                    out = Evaluation(type: type, featureKey: featureKey, reason: .rule)
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
                    out = Evaluation(type: type, featureKey: featureKey, reason: .allocated)
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
                   let overrideIndex = try firstMatchedOverrideIndex(overrides: overrides, options: options) {
                    let override = overrides[overrideIndex]
                    out = Evaluation(type: type, featureKey: featureKey, reason: .variableOverrideRule)
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
                    out = Evaluation(type: type, featureKey: featureKey, reason: .rule)
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
                   let overrideIndex = try firstMatchedOverrideIndex(overrides: overrides, options: options) {
                    let override = overrides[overrideIndex]
                    out = Evaluation(type: type, featureKey: featureKey, reason: .variableOverrideVariation)
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
                    out = Evaluation(type: type, featureKey: featureKey, reason: .allocated)
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
            out = Evaluation(type: type, featureKey: featureKey, reason: .noMatch)
            out.bucketKey = bucketKey
            out.bucketValue = bucketValue
            return out
        }

        if type == .variable, let variableKey {
            if let variableSchema {
                out = Evaluation(type: type, featureKey: featureKey, reason: .variableDefault)
                out.bucketKey = bucketKey
                out.bucketValue = bucketValue
                out.variableKey = variableKey
                out.variableSchema = variableSchema
                out.variableValue = variableSchema.defaultValue
                return out
            }

            out = Evaluation(type: type, featureKey: featureKey, reason: .variableNotFound)
            out.bucketKey = bucketKey
            out.bucketValue = bucketValue
            out.variableKey = variableKey
            return out
        }

        out = Evaluation(type: type, featureKey: featureKey, reason: .noMatch)
        out.bucketKey = bucketKey
        out.bucketValue = bucketValue
        out.enabled = false
        return out
}

private func firstMatchedOverrideIndex(overrides: [VariableOverride], options: EvaluateOptions) throws -> Int? {
    let context = options.dependencies.context
    let evaluationData = options.dependencies.evaluationData
    for index in overrides.indices {
        if try ordinaryOverrideIsMatched(overrides[index], context: context, evaluationData: evaluationData, options: options) {
            return index
        }
    }

    return nil
}

private func ordinaryOverrideIsMatched(
    _ override: borrowing VariableOverride,
    context: Context,
    evaluationData: InstanceEvaluationDataProvider,
    options: EvaluateOptions
) throws -> Bool {
    guard let conditions = override.conditions else { return false }
    return try conditionsAreMatched(conditions, options: options)
}

private func cleanDependencies(_ dependencies: EvaluateDependencies) -> EvaluateDependencies {
    var result = EvaluateDependencies(
        context: dependencies.context,
        reportDiagnostic: dependencies.reportDiagnostic,
        diagnosticAudience: dependencies.diagnosticAudience,
        modulesManager: dependencies.modulesManager,
        evaluationData: dependencies.evaluationData,
        stickyFeatures: dependencies.stickyFeatures,
        stickyVariables: dependencies.stickyVariables,
        session: dependencies.session,
        stickySource: dependencies.stickySource,
        inheritedStickyFeatures: dependencies.inheritedStickyFeatures,
        inheritedStickyVariables: dependencies.inheritedStickyVariables,
        stickyFeaturesToken: dependencies.stickyFeaturesToken,
        stickyVariablesToken: dependencies.stickyVariablesToken
    )
    result.inheritedEvaluationData = dependencies.inheritedEvaluationData
    return result
}

private func dependencyOperand(_ requested: EvaluateOptions, options: EvaluateOptions, purpose: String = "condition") throws -> DependencyOperand {
    var refreshed = requested
    refreshed.dependencies.refreshSticky()
    return try options.dependencies.session.read(DependencyOf(refreshed), dependencies: refreshed.dependencies, purpose: purpose) { parent in
        var dependency = refreshed
        dependency.dependencyOf = parent
        dependency.dependencyPurpose = purpose
        let evaluation = evaluateWithModules(dependency)
        switch requested.type {
        case .flag:
            return .flag(evaluation.enabled == true)
        case .variation:
            return .variation(evaluation.variationValue ?? evaluation.variation?.value)
        case .variable:
            let value = evaluation.variableValue ?? .null
            let type = evaluation.variableSchema?.type ?? evaluation.globalVariable?.type
            if evaluation.globalVariable?.compose == nil, type == "json", case .string(let json) = value {
                if let decoded = try? JSONDecoder().decode(AnyValue.self, from: Data(json.utf8)) {
                    return .variable(decoded)
                }
                requested.dependencies.reportDiagnostic(FeaturevisorDiagnostic(
                    level: .error,
                    code: "evaluation_error",
                    message: "getVariable failed",
                    details: ["variableKey": .string(requested.variableKey ?? "")]
                ))
                return .variable(.null)
            }
            return .variable(value)
        }
    }
}

private func requiredVariableValue(
    _ required: VariableCondition,
    options: EvaluateOptions
) throws -> VariableValue? {
    let dependencies = cleanDependencies(options.dependencies)
    let operand: DependencyOperand
    if let feature = required.feature {
        operand = try dependencyOperand(EvaluateOptions(
            type: .variable,
            featureKey: feature,
            variableKey: required.variable,
            dependencies: dependencies
        ), options: options)
    } else {
        operand = try dependencyOperand(EvaluateOptions(
            type: .variable,
            variableKey: required.variable,
            globalVariable: true,
            dependencies: dependencies
        ), options: options)
    }
    if case .variable(let value) = operand { return value }
    return .null
}

private func variableConditionIsMatched(_ required: VariableCondition, options: EvaluateOptions) throws -> Bool {
            var value = try requiredVariableValue(required, options: options)
            if let path = required.path {
                for part in path {
                    switch part {
                    case .key(let key):
                        if unsafeMutationKeysForRequirements.contains(key) {
                            throw NSError(
                                domain: "Featurevisor",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Unsafe variable requirement path"]
                            )
                        }
                        if case .object(let object)? = value {
                            value = object[key]
                        } else if case .array(let array)? = value {
                            if key == "length" {
                                value = .int(array.count)
                            } else if let index = Int(key), String(index) == key, array.indices.contains(index) {
                                value = array[index]
                            } else {
                                value = nil
                            }
                        } else {
                            value = nil
                        }
                    case .index(let index):
                        if case .array(let array)? = value, array.indices.contains(index) {
                            value = array[index]
                        } else {
                            value = nil
                        }
                    }
                }
            }
            return try options.dependencies.evaluationData.valueIsMatched(
                value,
                operator: required.operator,
                expected: required.value,
                regexFlags: required.regexFlags
            )
}

private struct InvalidSelector: Error {}

private func attributeOnlyCondition(_ condition: Condition) -> Bool {
    switch condition {
    case .predicate: return true
    case .list(let items), .and(let items), .or(let items), .not(let items):
        return items.allSatisfy(attributeOnlyCondition)
    default: return false
    }
}

func conditionsAreMatched(_ condition: Condition, options: EvaluateOptions) throws -> Bool {
    do { return try matchCondition(condition, options: options) }
    catch is InvalidSelector { return false }
    catch is RequirementCycleError { throw RequirementCycleError() }
    catch let error as RequirementEvaluationError { throw error }
    catch { throw RequirementEvaluationError(message: error.localizedDescription) }
}

private func matchCondition(_ condition: Condition, options: EvaluateOptions) throws -> Bool {
    switch condition {
    case .all: return true
    case .null: return false
    case .invalid: throw InvalidSelector()
    case .predicate:
        return options.dependencies.evaluationData.allConditionsAreMatched(condition, context: options.dependencies.context)
    case .invalidToken(let key):
        var refreshed = options
        refreshed.dependencies.refreshSticky()
        guard let segment = refreshed.dependencies.evaluationData.getSegment(key) else { return false }
        if case .tree(let value) = segment.conditions {
            if case .invalid = value { throw InvalidSelector() }
            if attributeOnlyCondition(value) {
                return refreshed.dependencies.evaluationData.allConditionsAreMatched(value, context: refreshed.dependencies.context)
            }
        }
        return try refreshed.dependencies.session.segment(key) {
            switch segment.conditions {
            case .tree(let value): return try matchCondition(value, options: refreshed)
            case .string: throw InvalidSelector()
            }
        }
    case .variable(let value): return try variableConditionIsMatched(value, options: options)
    case .feature(let value):
        let dependencies = cleanDependencies(options.dependencies)
        guard case .flag(let enabled) = try dependencyOperand(EvaluateOptions(type: .flag, featureKey: value.feature, dependencies: dependencies), options: options),
              enabled == (value.enabled ?? true) else { return false }
        guard let variation = value.variation else { return true }
        if case .variation(let actual) = try dependencyOperand(EvaluateOptions(type: .variation, featureKey: value.feature, dependencies: dependencies), options: options) {
            return actual == variation
        }
        return false
    case .list(let items), .and(let items):
        guard !items.isEmpty else { return false }
        for item in items where try !matchCondition(item, options: options) { return false }
        return true
    case .or(let items):
        for item in items where try matchCondition(item, options: options) { return true }
        return false
    case .not(let items):
        guard !items.isEmpty else { return false }
        for item in items where try !matchCondition(item, options: options) { return true }
        return false
    }
}

private let unsafeMutationKeysForRequirements = Set(["__proto__", "prototype", "constructor"])

private func programStepIsMatched(
    _ override: borrowing VariableOverrideProgramStep,
    options: EvaluateOptions
) throws -> Bool {
    guard let conditions = override.conditions else { return true }
    return try conditionsAreMatched(conditions, options: options)
}

private func evaluateGlobalVariable(_ variableKey: VariableKey, options: EvaluateOptions) throws -> Evaluation {
    var out = Evaluation(type: .variable, reason: .variableDefault)
    let dependencies = options.dependencies
    let definition = dependencies.evaluationData.getGlobalVariable(variableKey)
    if let sticky = dependencies.stickyVariables?[variableKey] {
        out = Evaluation(type: .variable, reason: .sticky)
        out.variableKey = variableKey
        out.variableValue = sticky
        out.globalVariable = definition
        return out
    }

    guard let variable = definition else {
        out = Evaluation(type: .variable, reason: .variableNotFound)
        out.variableKey = variableKey
        return out
    }

    if variable.deprecated == true {
        dependencies.reportDiagnostic(FeaturevisorDiagnostic(level: .warn, code: "deprecated_variable", message: "Variable is deprecated", details: ["variableKey": .string(variableKey)]))
    }
    if let conditions = variable.conditions, try !conditionsAreMatched(conditions, options: options) {
        out = Evaluation(type: .variable, reason: .conditionsUnmet)
        out.variableKey = variableKey
        out.globalVariable = variable
        out.conditions = conditions
        if variable.compose == nil, variable.useDefaultWhenDisabled == true { out.variableValue = variable.defaultValue }
        else { out.variableValue = variable.disabledValue }
        return out
    }

    var initialValue = variable.defaultValue ?? .null
    if let compose = variable.compose {
        let clean = cleanDependencies(dependencies)
        func read(_ feature: String?, _ variable: String?, variation: Bool = false) throws -> AnyValue {
            let requested = EvaluateOptions(
                type: variable != nil ? .variable : variation ? .variation : .flag,
                featureKey: feature ?? "", variableKey: variable,
                globalVariable: feature == nil, dependencies: clean
            )
            switch try dependencyOperand(requested, options: options, purpose: "composition") {
            case .flag(let value): return .bool(value)
            case .variation(let value): return value.map(AnyValue.string) ?? .null
            case .variable(let value): return value
            }
        }
        switch compose {
        case .alias(let key):
            guard !key.isEmpty else { throw NSError(domain: "Featurevisor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid composition source"]) }
            initialValue = try read(nil, key)
        case .members(let entries):
            guard !entries.isEmpty else { throw NSError(domain: "Featurevisor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty composition"]) }
            var value: [String: AnyValue] = [:]
            for entry in entries {
                guard !entry.key.isEmpty, !unsafeMutationKeysForRequirements.contains(entry.key),
                      entry.feature != nil || entry.variable != nil else {
                    throw NSError(domain: "Featurevisor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid composition property"])
                }
                value[entry.key] = try read(entry.feature, entry.variable, variation: entry.variation == true)
            }
            initialValue = .object(value)
        }
    }

    if let program = variable.overrideProgram {
        var index = 0
        var value = initialValue
        var result: Evaluation?
        var paths: [[String]] = []
        while index < program.count {
            let matched = try programStepIsMatched(program[index], options: options)
            if matched {
                let step = program[index]
                value = try applyVariableOperations(value, operations: step.operations)
                paths.append(step.keyPath ?? [step.key])
                out = Evaluation(type: .variable, reason: .variableOverrideRule)
                out.variableKey = variableKey
                out.variableValue = value
                out.globalVariable = variable
                out.variableOverrideIndex = index
                out.variableOverrideKey = step.key
                out.variableOverridePath = step.keyPath
                out.variableOverridePaths = paths
                result = out
            }
            let next = matched ? program[index].onMatch : program[index].onMiss
            guard next > index, next <= program.count else { throw VariableMutationError.invalidJump }
            index = next
        }
        if let result { return result }
    } else if let overrides = variable.overrides,
              let index = try firstMatchedOverrideIndex(overrides: overrides, options: options) {
        let matched = overrides[index]
        out = Evaluation(type: .variable, reason: .variableOverrideRule)
        out.variableKey = variableKey
        out.variableValue = matched.value
        out.globalVariable = variable
        out.variableOverrideIndex = index
        out.variableOverrideKey = matched.key
        out.variableOverridePath = matched.keyPath
        return out
    }

    out = Evaluation(type: .variable, reason: variable.compose == nil ? .variableDefault : .variableComposed)
    out.variableKey = variableKey
    out.variableValue = initialValue
    out.globalVariable = variable
    return out
}
