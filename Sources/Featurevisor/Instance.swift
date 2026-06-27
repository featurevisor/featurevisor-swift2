import Foundation

public struct FeaturevisorOptions: Sendable {
    public var datafile: DatafileContent?
    public var context: Context
    public var logLevel: LogLevel
    public var logger: Logger?
    public var onDiagnostic: FeaturevisorDiagnosticHandler?
    public var sticky: StickyFeatures?
    public var modules: [FeaturevisorModule]

    public init(
        datafile: DatafileContent? = nil,
        context: Context = [:],
        logLevel: LogLevel = Logger.defaultLevel,
        logger: Logger? = nil,
        onDiagnostic: FeaturevisorDiagnosticHandler? = nil,
        sticky: StickyFeatures? = nil,
        modules: [FeaturevisorModule] = []
    ) {
        self.datafile = datafile
        self.context = context
        self.logLevel = logLevel
        self.logger = logger
        self.onDiagnostic = onDiagnostic
        self.sticky = sticky
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

public final class FeaturevisorInstance: @unchecked Sendable {
    private var context: Context
    private let logger: Logger
    private var logLevel: LogLevel
    private let onDiagnostic: FeaturevisorDiagnosticHandler?
    private var sticky: StickyFeatures?

    private var datafile: DatafileContent
    private var datafileReader: DatafileReader
    private var modulesManager: ModulesManager!
    private var moduleDiagnosticSubscriptions: [ModuleDiagnosticSubscription] = []
    private let emitter: Emitter
    private var closed = false

    public init(options: FeaturevisorOptions) {
        self.context = options.context
        self.logger = options.logger ?? createLogger(level: options.logLevel)
        self.logLevel = options.logLevel
        self.onDiagnostic = options.onDiagnostic
        self.sticky = options.sticky
        self.emitter = Emitter()
        self.datafile = emptyDatafile
        self.datafileReader = DatafileReader(datafile: emptyDatafile, logger: self.logger)

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

        if let datafile = options.datafile {
            setDatafile(datafile, replace: true)
        }

        reportDiagnostic(FeaturevisorDiagnostic(level: .info, code: "sdk_initialized", message: "SDK initialized"))
    }

    public func setLogLevel(_ level: LogLevel) {
        logLevel = level
        logger.setLevel(level)
    }

    public func setDatafile(_ datafile: DatafileContent, replace: Bool = false) {
        guard !closed else { return }

        let storedDatafile = replace ? datafile : mergeStoredDatafile(existing: self.datafile, incoming: datafile)
        let newDatafileReader = DatafileReader(datafile: storedDatafile, logger: logger)
        let details = getParamsForDatafileSetEvent(
            previousDatafileReader: datafileReader,
            newDatafileReader: newDatafileReader,
            replace: replace
        )

        self.datafile = storedDatafile
        self.datafileReader = newDatafileReader

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

    public func setSticky(_ sticky: StickyFeatures, replace: Bool = false) {
        guard !closed else { return }

        let previousSticky = self.sticky ?? [:]
        if replace {
            self.sticky = sticky
        } else {
            self.sticky = (self.sticky ?? [:]).merging(sticky, uniquingKeysWith: { _, new in new })
        }
        let payload = getParamsForStickySetEvent(previousStickyFeatures: previousSticky, newStickyFeatures: self.sticky ?? [:], replace: replace)
        reportDiagnostic(FeaturevisorDiagnostic(level: .info, code: "sticky_set", message: "Sticky features set", details: payload))
        emitter.trigger(.stickySet, payload: EventPayload(payload))
    }

    public func getRevision() -> String { datafileReader.getRevision() }
    public func getFeature(_ featureKey: String) -> Feature? { datafileReader.getFeature(featureKey) }

    @discardableResult
    public func addModule(_ module: FeaturevisorModule) -> FeaturevisorUnsubscribe? {
        guard !closed else { return nil }
        return modulesManager.add(module)
    }

    public func removeModule(_ name: String) {
        guard !closed else { return }
        modulesManager.remove(name)
    }

    @discardableResult
    public func on(_ eventName: EventName, callback: @escaping EventCallback) -> FeaturevisorUnsubscribe {
        guard !closed else { return {} }
        return emitter.on(eventName, callback: callback)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        modulesManager.closeAll()
        moduleDiagnosticSubscriptions = []
        emitter.clearAll()
    }

    private func reportDiagnostic(_ diagnostic: FeaturevisorDiagnostic, sourceModule: FeaturevisorModule? = nil) {
        for subscription in moduleDiagnosticSubscriptions {
            if let sourceModule, subscription.moduleID == sourceModule.id {
                continue
            }
            if shouldLogDiagnostic(currentLevel: subscription.logLevel, diagnosticLevel: diagnostic.level) {
                subscription.handler(diagnostic)
            }
        }

        if shouldLogDiagnostic(currentLevel: logLevel, diagnosticLevel: diagnostic.level) {
            if let onDiagnostic {
                onDiagnostic(diagnostic)
            } else {
                var details = diagnostic.details.mapValues { String(describing: $0.rawValue) }
                details["code"] = diagnostic.code
                if let module = diagnostic.module { details["module"] = module }
                if let moduleName = diagnostic.moduleName { details["moduleName"] = moduleName }
                if let originalError = diagnostic.originalError { details["originalError"] = originalError }

                switch diagnostic.level {
                case .debug: logger.debug(diagnostic.message, details: details)
                case .info: logger.info(diagnostic.message, details: details)
                case .warn: logger.warn(diagnostic.message, details: details)
                case .error: logger.error(diagnostic.message, details: details)
                case .fatal: logger.fatal(diagnostic.message, details: details)
                }
            }
        }

        if diagnostic.level == .error {
            emitter.trigger(.error, payload: EventPayload([
                "code": .string(diagnostic.code),
                "message": .string(diagnostic.message),
                "level": .string("error"),
            ]))
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
                self.moduleDiagnosticSubscriptions.append(subscription)

                return { [weak self] in
                    self?.moduleDiagnosticSubscriptions.removeAll(where: { $0.id == subscription.id })
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
        moduleDiagnosticSubscriptions.removeAll(where: { $0.moduleID == module.id })
    }

    public func setContext(_ context: Context, replace: Bool = false) {
        guard !closed else { return }

        if replace {
            self.context = context
        } else {
            self.context = self.context.merging(context, uniquingKeysWith: { _, new in new })
        }
        emitter.trigger(.contextSet, payload: EventPayload([
            "context": .object(self.context),
            "replaced": .bool(replace),
        ]))
    }

    public func getContext(_ context: Context? = nil) -> Context {
        guard let context else { return self.context }
        return self.context.merging(context, uniquingKeysWith: { _, new in new })
    }

    public func spawn(_ context: Context = [:], options: OverrideOptions = OverrideOptions()) -> FeaturevisorChildInstance {
        FeaturevisorChildInstance(parent: self, context: getContext(context), sticky: options.sticky)
    }

    private func dependencies(_ context: Context, options: OverrideOptions = OverrideOptions()) -> EvaluateDependencies {
        EvaluateDependencies(
            context: getContext(context),
            logger: logger,
            modulesManager: modulesManager,
            datafileReader: datafileReader,
            sticky: options.sticky == nil ? sticky : (sticky ?? [:]).merging(options.sticky ?? [:], uniquingKeysWith: { _, new in new }),
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

    public func getAllEvaluations(_ context: Context = [:], _ featureKeys: [FeatureKey] = [], _ options: OverrideOptions = OverrideOptions()) -> EvaluatedFeatures {
        var result: EvaluatedFeatures = [:]
        let targetKeys = featureKeys.isEmpty ? datafileReader.getFeatureKeys() : featureKeys
        for key in targetKeys {
            let enabled = isEnabled(key, context, options)
            let variation = getVariation(key, context, options)
            var variables: [VariableKey: VariableValue] = [:]
            for variableKey in datafileReader.getVariableKeys(key) {
                if let value = getVariable(key, variableKey, context, options) {
                    variables[variableKey] = value
                }
            }
            result[key] = EvaluatedFeature(enabled: enabled, variation: variation, variables: variables.isEmpty ? nil : variables)
        }
        return result
    }
}

private func mergeStoredDatafile(existing: DatafileContent, incoming: DatafileContent) -> DatafileContent {
    DatafileContent(
        schemaVersion: incoming.schemaVersion,
        revision: incoming.revision,
        featurevisorVersion: incoming.featurevisorVersion,
        segments: existing.segments.merging(incoming.segments, uniquingKeysWith: { _, new in new }),
        features: existing.features.merging(incoming.features, uniquingKeysWith: { _, new in new })
    )
}

public func createInstance(_ options: FeaturevisorOptions = FeaturevisorOptions()) -> FeaturevisorInstance {
    FeaturevisorInstance(options: options)
}
