import Combine
import Foundation
import Featurevisor
import OpenFeature

public struct FeaturevisorOpenFeatureMetadata: ProviderMetadata {
    public let name: String? = "Featurevisor"
    public init() {}
}

public final class FeaturevisorOpenFeatureProvider: FeatureProvider, @unchecked Sendable {
    public let hooks: [any Hook] = []
    public let metadata: ProviderMetadata = FeaturevisorOpenFeatureMetadata()
    public let featurevisor: Featurevisor

    private let targetingKeyField: String
    private let keySeparator: String
    private let variationKey: String
    private let onTrack: (@Sendable (String, (any EvaluationContext)?, (any TrackingEventDetails)?) -> Void)?
    private let ownsFeaturevisor: Bool
    private let eventHandler = EventHandler()
    private let lock = NSLock()
    private var parseErrorMessage: String?
    private var errorUnsubscribe: FeaturevisorUnsubscribe?
    private var datafileUnsubscribe: FeaturevisorUnsubscribe?
    private var closed = false

    public init(
        options: FeaturevisorOptions = FeaturevisorOptions(),
        datafileJSON: String? = nil,
        featurevisor: Featurevisor? = nil,
        targetingKeyField: String = "userId",
        keySeparator: String = ":",
        variationKey: String = "variation",
        onTrack: (@Sendable (String, (any EvaluationContext)?, (any TrackingEventDetails)?) -> Void)? = nil
    ) {
        self.ownsFeaturevisor = featurevisor == nil
        var creationOptions = options
        if featurevisor == nil, datafileJSON != nil { creationOptions.datafile = nil }
        self.featurevisor = featurevisor ?? createFeaturevisor(creationOptions)
        self.targetingKeyField = targetingKeyField.isEmpty ? "userId" : targetingKeyField
        self.keySeparator = keySeparator.isEmpty ? ":" : keySeparator
        self.variationKey = variationKey.isEmpty ? "variation" : variationKey
        self.onTrack = onTrack

        self.errorUnsubscribe = self.featurevisor.on(.error) { [weak self] payload in
            guard
                case .object(let diagnostic)? = payload.params["diagnostic"],
                diagnostic["code"] == .string("invalid_datafile")
            else { return }
            let message = diagnostic["message"]?.asString() ?? "Could not parse datafile"
            guard let self else { return }
            self.withLock { self.parseErrorMessage = message }
        }
        self.datafileUnsubscribe = self.featurevisor.on(.datafileSet) { [weak self] _ in
            guard let self else { return }
            self.withLock { self.parseErrorMessage = nil }
        }

        if featurevisor == nil, let datafileJSON {
            self.featurevisor.setDatafile(json: datafileJSON, replace: true)
        }
    }

    public func initialize(initialContext: (any EvaluationContext)?) async throws {}
    public func onContextSet(oldContext: (any EvaluationContext)?, newContext: any EvaluationContext) async throws {}
    public func observe() -> AnyPublisher<ProviderEvent?, Never> { eventHandler.observe() }

    public func track(key: String, context: (any EvaluationContext)?, details: (any TrackingEventDetails)?) throws {
        onTrack?(key, context, details)
    }

    public func close() {
        let shouldClose = withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        errorUnsubscribe?()
        datafileUnsubscribe?()
        errorUnsubscribe = nil
        datafileUnsubscribe = nil
        if ownsFeaturevisor { featurevisor.close() }
    }

    public func getBooleanEvaluation(key: String, defaultValue: Bool, context: (any EvaluationContext)?) throws -> ProviderEvaluation<Bool> {
        typed(resolve(key: key, defaultValue: AnyValue.bool(defaultValue), context: context, expected: .boolean), fallback: defaultValue) { $0.asBool() }
    }

    public func getStringEvaluation(key: String, defaultValue: String, context: (any EvaluationContext)?) throws -> ProviderEvaluation<String> {
        typed(resolve(key: key, defaultValue: AnyValue.string(defaultValue), context: context, expected: .string), fallback: defaultValue) { $0.asString() }
    }

