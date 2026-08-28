import Foundation

public struct FeaturevisorOptions: Sendable {
    public var datafile: DatafileContent?
    public var context: Context
    public var logLevel: LogLevel
    public var onDiagnostic: FeaturevisorDiagnosticHandler?
    public var stickyFeatures: StickyFeatures?
    public var stickyVariables: StickyVariables?
    public var modules: [FeaturevisorModule]

    public init(
        datafile: DatafileContent? = nil,
        context: Context = [:],
        logLevel: LogLevel = .info,
        onDiagnostic: FeaturevisorDiagnosticHandler? = nil,
        stickyFeatures: StickyFeatures? = nil,
        stickyVariables: StickyVariables? = nil,
        modules: [FeaturevisorModule] = []
    ) {
        self.datafile = datafile
        self.context = context
        self.logLevel = logLevel
        self.onDiagnostic = onDiagnostic
        self.stickyFeatures = stickyFeatures
        self.stickyVariables = stickyVariables
        self.modules = modules
    }
}

private let emptyDatafile = DatafileContent(schemaVersion: "2", revision: "unknown", segments: [:], features: [:])

private struct ModuleDiagnosticSubscription: Sendable {
    let id: UUID
    let moduleID: UUID
    let handler: FeaturevisorDiagnosticHandler
    let logLevel: LogLevel
}

public final class Featurevisor: @unchecked Sendable {
    private let lock = FeaturevisorLock()
    private var context: Context
    private var logLevel: LogLevel
    private let onDiagnostic: FeaturevisorDiagnosticHandler?
    private var stickyFeatures: StickyFeatures?
    private var stickyVariables: StickyVariables?

    private var datafile: DatafileContent
    private var evaluationData: InstanceEvaluationDataProvider
    private var modulesManager: ModulesManager!
    private var moduleDiagnosticSubscriptions: [ModuleDiagnosticSubscription] = []
    private let emitter: Emitter
    private var closed = false

    fileprivate init(options: FeaturevisorOptions) {
        self.context = options.context
        self.logLevel = options.logLevel
        self.onDiagnostic = options.onDiagnostic
        self.stickyFeatures = options.stickyFeatures
        self.stickyVariables = options.stickyVariables
        self.emitter = Emitter()
        self.datafile = emptyDatafile
        self.evaluationData = InstanceEvaluationDataProvider(datafile: emptyDatafile, reportDiagnostic: { _ in })

        self.modulesManager = ModulesManager(
            modules: options.modules,
            reportDiagnostic: { [weak self] diagnostic, sourceModule in
                self?.reportDiagnostic(diagnostic, sourceModule: sourceModule)
            },
            getModuleApi: { [weak self] module in
                self?.getModuleApi(module) ?? FeaturevisorModuleApi(
                    getRevision: { "unknown" },
                    onDiagnostic: { _, _ in {} },
                    reportDiagnostic: { _ in }
                )
            },
            clearModuleDiagnosticSubscriptions: { [weak self] module in
                self?.clearModuleDiagnosticSubscriptions(module)
            }
        )

        self.evaluationData = InstanceEvaluationDataProvider(
            datafile: emptyDatafile,
            reportDiagnostic: { [weak self] diagnostic in self?.reportDiagnostic(diagnostic) }
        )

        if let datafile = options.datafile {
            setDatafile(datafile, replace: true)
        }

        reportDiagnostic(FeaturevisorDiagnostic(level: .info, code: "sdk_initialized", message: "SDK initialized"))
    }

    public func setLogLevel(_ level: LogLevel) {
        lock.withLock { logLevel = level }
    }

    public func setDatafile(_ datafile: DatafileContent, replace: Bool = false) {
        let result = lock.withLock { () -> [String: AnyValue]? in
            guard !closed else { return nil }
            let storedDatafile = replace ? datafile : mergeStoredDatafile(existing: self.datafile, incoming: datafile)
            let newInstanceEvaluationDataProvider = InstanceEvaluationDataProvider(
                datafile: storedDatafile,
                reportDiagnostic: { [weak self] diagnostic in self?.reportDiagnostic(diagnostic) }
            )
            let details = getParamsForDatafileSetEvent(
                previousInstanceEvaluationDataProvider: evaluationData,
                newInstanceEvaluationDataProvider: newInstanceEvaluationDataProvider,
                replace: replace
            )
            self.datafile = storedDatafile
            self.evaluationData = newInstanceEvaluationDataProvider
            return details
        }
        guard let details = result else { return }

        reportDiagnostic(FeaturevisorDiagnostic(level: .info, code: "datafile_set", message: "Datafile set", details: details))
        emitter.trigger(.datafileSet, payload: EventPayload(details))
    }

