import Foundation

public struct EvaluateInput: Sendable {
    public var type: EvaluationType
    public var featureKey: FeatureKey
    public var variableKey: VariableKey?
    public var context: Context

    public init(type: EvaluationType, featureKey: FeatureKey, variableKey: VariableKey? = nil, context: Context) {
        self.type = type
        self.featureKey = featureKey
        self.variableKey = variableKey
        self.context = context
    }
}

public struct BucketContext: Sendable {
    public var bucketKey: String
    public var bucketValue: Int
}

public struct Hook: Sendable {
    public var name: String
    public var before: (@Sendable (EvaluateInput) -> EvaluateInput)?
    public var after: (@Sendable (Evaluation, EvaluateInput) -> Evaluation)?
    public var bucketKey: (@Sendable (String) -> String)?
    public var bucketValue: (@Sendable (Int) -> Int)?

    public init(
        name: String,
        before: (@Sendable (EvaluateInput) -> EvaluateInput)? = nil,
        after: (@Sendable (Evaluation, EvaluateInput) -> Evaluation)? = nil,
        bucketKey: (@Sendable (String) -> String)? = nil,
        bucketValue: (@Sendable (Int) -> Int)? = nil
    ) {
        self.name = name
        self.before = before
        self.after = after
        self.bucketKey = bucketKey
        self.bucketValue = bucketValue
    }
}

public final class HooksManager: @unchecked Sendable {
    private var hooks: [Hook]
    private let logger: Logger

    public init(hooks: [Hook], logger: Logger) {
        self.hooks = hooks
        self.logger = logger
    }

    @discardableResult
    public func add(_ hook: Hook) -> () -> Void {
        hooks.append(hook)
        return { [weak self] in
            self?.hooks.removeAll(where: { $0.name == hook.name })
        }
    }

    public func getAll() -> [Hook] {
        hooks
    }

    public func runBefore(_ input: EvaluateInput) -> EvaluateInput {
        hooks.reduce(input) { partial, hook in
            if let before = hook.before { return before(partial) }
            return partial
        }
    }

    public func runAfter(_ evaluation: Evaluation, input: EvaluateInput) -> Evaluation {
        hooks.reduce(evaluation) { partial, hook in
            if let after = hook.after { return after(partial, input) }
            return partial
        }
    }

    public func transformBucketKey(_ key: String) -> String {
        hooks.reduce(key) { partial, hook in
            if let transform = hook.bucketKey { return transform(partial) }
            return partial
        }
    }

    public func transformBucketValue(_ value: Int) -> Int {
        hooks.reduce(value) { partial, hook in
            if let transform = hook.bucketValue { return transform(partial) }
            return partial
        }
    }
}
