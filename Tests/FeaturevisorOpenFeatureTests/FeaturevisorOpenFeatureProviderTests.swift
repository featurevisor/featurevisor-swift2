import XCTest
import Combine
import Featurevisor
import FeaturevisorOpenFeature
import OpenFeature

final class FeaturevisorOpenFeatureProviderTests: XCTestCase {
    private final class CloseState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var closed: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
        func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
    }

    private let datafileJSON = #"{"schemaVersion":"2","revision":"openfeature-test","segments":{},"features":{"checkout":{"bucketBy":"userId","variations":[{"value":"on","variables":{"title":"Hello","count":3,"ratio":1.5,"visible":true,"items":["a"],"config":{"color":"blue"},"json":"{\"nested\":true}"}}],"variablesSchema":{"title":{"type":"string","defaultValue":"Default"},"count":{"type":"integer","defaultValue":0},"ratio":{"type":"double","defaultValue":0},"visible":{"type":"boolean","defaultValue":false},"items":{"type":"array","defaultValue":[]},"config":{"type":"object","defaultValue":{}},"json":{"type":"json","defaultValue":"{}"}},"force":[{"conditions":{"attribute":"userId","operator":"equals","value":"forced-user"},"enabled":true,"variation":"on"}],"traffic":[{"key":"all","segments":"*","percentage":100000,"variation":"on"}]}},"variables":{"welcomeMessage":{"type":"string","defaultValue":"Welcome"},"enabled":{"type":"boolean","defaultValue":true}}}"#

    private func provider(
        keySeparator: String = ":",
        variationKey: String = "variation",
        globalVariablePrefix: String = "variable",
        targetingKeyField: String = "userId",
        modules: [FeaturevisorModule] = [],
        onTrack: (@Sendable (String, (any EvaluationContext)?, (any TrackingEventDetails)?) -> Void)? = nil
    ) throws -> FeaturevisorOpenFeatureProvider {
        FeaturevisorOpenFeatureProvider(
            options: FeaturevisorOptions(datafile: try DatafileContent.fromJSON(datafileJSON), logLevel: .fatal, modules: modules),
            targetingKeyField: targetingKeyField,
            keySeparator: keySeparator,
            variationKey: variationKey,
            globalVariablePrefix: globalVariablePrefix,
            onTrack: onTrack
        )
    }

    func testLifecycleStatusAndChangeEvents() throws {
        let provider = try provider()
        defer { provider.close() }
        XCTAssertEqual(provider.status, .notReady)
        let ready = expectation(description: "ready")
        let changes = expectation(description: "sticky configuration changes")
        changes.expectedFulfillmentCount = 2
        let subscription = provider.observe().sink { event in
            if case .ready = event { ready.fulfill() }
            if case .configurationChanged = event { changes.fulfill() }
        }
        _ = provider.initialize(initialContext: nil)
        XCTAssertEqual(provider.status, .ready)
        provider.featurevisor.setStickyFeatures([:])
        provider.featurevisor.setStickyVariables([:])
        wait(for: [ready, changes], timeout: 2)
        subscription.cancel()

        XCTAssertFalse(provider.featurevisor.setDatafile(json: "{"))
        XCTAssertEqual(provider.status, .error)
        _ = provider.onContextSet(oldContext: nil, newContext: ImmutableContext())
        XCTAssertEqual(provider.status, .error)
        XCTAssertTrue(provider.featurevisor.setDatafile(json: datafileJSON, replace: true))
        XCTAssertEqual(provider.status, .ready)
        provider.close()
        XCTAssertFalse(provider.featurevisor.setDatafile(json: "{"))
        XCTAssertEqual(provider.status, .ready)
    }

    func testFeaturevisorContextChangesNotifyWithoutReconciliationLoops() async throws {
        let json = #"{"schemaVersion":"2","revision":"context","segments":{},"features":{},"variables":{"message":{"type":"string","defaultValue":"en","overrides":[{"conditions":{"attribute":"country","operator":"equals","value":"nl"},"value":"nl"}]}}}"#
        for borrowed in [false, true] {
            let options = FeaturevisorOptions(datafile: try DatafileContent.fromJSON(json), logLevel: .fatal)
            let supplied = borrowed ? createFeaturevisor(options) : nil
            let provider = FeaturevisorOpenFeatureProvider(options: options, featurevisor: supplied)
            let f = provider.featurevisor
            await OpenFeatureAPI.shared.setProviderAndWait(provider: provider, initialContext: ImmutableContext())
            let events = Box<[String]>([])
            let contextNotification = expectation(description: "Provider context notification")
            let configurationNotifications = expectation(description: "Provider configuration notifications")
            configurationNotifications.expectedFulfillmentCount = 4
            let subscription = provider.observe().sink { event in
                if case .configurationChanged = event {
                    events.mutate { $0.append("configuration") }
                    configurationNotifications.fulfill()
                }
                if case .contextChanged = event {
                    events.mutate { $0.append("context") }
                    contextNotification.fulfill()
                }
            }
            let client = OpenFeatureAPI.shared.getClient()
            XCTAssertEqual(client.getStringValue(key: "variable:message", defaultValue: "fallback"), "en")
            let notification = expectation(description: "API context notification")
            let apiSubscription = OpenFeatureAPI.shared.observe().sink { event in
                if case .configurationChanged = event { notification.fulfill() }
            }
            f.setContext(["country": .string("nl")])
            await fulfillment(of: [notification], timeout: 2)
            apiSubscription.cancel()
            XCTAssertEqual(client.getStringValue(key: "variable:message", defaultValue: "fallback"), "nl")
            f.setContext([:], replace: true)
            XCTAssertEqual(client.getStringValue(key: "variable:message", defaultValue: "fallback"), "en")
            await OpenFeatureAPI.shared.setEvaluationContextAndWait(evaluationContext: ImmutableContext(attributes: ["country": .string("nl")]))
            await fulfillment(of: [contextNotification], timeout: 2)
            XCTAssertEqual(client.getStringValue(key: "variable:message", defaultValue: "fallback"), "nl")
            XCTAssertEqual(events.value, ["configuration", "configuration", "context"])
            f.setDatafile(json: "{")
            f.setContext(["country": .string("en")])
            XCTAssertEqual(provider.status, .error)
            f.setDatafile(json: json, replace: true)
            XCTAssertEqual(provider.status, .ready)
            await fulfillment(of: [configurationNotifications], timeout: 2)
            provider.close()
            let count = events.value.count
            f.setContext(["country": .string("nl")])
            XCTAssertEqual(events.value.count, count)
            if borrowed { XCTAssertEqual(f.getVariableString("message"), "nl") }
            subscription.cancel()
            supplied?.close()
            await OpenFeatureAPI.shared.clearProviderAndWait()
        }
    }

    func testInvalidInitialRegistrationStaysInErrorUntilDatafileRecovery() async throws {
        let provider = FeaturevisorOpenFeatureProvider(options: FeaturevisorOptions(logLevel: .fatal), datafileJSON: #"{"schemaVersion":"2","revision":"x","features":[],"segments":{}}"#)
        await OpenFeatureAPI.shared.setProviderAndWait(provider: provider, initialContext: ImmutableContext())
        XCTAssertEqual(provider.status, .error)
        provider.featurevisor.setContext(["country": .string("nl")])
        XCTAssertEqual(provider.status, .error)
        provider.featurevisor.setDatafile(json: datafileJSON, replace: true)
        XCTAssertEqual(provider.status, .ready)
        XCTAssertTrue(OpenFeatureAPI.shared.getClient().getBooleanValue(key: "checkout", defaultValue: false))
        await OpenFeatureAPI.shared.clearProviderAndWait()
        provider.close()
    }

    func testResolvesEveryTypeAndMapsTargetingKey() throws {
        let provider = try provider()
        let context = ImmutableContext(targetingKey: "forced-user")
        XCTAssertTrue(try provider.getBooleanEvaluation(key: "checkout", defaultValue: false, context: context).value)
        XCTAssertEqual(try provider.getStringEvaluation(key: "checkout:variation", defaultValue: "fallback", context: context).value, "on")
        XCTAssertEqual(try provider.getStringEvaluation(key: "checkout:title", defaultValue: "fallback", context: context).value, "Hello")
        XCTAssertEqual(try provider.getIntegerEvaluation(key: "checkout:count", defaultValue: 0, context: context).value, 3)
        XCTAssertEqual(try provider.getDoubleEvaluation(key: "checkout:ratio", defaultValue: 0, context: context).value, 1.5)
        XCTAssertTrue(try provider.getBooleanEvaluation(key: "checkout:visible", defaultValue: false, context: context).value)
        XCTAssertEqual(try provider.getObjectEvaluation(key: "checkout:items", defaultValue: .list([]), context: context).value, .list([.string("a")]))
        XCTAssertEqual(try provider.getObjectEvaluation(key: "checkout:config", defaultValue: .structure([:]), context: context).value, .structure(["color": .string("blue")]))
        XCTAssertEqual(try provider.getObjectEvaluation(key: "checkout:json", defaultValue: .structure([:]), context: context).value, .structure(["nested": .boolean(true)]))
        XCTAssertEqual(try provider.getStringEvaluation(key: "variable:welcomeMessage", defaultValue: "fallback", context: context).value, "Welcome")
        XCTAssertTrue(try provider.getBooleanEvaluation(key: "variable:enabled", defaultValue: false, context: context).value)
    }

    func testSupportsCustomGlobalVariablePrefix() throws {
        let custom = try provider(keySeparator: "/", globalVariablePrefix: "$global")
        XCTAssertEqual(
            try custom.getStringEvaluation(key: "$global/welcomeMessage", defaultValue: "fallback", context: nil).value,
            "Welcome"
        )
        XCTAssertEqual(
            try custom.getStringEvaluation(key: "variable/welcomeMessage", defaultValue: "fallback", context: nil).errorCode,
            .flagNotFound
        )
    }

    func testErrorsCustomGrammarTrackingAndClose() throws {
        let tracked = Box<[String]>([])
        let provider = try provider(keySeparator: "/", variationKey: "$variation") { name, _, _ in tracked.mutate { $0.append(name) } }
        XCTAssertEqual(try provider.getStringEvaluation(key: "checkout/$variation", defaultValue: "fallback", context: nil).value, "on")
        XCTAssertEqual(try provider.getStringEvaluation(key: "missing", defaultValue: "fallback", context: nil).errorCode, .typeMismatch)
        let missing = try provider.getBooleanEvaluation(key: "missing", defaultValue: true, context: nil)
        XCTAssertTrue(missing.value)
        XCTAssertEqual(missing.errorCode, .flagNotFound)
        try provider.track(key: "purchase", context: nil, details: nil)
        XCTAssertEqual(tracked.value, ["purchase"])
        provider.close()
    }

    func testWorksThroughOpenFeatureAPI() async throws {
        let tracked = Box<[String]>([])
        let provider = try provider(onTrack: { name, context, _ in
            tracked.set([name, context?.getTargetingKey() ?? ""])
        })
        defer { provider.close() }
        await OpenFeatureAPI.shared.setProviderAndWait(
            provider: provider,
            initialContext: ImmutableContext(targetingKey: "forced-user")
        )
        let client = OpenFeatureAPI.shared.getClient()
        let value = client.getBooleanValue(
            key: "checkout",
            defaultValue: false
        )
        XCTAssertTrue(value)
        XCTAssertEqual(client.getBooleanDetails(key: "checkout", defaultValue: false).reason, "TARGETING_MATCH")
        let missing = client.getStringDetails(key: "variable:missing", defaultValue: "fallback")
        XCTAssertEqual(missing.value, "fallback")
        XCTAssertEqual(missing.reason, "ERROR")
        XCTAssertEqual(missing.errorCode, .flagNotFound)
        client.track(key: "purchase")
        XCTAssertEqual(tracked.value, ["purchase", "forced-user"])
        XCTAssertTrue(provider.featurevisor.setDatafile(json: datafileJSON.replacingOccurrences(of: "Hello", with: "Updated"), replace: true))
        XCTAssertEqual(client.getStringValue(key: "checkout:title", defaultValue: "fallback"), "Updated")
    }

    func testProviderBorrowsExistingFeaturevisor() throws {
        let state = CloseState()
        let featurevisor = createFeaturevisor(FeaturevisorOptions(
            datafile: try DatafileContent.fromJSON(datafileJSON),
            logLevel: .fatal,
            modules: [FeaturevisorModule(name: "owner", close: { state.closed = true })]
        ))
        let provider = FeaturevisorOpenFeatureProvider(featurevisor: featurevisor)

        XCTAssertTrue(provider.featurevisor === featurevisor)
        provider.close()
        XCTAssertFalse(state.closed)

        featurevisor.close()
        XCTAssertTrue(state.closed)
    }

    func testMalformedDatafileReturnsParseErrorAndRecovers() throws {
        let provider = FeaturevisorOpenFeatureProvider(
            options: FeaturevisorOptions(logLevel: .fatal),
            datafileJSON: "{"
        )

        let malformed = try provider.getBooleanEvaluation(key: "checkout", defaultValue: false, context: nil)
        XCTAssertFalse(malformed.value)
        XCTAssertEqual(malformed.reason, Reason.error.rawValue)
        XCTAssertEqual(malformed.errorCode, .parseError)
        XCTAssertEqual(malformed.errorMessage, "Could not parse datafile")

        provider.featurevisor.setDatafile(try DatafileContent.fromJSON(datafileJSON), replace: true)
        let recovered = try provider.getBooleanEvaluation(key: "checkout", defaultValue: false, context: nil)
        XCTAssertTrue(recovered.value)
        XCTAssertNil(recovered.errorCode)
    }

    func testMissingEntitiesTypeMismatchesAndInvalidJSONReturnDefaults() throws {
        var datafile = try DatafileContent.fromJSON(datafileJSON)
        datafile.features["emptyVariation"] = datafile.features["checkout"]
        datafile.features["emptyVariation"]?.variations = []
        datafile.features["checkout"]?.variations?[0].variables?["invalidJson"] = .string("not-json")
        datafile.features["checkout"]?.variablesSchema?["invalidJson"] = try JSONDecoder().decode(
            ResolvedVariableSchema.self,
            from: Data(#"{"key":"invalidJson","type":"json","defaultValue":"{}"}"#.utf8)
        )
        let provider = FeaturevisorOpenFeatureProvider(options: FeaturevisorOptions(datafile: datafile, logLevel: .fatal))

        XCTAssertEqual(try provider.getBooleanEvaluation(key: "missing", defaultValue: true, context: nil).errorCode, .flagNotFound)
        XCTAssertEqual(try provider.getStringEvaluation(key: "checkout:missing", defaultValue: "fallback", context: nil).errorCode, .flagNotFound)
        XCTAssertEqual(try provider.getStringEvaluation(key: "emptyVariation:variation", defaultValue: "fallback", context: nil).errorCode, .flagNotFound)
        XCTAssertEqual(try provider.getStringEvaluation(key: "checkout", defaultValue: "fallback", context: nil).errorCode, .typeMismatch)
        XCTAssertEqual(try provider.getBooleanEvaluation(key: "checkout:title", defaultValue: false, context: nil).errorCode, .typeMismatch)
        XCTAssertEqual(try provider.getObjectEvaluation(key: "checkout:invalidJson", defaultValue: .structure([:]), context: nil).errorCode, .typeMismatch)
    }

    func testNumericResolutionAcceptsIntegersAsDoublesAndRejectsNonFiniteValues() throws {
        let integer = try provider().getDoubleEvaluation(key: "checkout:count", defaultValue: 0, context: nil)
        XCTAssertEqual(integer.value, 3)
        XCTAssertNil(integer.errorCode)

        let nonFiniteModule = FeaturevisorModule(name: "non-finite", afterEvaluation: { evaluation, _ in
            var updated = evaluation
            if updated.variableKey == "ratio" { updated.variableValue = .double(.infinity) }
            return updated
        })
        let nonFinite = try provider(modules: [nonFiniteModule]).getDoubleEvaluation(
            key: "checkout:ratio",
            defaultValue: 7,
            context: nil
        )
        XCTAssertEqual(nonFinite.value, 7)
        XCTAssertEqual(nonFinite.errorCode, .typeMismatch)
    }

    func testMapsAllFeaturevisorReasons() throws {
        let mappings: [(EvaluationReason, String)] = [
            (.forced, Reason.targetingMatch.rawValue),
            (.sticky, Reason.targetingMatch.rawValue),
            (.rule, Reason.targetingMatch.rawValue),
            (.variableOverrideVariation, Reason.targetingMatch.rawValue),
            (.variableOverrideRule, Reason.targetingMatch.rawValue),
            (.allocated, Reason.split.rawValue),
            (.disabled, Reason.disabled.rawValue),
            (.variationDisabled, Reason.disabled.rawValue),
            (.variableDisabled, Reason.disabled.rawValue),
            (.conditionsUnmet, Reason.disabled.rawValue),
            (.variableComposed, Reason.targetingMatch.rawValue),
            (.noMatch, Reason.defaultReason.rawValue),
            (.variableDefault, Reason.defaultReason.rawValue),
        ]

        for (featurevisorReason, openFeatureReason) in mappings {
            let module = FeaturevisorModule(name: "reason", afterEvaluation: { evaluation, _ in
                var updated = evaluation
                updated.reason = featurevisorReason
                return updated
            })
            let result = try provider(modules: [module]).getBooleanEvaluation(key: "checkout", defaultValue: false, context: nil)
            XCTAssertEqual(result.reason, openFeatureReason, "Failed to map \(featurevisorReason.rawValue)")
            XCTAssertNil(result.errorCode)
        }
    }

    func testUnmetPrerequisiteReturnsDisabledReason() throws {
        var datafile = try DatafileContent.fromJSON(datafileJSON)
        datafile.features["checkout"]?.requiredFeatures = [.feature("missing")]
        let provider = FeaturevisorOpenFeatureProvider(options: FeaturevisorOptions(datafile: datafile, logLevel: .fatal))

        let result = try provider.getBooleanEvaluation(key: "checkout", defaultValue: true, context: nil)
        XCTAssertFalse(result.value)
        XCTAssertEqual(result.reason, Reason.disabled.rawValue)
        XCTAssertEqual(result.flagMetadata["featurevisorReason"], .string("conditions_unmet"))
        XCTAssertNil(result.errorCode)
    }

    func testMapsGeneralErrorsAndAllAvailableMetadata() throws {
        let module = FeaturevisorModule(name: "metadata", afterEvaluation: { evaluation, _ in
            var updated = evaluation
            updated.reason = .error
            updated.error = "Evaluation failed"
            updated.variableKey = "title"
            updated.ruleKey = "rule-1"
            updated.bucketKey = "checkout.user-1"
            updated.bucketValue = 0
            updated.forceIndex = 0
            updated.variableOverrideIndex = 0
            return updated
        })
        let result = try provider(modules: [module]).getBooleanEvaluation(key: "checkout", defaultValue: false, context: nil)

        XCTAssertEqual(result.errorCode, .general)
        XCTAssertEqual(result.errorMessage, "Evaluation failed")
        XCTAssertEqual(result.flagMetadata["featureKey"], .string("checkout"))
        XCTAssertEqual(result.flagMetadata["variableKey"], .string("title"))
        XCTAssertEqual(result.flagMetadata["featurevisorReason"], .string("error"))
        XCTAssertEqual(result.flagMetadata["revision"], .string("openfeature-test"))
        XCTAssertEqual(result.flagMetadata["schemaVersion"], .string("2"))
        XCTAssertEqual(result.flagMetadata["ruleKey"], .string("rule-1"))
        XCTAssertEqual(result.flagMetadata["bucketKey"], .string("checkout.user-1"))
        XCTAssertEqual(result.flagMetadata["bucketValue"], .integer(0))
        XCTAssertEqual(result.flagMetadata["forceIndex"], .integer(0))
        XCTAssertEqual(result.flagMetadata["variableOverrideIndex"], .integer(0))
    }

    func testMapsTargetingKeyDatesArraysAndNestedContextWithoutMutation() throws {
        let captured = Box<Context?>(nil)
        let module = FeaturevisorModule(name: "capture", beforeEvaluation: { options in
            captured.set(options.dependencies.context)
            return options
        })
        let date = Date(timeIntervalSince1970: 1_767_326_645)
        let context = ImmutableContext(
            targetingKey: "subject",
            structure: ImmutableStructure(attributes: [
                "createdAt": .date(date),
                "nested": .structure(["items": .list([.date(date)])]),
            ])
        )

        _ = try provider(targetingKeyField: "accountId", modules: [module]).getBooleanEvaluation(
            key: "checkout",
            defaultValue: false,
            context: context
        )

        XCTAssertEqual(captured.value?["accountId"], .string("subject"))
        XCTAssertNotNil(captured.value?["createdAt"]?.asString())
        XCTAssertEqual(context.getValue(key: "createdAt"), .date(date))
        XCTAssertEqual(
            captured.value?["nested"],
            .object(["items": .array([.string(ISO8601DateFormatter().string(from: date))])])
        )
    }

    func testTrackingForwardsContextAndDetailsAndCloseIsIdempotent() throws {
        let events = Box<[(String, String, Double?)]>([])
        let state = CloseState()
        let module = FeaturevisorModule(name: "close", close: { state.closed = true })
        let provider = try provider(modules: [module]) { name, context, details in
            events.mutate { $0.append((name, context?.getTargetingKey() ?? "", details?.getValue())) }
        }
        let context = ImmutableContext(targetingKey: "user-1")
        let details = ImmutableTrackingEventDetails(value: 10, structure: ImmutableStructure(attributes: ["orderId": .string("1")]))

        try provider.track(key: "purchase", context: context, details: details)
        XCTAssertEqual(events.value.first?.0, "purchase")
        XCTAssertEqual(events.value.first?.1, "user-1")
        XCTAssertEqual(events.value.first?.2, 10)

        provider.close()
        provider.close()
        XCTAssertTrue(state.closed)
    }

    func testExistingInstanceTakesPrecedenceOverOptionsAndRawDatafile() throws {
        let featurevisor = createFeaturevisor(FeaturevisorOptions(
            datafile: try DatafileContent.fromJSON(datafileJSON),
            logLevel: .fatal
        ))
        let provider = FeaturevisorOpenFeatureProvider(
            options: FeaturevisorOptions(),
            datafileJSON: "{",
            featurevisor: featurevisor
        )

        let result = try provider.getBooleanEvaluation(key: "checkout", defaultValue: false, context: nil)
        XCTAssertTrue(result.value)
        XCTAssertNil(result.errorCode)
    }
}
