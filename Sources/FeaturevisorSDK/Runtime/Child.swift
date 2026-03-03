import Foundation

public final class FeaturevisorChildInstance: @unchecked Sendable {
    private let parent: FeaturevisorInstance
    private var context: Context
    private var sticky: StickyFeatures?
    private let emitter = Emitter()

    init(parent: FeaturevisorInstance, context: Context, sticky: StickyFeatures?) {
        self.parent = parent
        self.context = context
        self.sticky = sticky
    }

    public func getContext(_ context: Context? = nil) -> Context {
        guard let context else { return self.context }
        return self.context.merging(context, uniquingKeysWith: { _, new in new })
    }

    public func setContext(_ context: Context, replace: Bool = false) {
        if replace {
            self.context = context
        } else {
            self.context = self.context.merging(context, uniquingKeysWith: { _, new in new })
        }
        emitter.trigger(.contextSet)
    }

    public func setSticky(_ sticky: StickyFeatures, replace: Bool = false) {
        if replace {
            self.sticky = sticky
        } else {
            self.sticky = (self.sticky ?? [:]).merging(sticky, uniquingKeysWith: { _, new in new })
        }
        emitter.trigger(.stickySet)
    }

    @discardableResult
    public func on(_ eventName: EventName, callback: @escaping EventCallback) -> () -> Void {
        emitter.on(eventName, callback: callback)
    }

    private func merge(_ options: OverrideOptions) -> OverrideOptions {
        OverrideOptions(
            sticky: options.sticky == nil ? sticky : (sticky ?? [:]).merging(options.sticky ?? [:], uniquingKeysWith: { _, new in new }),
            defaultVariationValue: options.defaultVariationValue,
            defaultVariableValue: options.defaultVariableValue
        )
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
}
