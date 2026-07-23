import Foundation

public final class FeaturevisorChildInstance: @unchecked Sendable {
    private let lock = FeaturevisorLock()
    private let parent: Featurevisor
    private var context: Context
    private var sticky: StickyFeatures?
    private let emitter = Emitter()
    private var parentUnsubscribers: [(UUID, FeaturevisorUnsubscribe)] = []

    init(parent: Featurevisor, context: Context, sticky: StickyFeatures?) {
        self.parent = parent
        self.context = context
        self.sticky = sticky
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

    public func setSticky(_ sticky: StickyFeatures, replace: Bool = false) {
        let values = lock.withLock { () -> (StickyFeatures, StickyFeatures) in
            let previous = self.sticky ?? [:]
            self.sticky = replace ? sticky : (self.sticky ?? [:]).merging(sticky, uniquingKeysWith: { _, new in new })
            return (previous, self.sticky ?? [:])
        }
        emitter.trigger(
            .stickySet,
            payload: EventPayload(
                getParamsForStickySetEvent(
                    previousStickyFeatures: values.0,
                    newStickyFeatures: values.1,
                    replace: replace
                )
            )
        )
    }

    @discardableResult
    public func on(_ eventName: EventName, callback: @escaping EventCallback) -> () -> Void {
        if eventName == .contextSet || eventName == .stickySet {
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
        merged.sticky = lock.withLock { sticky }
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

    public func getAllEvaluations(_ context: Context = [:], _ featureKeys: [FeatureKey] = [], _ options: OverrideOptions = OverrideOptions()) -> EvaluatedFeatures {
        parent.getAllEvaluations(getContext(context), featureKeys, merge(options))
    }
}