    public func getIntegerEvaluation(key: String, defaultValue: Int64, context: (any EvaluationContext)?) throws -> ProviderEvaluation<Int64> {
        typed(resolve(key: key, defaultValue: AnyValue.int(Int(defaultValue)), context: context, expected: .integer), fallback: defaultValue) { value in
            guard case .int(let int) = value else { return nil }
            return Int64(int)
        }
    }

    public func getDoubleEvaluation(key: String, defaultValue: Double, context: (any EvaluationContext)?) throws -> ProviderEvaluation<Double> {
        typed(resolve(key: key, defaultValue: AnyValue.double(defaultValue), context: context, expected: .number), fallback: defaultValue) { $0.asDouble() }
    }

    public func getObjectEvaluation(key: String, defaultValue: Value, context: (any EvaluationContext)?) throws -> ProviderEvaluation<Value> {
        let fallback = anyValue(defaultValue)
        return typed(resolve(key: key, defaultValue: fallback, context: context, expected: .object), fallback: defaultValue) { openFeatureValue($0) }
    }

    private enum ExpectedType { case boolean, string, integer, number, object }

    private func resolve(key: String, defaultValue: AnyValue, context: (any EvaluationContext)?, expected: ExpectedType) -> ProviderEvaluation<AnyValue> {
        if let message = withLock({ parseErrorMessage }) {
            return ProviderEvaluation(
                value: defaultValue,
                reason: Reason.error.rawValue,
                errorCode: .parseError,
                errorMessage: message
            )
        }
        let parts = splitKey(key)
        let fvContext = featurevisorContext(context)
        let evaluation: Evaluation
        var value: AnyValue?

        if parts.selector == nil || parts.selector?.isEmpty == true {
            guard expected == .boolean else { return typeMismatch(key, defaultValue, expected) }
            evaluation = featurevisor.evaluateFlag(parts.feature, context: fvContext)
            if let enabled = evaluation.enabled { value = .bool(enabled) }
        } else if parts.selector == variationKey {
            evaluation = featurevisor.evaluateVariation(parts.feature, context: fvContext)
            if let variation = evaluation.variationValue ?? evaluation.variation?.value { value = .string(variation) }
        } else {
            evaluation = featurevisor.evaluateVariable(parts.feature, parts.selector!, context: fvContext)
            value = evaluation.variableValue
            if evaluation.variableSchema?.type == "json", case .string(let json)? = value,
               let data = json.data(using: .utf8), let parsed = try? JSONDecoder().decode(AnyValue.self, from: data) {
                value = parsed
            }
        }

        let metadata = metadata(evaluation)
        if let code = errorCode(evaluation.reason) {
            return ProviderEvaluation(value: defaultValue, flagMetadata: metadata, reason: Reason.error.rawValue, errorCode: code, errorMessage: errorMessage(evaluation))
        }
        guard let resolved = value else {
            return ProviderEvaluation(value: defaultValue, flagMetadata: metadata, variant: variant(evaluation), reason: reason(evaluation.reason))
        }
        guard matches(resolved, expected) else { return typeMismatch(key, defaultValue, expected, metadata: metadata) }
        return ProviderEvaluation(value: resolved, flagMetadata: metadata, variant: variant(evaluation), reason: reason(evaluation.reason))
    }

    private func splitKey(_ key: String) -> (feature: String, selector: String?) {
        guard let range = key.range(of: keySeparator) else { return (key, nil) }
        return (String(key[..<range.lowerBound]), String(key[range.upperBound...]))
    }

    private func featurevisorContext(_ context: (any EvaluationContext)?) -> Context {
        guard let context else { return [:] }
        var result = context.asMap().mapValues(anyValue)
        let targetingKey = context.getTargetingKey()
        if !targetingKey.isEmpty { result[targetingKeyField] = .string(targetingKey) }
        return result
    }

    private func anyValue(_ value: Value) -> AnyValue {
        switch value {
        case .boolean(let value): return .bool(value)
        case .string(let value): return .string(value)
        case .integer(let value): return .int(Int(value))
        case .double(let value): return .double(value)
        case .date(let value): return .string(ISO8601DateFormatter().string(from: value))
        case .list(let values): return .array(values.map(anyValue))
        case .structure(let values): return .object(values.mapValues(anyValue))
        case .null: return .null
        }
    }

