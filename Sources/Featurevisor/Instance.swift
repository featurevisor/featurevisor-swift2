import Foundation

public struct InstanceOptions: Sendable {
    public var datafile: DatafileContent?
    public var context: Context
    public var logLevel: LogLevel
    public var logger: Logger?
    public var sticky: StickyFeatures?
    public var hooks: [Hook]

    public init(
        datafile: DatafileContent? = nil,
        context: Context = [:],
        logLevel: LogLevel = Logger.defaultLevel,
        logger: Logger? = nil,
        sticky: StickyFeatures? = nil,
        hooks: [Hook] = []
    ) {
        self.datafile = datafile
        self.context = context
        self.logLevel = logLevel
        self.logger = logger
        self.sticky = sticky
        self.hooks = hooks
    }
}

private let emptyDatafile = DatafileContent(schemaVersion: "2", revision: "unknown", segments: [:], features: [:])

public final class FeaturevisorInstance: @unchecked Sendable {
    private var context: Context
    private let logger: Logger
    private var sticky: StickyFeatures?

    private var datafileReader: DatafileReader
    private let hooksManager: HooksManager
    private let emitter: Emitter

    public init(options: InstanceOptions) {
        self.context = options.context
        self.logger = options.logger ?? createLogger(level: options.logLevel)
        self.sticky = options.sticky
        self.hooksManager = HooksManager(hooks: options.hooks, logger: self.logger)
        self.emitter = Emitter()
        self.datafileReader = DatafileReader(datafile: options.datafile ?? emptyDatafile, logger: self.logger)
        self.logger.info("Featurevisor SDK initialized")
    }

    public func setLogLevel(_ level: LogLevel) {
        logger.setLevel(level)
    }

    public func setDatafile(_ datafile: DatafileContent) {
        self.datafileReader = DatafileReader(datafile: datafile, logger: logger)
        emitter.trigger(.datafileSet, payload: EventPayload(["revision": datafile.revision]))
    }

    public func setDatafile(json: String) {
        do {
            setDatafile(try DatafileContent.fromJSON(json))
        } catch {
            logger.error("could not parse datafile", details: ["error": error.localizedDescription])
        }
    }

    public func setSticky(_ sticky: StickyFeatures, replace: Bool = false) {
        if replace {
            self.sticky = sticky
        } else {
            self.sticky = (self.sticky ?? [:]).merging(sticky, uniquingKeysWith: { _, new in new })
        }
        emitter.trigger(.stickySet)
    }

    public func getRevision() -> String { datafileReader.getRevision() }
    public func getFeature(_ featureKey: String) -> Feature? { datafileReader.getFeature(featureKey) }

    @discardableResult
    public func addHook(_ hook: Hook) -> () -> Void { hooksManager.add(hook) }

    @discardableResult
    public func on(_ eventName: EventName, callback: @escaping EventCallback) -> () -> Void {
        emitter.on(eventName, callback: callback)
    }

    public func close() {
        emitter.clearAll()
    }

    public func setContext(_ context: Context, replace: Bool = false) {
        if replace {
            self.context = context
        } else {
            self.context = self.context.merging(context, uniquingKeysWith: { _, new in new })
        }
        emitter.trigger(.contextSet)
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
            hooksManager: hooksManager,
            datafileReader: datafileReader,
            sticky: options.sticky == nil ? sticky : (sticky ?? [:]).merging(options.sticky ?? [:], uniquingKeysWith: { _, new in new }),
            defaultVariationValue: options.defaultVariationValue,
            defaultVariableValue: options.defaultVariableValue
        )
    }

    public func evaluateFlag(_ featureKey: FeatureKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        evaluateWithHooks(EvaluateOptions(type: .flag, featureKey: featureKey, dependencies: dependencies(context, options: options)))
    }

    public func isEnabled(_ featureKey: FeatureKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Bool {
        evaluateFlag(featureKey, context: context, options: options).enabled == true
    }

    public func evaluateVariation(_ featureKey: FeatureKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        evaluateWithHooks(EvaluateOptions(type: .variation, featureKey: featureKey, dependencies: dependencies(context, options: options)))
    }

    public func getVariation(_ featureKey: FeatureKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> VariationValue? {
        evaluateVariation(featureKey, context: context, options: options).variationValue
    }

    public func evaluateVariable(_ featureKey: FeatureKey, _ variableKey: VariableKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        evaluateWithHooks(EvaluateOptions(type: .variable, featureKey: featureKey, variableKey: variableKey, dependencies: dependencies(context, options: options)))
    }

    public func getVariable(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> VariableValue? {
        evaluateVariable(featureKey, variableKey, context: context, options: options).variableValue
    }

    public func getVariableBoolean(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Bool? {
        getVariable(featureKey, variableKey, context, options)?.asBool()
    }

    public func getVariableString(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> String? {
        getVariable(featureKey, variableKey, context, options)?.asString()
    }

    public func getVariableInteger(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Int? {
        getVariable(featureKey, variableKey, context, options)?.asInt()
    }

    public func getVariableDouble(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Double? {
        getVariable(featureKey, variableKey, context, options)?.asDouble()
    }

    public func getVariableArray(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [AnyValue]? {
        getVariable(featureKey, variableKey, context, options)?.asArray()
    }

    public func getVariableObject(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [String: AnyValue]? {
        getVariable(featureKey, variableKey, context, options)?.asObject()
    }

    public func getVariableJSON(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> AnyValue? {
        getVariable(featureKey, variableKey, context, options)
    }

    public func getAllEvaluations(_ context: Context = [:]) -> EvaluatedFeatures {
        var result: EvaluatedFeatures = [:]
        for key in datafileReader.getFeatureKeys() {
            let enabled = isEnabled(key, context)
            let variation = getVariation(key, context)
            var variables: [VariableKey: VariableValue] = [:]
            for variableKey in datafileReader.getVariableKeys(key) {
                if let value = getVariable(key, variableKey, context) {
                    variables[variableKey] = value
                }
            }
            result[key] = EvaluatedFeature(enabled: enabled, variation: variation, variables: variables.isEmpty ? nil : variables)
        }
        return result
    }
}

public func createInstance(_ options: InstanceOptions = InstanceOptions()) -> FeaturevisorInstance {
    FeaturevisorInstance(options: options)
}
