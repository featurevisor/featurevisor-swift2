import Foundation

public final class FeaturevisorChildInstance: @unchecked Sendable {
    private let lock = FeaturevisorLock()
    private let parent: Featurevisor
    private var context: Context
    private var stickyFeatures: StickyFeatures?
    private var stickyVariables: StickyVariables?
    private let emitter = Emitter()
    private var parentUnsubscribers: [(UUID, FeaturevisorUnsubscribe)] = []

    init(parent: Featurevisor, context: Context, stickyFeatures: StickyFeatures?, stickyVariables: StickyVariables?) {
        self.parent = parent
        self.context = context
        self.stickyFeatures = stickyFeatures
        self.stickyVariables = stickyVariables
    }

    public func getContext(_ context: Context? = nil) -> Context {
        let childContext = lock.withLock {
            self.context.merging(context ?? [:], uniquingKeysWith: { _, new in new })
        }
        return parent.getContext(childContext)
    }

    public func setContext(_ context: Context, replace: Bool = false) {
        let updatedContext = lock.withLock {
            self.context = replace ? context : self.context.merging(context, uniquingKeysWith: { _, new in new })
            return self.context
        }
        emitter.trigger(.contextSet, payload: EventPayload([
            "context": .object(updatedContext),
            "replaced": .bool(replace),
        ]))
    }

    public func setStickyFeatures(_ sticky: StickyFeatures, replace: Bool = false) {
        let values = lock.withLock { () -> (StickyFeatures, StickyFeatures) in
            let previous = self.stickyFeatures ?? [:]
            self.stickyFeatures = replace ? sticky : (self.stickyFeatures ?? [:]).merging(sticky, uniquingKeysWith: { _, new in new })
            return (previous, self.stickyFeatures ?? [:])
        }
        emitter.trigger(
            .stickyFeaturesSet,
            payload: EventPayload(
                getParamsForStickySetEvent(
                    previousStickyFeatures: values.0,
                    newStickyFeatures: values.1,
                    replace: replace
                )
            )
        )
    }

    public func setStickyVariables(_ sticky: StickyVariables, replace: Bool = false) {
        let values = lock.withLock { () -> (StickyVariables, StickyVariables) in
            let previous = stickyVariables ?? [:]
            stickyVariables = replace ? sticky : previous.merging(sticky, uniquingKeysWith: { _, new in new })
            return (previous, stickyVariables ?? [:])
        }
        emitter.trigger(.stickyVariablesSet, payload: EventPayload(getParamsForStickyVariablesSetEvent(previousStickyVariables: values.0, newStickyVariables: values.1, replace: replace)))
    }

    @discardableResult
    public func on(_ eventName: EventName, callback: @escaping EventCallback) -> () -> Void {
        if eventName == .contextSet || eventName == .stickyFeaturesSet || eventName == .stickyVariablesSet {
            return emitter.on(eventName, callback: callback)
        }
        let parentUnsubscribe = parent.on(eventName, callback: callback)
        let token = UUID()
        var active = true
        let unsubscribe: FeaturevisorUnsubscribe = { [weak self] in
            guard active else { return }
            active = false
            parentUnsubscribe()
            self?.lock.withLock {
                self?.parentUnsubscribers.removeAll { $0.0 == token }
            }
        }
        lock.withLock { parentUnsubscribers.append((token, unsubscribe)) }
        return unsubscribe
    }

    public func close() {
        let unsubscribers = lock.withLock { () -> [FeaturevisorUnsubscribe] in
            let current = parentUnsubscribers.map(\.1)
            parentUnsubscribers = []
            return current
        }
        unsubscribers.forEach { $0() }
        emitter.clearAll()
    }

    private func merge(_ options: OverrideOptions) -> OverrideOptions {
        var merged = OverrideOptions(
            defaultVariationValue: options.defaultVariationValue,
            defaultVariableValue: options.defaultVariableValue
        )
        let values = lock.withLock { (stickyFeatures, stickyVariables) }
        merged.stickyFeatures = values.0
        merged.stickyVariables = values.1
        return merged
    }