    public func setDatafile(json: String, replace: Bool = false) {
        do {
            setDatafile(try DatafileContent.fromJSON(json), replace: replace)
        } catch {
            reportDiagnostic(FeaturevisorDiagnostic(
                level: .error,
                code: "invalid_datafile",
                message: "Could not parse datafile",
                originalError: error.localizedDescription
            ))
        }
    }

    public func setStickyFeatures(_ sticky: StickyFeatures, replace: Bool = false) {
        let values = lock.withLock { () -> (StickyFeatures, StickyFeatures)? in
            guard !closed else { return nil }
            let previous = self.stickyFeatures ?? [:]
            self.stickyFeatures = replace ? sticky : previous.merging(sticky, uniquingKeysWith: { _, new in new })
            return (previous, self.stickyFeatures ?? [:])
        }
        guard let (previousSticky, newSticky) = values else { return }
        let payload = getParamsForStickyFeaturesSetEvent(previousStickyFeatures: previousSticky, newStickyFeatures: newSticky, replace: replace)
        reportDiagnostic(FeaturevisorDiagnostic(level: .info, code: "sticky_features_set", message: "Sticky features set", details: payload))
        emitter.trigger(.stickyFeaturesSet, payload: EventPayload(payload))
    }

    public func setStickyVariables(_ sticky: StickyVariables, replace: Bool = false) {
        let values = lock.withLock { () -> (StickyVariables, StickyVariables)? in
            guard !closed else { return nil }
            let previous = self.stickyVariables ?? [:]
            self.stickyVariables = replace ? sticky : previous.merging(sticky, uniquingKeysWith: { _, new in new })
            return (previous, self.stickyVariables ?? [:])
        }
        guard let values else { return }
        let payload = getParamsForStickyVariablesSetEvent(previousStickyVariables: values.0, newStickyVariables: values.1, replace: replace)
        reportDiagnostic(FeaturevisorDiagnostic(level: .info, code: "sticky_variables_set", message: "Sticky variables set", details: payload))
        emitter.trigger(.stickyVariablesSet, payload: EventPayload(payload))
    }

    private func reader() -> InstanceEvaluationDataProvider { lock.withLock { evaluationData } }
    public func getRevision() -> String { reader().getRevision() }
    public func getSchemaVersion() -> String { reader().getSchemaVersion() }
    public func getSegment(_ segmentKey: SegmentKey) -> Segment? { reader().getSegment(segmentKey) }
    public func getFeature(_ featureKey: String) -> Feature? { reader().getFeature(featureKey) }
    public func getFeatureKeys() -> [FeatureKey] { reader().getFeatureKeys() }
    public func getVariableKeys(_ featureKey: FeatureKey? = nil) -> [String] {
        guard let featureKey else { return reader().getGlobalVariableKeys() }
        return reader().getVariableKeys(featureKey)
    }
    public func hasVariations(_ featureKey: FeatureKey) -> Bool { reader().hasVariations(featureKey) }

    @discardableResult
    public func addModule(_ module: FeaturevisorModule) -> FeaturevisorUnsubscribe? {
        guard lock.withLock({ !closed }) else { return nil }
        return modulesManager.add(module)
    }

    public func removeModule(_ name: String) {
        guard lock.withLock({ !closed }) else { return }
        modulesManager.remove(name)
    }

    @discardableResult
    public func on(_ eventName: EventName, callback: @escaping EventCallback) -> FeaturevisorUnsubscribe {
        guard lock.withLock({ !closed }) else { return {} }
        return emitter.on(eventName, callback: callback)
    }