    private func openFeatureValue(_ value: AnyValue) -> Value? {
        switch value {
        case .bool(let value): return .boolean(value)
        case .string(let value): return .string(value)
        case .int(let value): return .integer(Int64(value))
        case .double(let value): return .double(value)
        case .array(let values): return .list(values.compactMap(openFeatureValue))
        case .object(let values): return .structure(values.compactMapValues(openFeatureValue))
        case .null: return .null
        }
    }

    private func metadata(_ evaluation: Evaluation) -> FlagMetadata {
        var metadata: FlagMetadata = [
            "featureKey": .string(evaluation.featureKey),
            "featurevisorReason": .string(evaluation.reason.rawValue),
            "schemaVersion": .string(featurevisor.getSchemaVersion()),
        ]
        let revision = featurevisor.getRevision()
        if !revision.isEmpty { metadata["revision"] = .string(revision) }
        if let value = evaluation.variableKey { metadata["variableKey"] = .string(value) }
        if let value = evaluation.ruleKey { metadata["ruleKey"] = .string(value) }
        if let value = evaluation.bucketKey { metadata["bucketKey"] = .string(value) }
        if let value = evaluation.bucketValue { metadata["bucketValue"] = .integer(Int64(value)) }
        if let value = evaluation.forceIndex { metadata["forceIndex"] = .integer(Int64(value)) }
        if let value = evaluation.variableOverrideIndex { metadata["variableOverrideIndex"] = .integer(Int64(value)) }
        return metadata
    }

    private func reason(_ value: EvaluationReason) -> String {
        switch value {
        case .featureNotFound, .variableNotFound, .noVariations, .error: return Reason.error.rawValue
        case .required, .forced, .sticky, .rule, .variableOverrideVariation, .variableOverrideRule: return Reason.targetingMatch.rawValue
        case .allocated: return Reason.split.rawValue
        case .disabled, .variationDisabled, .variableDisabled: return Reason.disabled.rawValue
        default: return Reason.defaultReason.rawValue
        }
    }

    private func errorCode(_ value: EvaluationReason) -> ErrorCode? {
        switch value {
        case .featureNotFound, .variableNotFound, .noVariations: return .flagNotFound
        case .error: return .general
        default: return nil
        }
    }

    private func errorMessage(_ evaluation: Evaluation) -> String {
        if let error = evaluation.error { return error }
        switch evaluation.reason {
        case .featureNotFound: return "Feature \"\(evaluation.featureKey)\" was not found"
        case .variableNotFound: return "Variable \"\(evaluation.variableKey ?? "")\" was not found for feature \"\(evaluation.featureKey)\""
        case .noVariations: return "Feature \"\(evaluation.featureKey)\" has no variations"
        default: return "Featurevisor evaluation failed"
        }
    }

    private func variant(_ evaluation: Evaluation) -> String? { evaluation.variationValue ?? evaluation.variation?.value }

    private func matches(_ value: AnyValue, _ expected: ExpectedType) -> Bool {
        switch (value, expected) {
        case (.bool, .boolean), (.string, .string), (.int, .integer), (.int, .number), (.array, .object), (.object, .object): return true
        case (.double(let value), .number): return value.isFinite
        default: return false
        }
    }

    private func typeMismatch(_ key: String, _ value: AnyValue, _ expected: ExpectedType, metadata: FlagMetadata = [:]) -> ProviderEvaluation<AnyValue> {
        ProviderEvaluation(value: value, flagMetadata: metadata, reason: Reason.error.rawValue, errorCode: .typeMismatch, errorMessage: "Flag \"\(key)\" did not resolve to a \(expected) value")
    }

    private func typed<T>(_ source: ProviderEvaluation<AnyValue>, fallback: T, convert: (AnyValue) -> T?) -> ProviderEvaluation<T> {
        ProviderEvaluation(value: convert(source.value) ?? fallback, flagMetadata: source.flagMetadata, variant: source.variant, reason: source.reason, errorCode: source.errorCode, errorMessage: source.errorMessage)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
