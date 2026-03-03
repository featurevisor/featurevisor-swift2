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
        let newDatafileReader = DatafileReader(datafile: datafile, logger: logger)
        let details = getParamsForDatafileSetEvent(previousDatafileReader: datafileReader, newDatafileReader: newDatafileReader)
        self.datafileReader = newDatafileReader
        emitter.trigger(.datafileSet, payload: EventPayload(details))
    }

    public func setDatafile(json: String) {
        do {
            setDatafile(try DatafileContent.fromJSON(json))
        } catch {
            logger.error("could not parse datafile", details: ["error": error.localizedDescription])
        }
    }

    public func setSticky(_ sticky: StickyFeatures, replace: Bool = false) {
        let previousSticky = self.sticky ?? [:]
        if replace {
            self.sticky = sticky
        } else {
            self.sticky = (self.sticky ?? [:]).merging(sticky, uniquingKeysWith: { _, new in new })
        }
        let payload = getParamsForStickySetEvent(previousStickyFeatures: previousSticky, newStickyFeatures: self.sticky ?? [:], replace: replace)
        emitter.trigger(.stickySet, payload: EventPayload(payload))
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
        emitter.trigger(.contextSet, payload: EventPayload([
            "context": (try? JSONSerialization.string(from: self.context)) ?? "{}",
            "replaced": replace ? "true" : "false",
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

private extension JSONSerialization {
    static func string(from context: Context) throws -> String {
        let obj = context.mapValues { $0.rawValue }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        return String(decoding: data, as: UTF8.self)
    }
}

public func createInstance(_ options: InstanceOptions = InstanceOptions()) -> FeaturevisorInstance {
    FeaturevisorInstance(options: options)
}