    public func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            moduleDiagnosticSubscriptions = []
            return true
        }
        guard shouldClose else { return }
        modulesManager.closeAll()
        emitter.clearAll()
    }

    private func reportDiagnostic(_ diagnostic: FeaturevisorDiagnostic, sourceModule: FeaturevisorModule? = nil) {
        let snapshot = lock.withLock { (moduleDiagnosticSubscriptions, logLevel, onDiagnostic) }
        for subscription in snapshot.0 {
            if let sourceModule, subscription.moduleID == sourceModule.id {
                continue
            }
            if shouldLogDiagnostic(currentLevel: subscription.logLevel, diagnosticLevel: diagnostic.level) {
                subscription.handler(diagnostic)
            }
        }

        if shouldLogDiagnostic(currentLevel: snapshot.1, diagnosticLevel: diagnostic.level) {
            if let onDiagnostic = snapshot.2 {
                onDiagnostic(diagnostic)
            } else {
                writeDiagnosticToConsole(diagnostic)
            }
        }

        if diagnostic.level == .error {
            var normalized: [String: AnyValue] = [
                "level": .string(String(describing: diagnostic.level)),
                "code": .string(diagnostic.code),
                "message": .string(diagnostic.message),
                "details": .object(diagnostic.details),
            ]
            if let module = diagnostic.module { normalized["module"] = .string(module) }
            if let moduleName = diagnostic.moduleName { normalized["moduleName"] = .string(moduleName) }
            if let originalError = diagnostic.originalError { normalized["originalError"] = .string(originalError) }
            emitter.trigger(.error, payload: EventPayload(["diagnostic": .object(normalized)]))
        }
    }

    private func getModuleApi(_ module: FeaturevisorModule) -> FeaturevisorModuleApi {
        FeaturevisorModuleApi(
            getRevision: { [weak self] in
                self?.getRevision() ?? "unknown"
            },
            onDiagnostic: { [weak self] handler, options in
                guard let self else { return {} }
                let subscription = ModuleDiagnosticSubscription(
                    id: UUID(),
                    moduleID: module.id,
                    handler: handler,
                    logLevel: options.logLevel
                )
                let added = self.lock.withLock { () -> Bool in
                    guard !self.closed else { return false }
                    self.moduleDiagnosticSubscriptions.append(subscription)
                    return true
                }
                guard added else { return {} }

                return { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        self.moduleDiagnosticSubscriptions.removeAll(where: { $0.id == subscription.id })
                    }
                }
            },
            reportDiagnostic: { [weak self] diagnostic in
                var moduleDiagnostic = diagnostic
                if let name = module.name {
                    moduleDiagnostic.module = name
                }
                self?.reportDiagnostic(moduleDiagnostic, sourceModule: module)
            }
        )
    }

    private func clearModuleDiagnosticSubscriptions(_ module: FeaturevisorModule) {
        lock.withLock { moduleDiagnosticSubscriptions.removeAll(where: { $0.moduleID == module.id }) }
    }

    public func setContext(_ context: Context, replace: Bool = false) {
        let newContext = lock.withLock { () -> Context? in
            guard !closed else { return nil }
            self.context = replace ? context : self.context.merging(context, uniquingKeysWith: { _, new in new })
            return self.context
        }
        guard let newContext else { return }
        emitter.trigger(.contextSet, payload: EventPayload([
            "context": .object(newContext),
            "replaced": .bool(replace),
        ]))
        reportDiagnostic(FeaturevisorDiagnostic(
            level: .debug,
            code: "context_set",
            message: replace ? "Context replaced" : "Context updated",
            details: [
                "context": .object(newContext),
                "replaced": .bool(replace),
            ]
        ))
    }

    public func getContext(_ context: Context? = nil) -> Context {
        lock.withLock {
            guard let context else { return self.context }
            return self.context.merging(context, uniquingKeysWith: { _, new in new })
        }
    }

    public func spawn(_ context: Context = [:], options: SpawnOptions = SpawnOptions()) -> FeaturevisorChildInstance {
        FeaturevisorChildInstance(parent: self, context: getContext(context), stickyFeatures: options.stickyFeatures, stickyVariables: options.stickyVariables)
    }

    private func dependencies(_ context: Context, options: OverrideOptions = OverrideOptions()) -> EvaluateDependencies {
        let snapshot = lock.withLock {
            (
                self.context.merging(context, uniquingKeysWith: { _, new in new }),
                evaluationData,
                options.stickyFeatures ?? stickyFeatures,
                options.stickyVariables ?? stickyVariables
            )
        }
        return EvaluateDependencies(
            context: snapshot.0,
            reportDiagnostic: { [weak self] diagnostic in
                self?.reportDiagnostic(diagnostic)
            },
            modulesManager: modulesManager,
            evaluationData: snapshot.1,
            stickyFeatures: snapshot.2,
            stickyVariables: snapshot.3,
            defaultVariationValue: options.defaultVariationValue,
            defaultVariableValue: options.defaultVariableValue
        )
    }

    public func evaluateFlag(_ featureKey: FeatureKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        evaluateWithModules(EvaluateOptions(type: .flag, featureKey: featureKey, dependencies: dependencies(context, options: options)))
    }

    public func isEnabled(_ featureKey: FeatureKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Bool {
        evaluateFlag(featureKey, context: context, options: options).enabled == true
    }

    public func evaluateVariation(_ featureKey: FeatureKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        evaluateWithModules(EvaluateOptions(type: .variation, featureKey: featureKey, dependencies: dependencies(context, options: options)))
    }

    public func getVariation(_ featureKey: FeatureKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> VariationValue? {
        evaluateVariation(featureKey, context: context, options: options).variationValue
    }

    public func evaluateVariable(_ featureKey: FeatureKey, _ variableKey: VariableKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        evaluateWithModules(EvaluateOptions(type: .variable, featureKey: featureKey, variableKey: variableKey, dependencies: dependencies(context, options: options)))
    }

    public func evaluateVariable(_ variableKey: VariableKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        evaluateWithModules(EvaluateOptions(type: .variable, variableKey: variableKey, globalVariable: true, dependencies: dependencies(context, options: options)))
    }

    public func getVariable(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> VariableValue? {
        let evaluation = evaluateVariable(variableKey, context: context, options: options)
        let value = evaluation.variableValue ?? options.defaultVariableValue
        if evaluation.globalVariable?.type == "json", case .string(let json)? = value,
           let data = json.data(using: .utf8), let parsed = try? JSONDecoder().decode(AnyValue.self, from: data) { return parsed }
        return value
    }

    public func getVariableBoolean(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Bool? { getValueByType(getVariable(variableKey, context, options), fieldType: "boolean")?.asBool() }
    public func getVariableString(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> String? { getValueByType(getVariable(variableKey, context, options), fieldType: "string")?.asString() }
    public func getVariableInteger(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Int? { getValueByType(getVariable(variableKey, context, options), fieldType: "integer")?.asInt() }
    public func getVariableDouble(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Double? { getValueByType(getVariable(variableKey, context, options), fieldType: "double")?.asDouble() }
    public func getVariableArray(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [AnyValue]? { getValueByType(getVariable(variableKey, context, options), fieldType: "array")?.asArray() }
    public func getVariableObject(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [String: AnyValue]? { getValueByType(getVariable(variableKey, context, options), fieldType: "object")?.asObject() }
    public func getVariableJSON(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> AnyValue? { getVariable(variableKey, context, options) }

    public func getVariable(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> VariableValue? {
        let evaluation = evaluateVariable(featureKey, variableKey, context: context, options: options)
        if evaluation.variableSchema?.type == "json",
           case .string(let jsonString)? = evaluation.variableValue,
           let data = jsonString.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(AnyValue.self, from: data) {
            return parsed
        }
        return evaluation.variableValue
    }

    public func getVariableBoolean(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Bool? {
        getValueByType(getVariable(featureKey, variableKey, context, options), fieldType: "boolean")?.asBool()
    }

    public func getVariableString(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> String? {
        getValueByType(getVariable(featureKey, variableKey, context, options), fieldType: "string")?.asString()
    }

    public func getVariableInteger(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Int? {
        getValueByType(getVariable(featureKey, variableKey, context, options), fieldType: "integer")?.asInt()
    }

    public func getVariableDouble(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Double? {
        getValueByType(getVariable(featureKey, variableKey, context, options), fieldType: "double")?.asDouble()
    }

    public func getVariableArray(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [AnyValue]? {
        getValueByType(getVariable(featureKey, variableKey, context, options), fieldType: "array")?.asArray()
    }

    public func getVariableObject(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [String: AnyValue]? {
        getValueByType(getVariable(featureKey, variableKey, context, options), fieldType: "object")?.asObject()
    }

    public func getVariableJSON(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> AnyValue? {
        getVariable(featureKey, variableKey, context, options)
    }

    public func getFeatureEvaluations(_ context: Context = [:], _ featureKeys: [FeatureKey] = [], _ options: OverrideOptions = OverrideOptions()) -> EvaluatedFeatures {
        var result: EvaluatedFeatures = [:]
        let reader = reader()
        let targetKeys = featureKeys.isEmpty ? reader.getFeatureKeys() : featureKeys
        for key in targetKeys {
            let enabled = isEnabled(key, context, options)
            let variation = getVariation(key, context, options)
            var variables: [VariableKey: VariableValue] = [:]
            for variableKey in reader.getVariableKeys(key) {
                if let value = getVariable(key, variableKey, context, options) {
                    variables[variableKey] = value
                }
            }
            result[key] = EvaluatedFeature(enabled: enabled, variation: variation, variables: variables.isEmpty ? nil : variables)
        }
        return result
    }


    public func getVariableEvaluations(_ context: Context = [:], _ variableKeys: [VariableKey] = [], _ options: OverrideOptions = OverrideOptions()) -> EvaluatedVariables {
        var result: EvaluatedVariables = [:]
        let keys = variableKeys.isEmpty ? reader().getGlobalVariableKeys() : variableKeys
        for key in keys { if let value = getVariable(key, context, options) { result[key] = value } }
        return result
    }
}

private func mergeStoredDatafile(existing: DatafileContent, incoming: DatafileContent) -> DatafileContent {
    DatafileContent(
        schemaVersion: incoming.schemaVersion,
        revision: incoming.revision,
        featurevisorVersion: incoming.featurevisorVersion,
        segments: existing.segments.merging(incoming.segments, uniquingKeysWith: { _, new in new }),
        features: existing.features.merging(incoming.features, uniquingKeysWith: { _, new in new }),
        variables: (existing.variables ?? [:]).merging(incoming.variables ?? [:], uniquingKeysWith: { _, new in new })
    )
}

public func createFeaturevisor(_ options: FeaturevisorOptions = FeaturevisorOptions()) -> Featurevisor {
    Featurevisor(options: options)
}