    public func evaluateFlag(_ featureKey: FeatureKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        parent.evaluateFlag(featureKey, context: getContext(context), options: merge(options))
    }

    public func isEnabled(_ featureKey: FeatureKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Bool {
        parent.isEnabled(featureKey, getContext(context), merge(options))
    }

    public func evaluateVariation(_ featureKey: FeatureKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        parent.evaluateVariation(featureKey, context: getContext(context), options: merge(options))
    }

    public func getVariation(_ featureKey: FeatureKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> VariationValue? {
        parent.getVariation(featureKey, getContext(context), merge(options))
    }

    public func evaluateVariable(_ featureKey: FeatureKey, _ variableKey: VariableKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation {
        parent.evaluateVariable(featureKey, variableKey, context: getContext(context), options: merge(options))
    }

    public func getVariable(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> VariableValue? {
        parent.getVariable(featureKey, variableKey, getContext(context), merge(options))
    }

    public func evaluateVariable(_ variableKey: VariableKey, context: Context = [:], options: OverrideOptions = OverrideOptions()) -> Evaluation { parent.evaluateVariable(variableKey, context: getContext(context), options: merge(options)) }
    public func getVariable(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> VariableValue? { parent.getVariable(variableKey, getContext(context), merge(options)) }
    public func getVariableBoolean(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Bool? { parent.getVariableBoolean(variableKey, getContext(context), merge(options)) }
    public func getVariableString(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> String? { parent.getVariableString(variableKey, getContext(context), merge(options)) }
    public func getVariableInteger(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Int? { parent.getVariableInteger(variableKey, getContext(context), merge(options)) }
    public func getVariableDouble(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Double? { parent.getVariableDouble(variableKey, getContext(context), merge(options)) }
    public func getVariableArray(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [AnyValue]? { parent.getVariableArray(variableKey, getContext(context), merge(options)) }
    public func getVariableObject(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [String: AnyValue]? { parent.getVariableObject(variableKey, getContext(context), merge(options)) }
    public func getVariableJSON(_ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> AnyValue? { parent.getVariableJSON(variableKey, getContext(context), merge(options)) }

    public func getVariableBoolean(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Bool? {
        parent.getVariableBoolean(featureKey, variableKey, getContext(context), merge(options))
    }

    public func getVariableString(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> String? {
        parent.getVariableString(featureKey, variableKey, getContext(context), merge(options))
    }

    public func getVariableInteger(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Int? {
        parent.getVariableInteger(featureKey, variableKey, getContext(context), merge(options))
    }

    public func getVariableDouble(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> Double? {
        parent.getVariableDouble(featureKey, variableKey, getContext(context), merge(options))
    }

    public func getVariableArray(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [AnyValue]? {
        parent.getVariableArray(featureKey, variableKey, getContext(context), merge(options))
    }

    public func getVariableObject(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> [String: AnyValue]? {
        parent.getVariableObject(featureKey, variableKey, getContext(context), merge(options))
    }

    public func getVariableJSON(_ featureKey: FeatureKey, _ variableKey: VariableKey, _ context: Context = [:], _ options: OverrideOptions = OverrideOptions()) -> AnyValue? {
        parent.getVariableJSON(featureKey, variableKey, getContext(context), merge(options))
    }

    public func getFeatureEvaluations(_ context: Context = [:], _ featureKeys: [FeatureKey] = [], _ options: OverrideOptions = OverrideOptions()) -> EvaluatedFeatures {
        parent.getFeatureEvaluations(getContext(context), featureKeys, merge(options))
    }

    public func getVariableEvaluations(_ context: Context = [:], _ variableKeys: [VariableKey] = [], _ options: OverrideOptions = OverrideOptions()) -> EvaluatedVariables { parent.getVariableEvaluations(getContext(context), variableKeys, merge(options)) }
}
