import XCTest
@testable import Featurevisor

final class ChildTests: XCTestCase {
    func testChildContextAndSticky() {
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: TestFixtures.basicDatafile(), context: ["app": .string("ios")]))
        let child = sdk.spawn(["userId": .string("123")])

        XCTAssertEqual(child.getContext()["app"], .string("ios"))
        XCTAssertEqual(child.getContext()["userId"], .string("123"))

        XCTAssertTrue(child.evaluateFlag("test").enabled == true)
        XCTAssertEqual(child.evaluateVariation("test").variation?.value, "control")
        XCTAssertEqual(child.evaluateVariable("test", "color").variableValue, .string("blue"))

        child.setStickyFeatures(["another": EvaluatedFeature(enabled: true)])
        XCTAssertTrue(child.isEnabled("another"))
        XCTAssertEqual(child.evaluateFlag("another").reason, .sticky)
    }

    func testDefaultChildDoesNotInheritParentStickyValues() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"child-sticky","segments":{},"features":{"source":{"bucketBy":"userId","force":[{"segments":"*","enabled":false}],"traffic":[]},"byFeature":{"bucketBy":"userId","requiredFeatures":["source"],"traffic":[{"key":"all","segments":"*","percentage":100000}]},"byGlobal":{"bucketBy":"userId","conditions":[{"variable":"setting","operator":"equals","value":"datafile"}],"traffic":[{"key":"all","segments":"*","percentage":100000}]}},"variables":{"setting":{"type":"string","defaultValue":"datafile"}}}"#)
        let sdk = createFeaturevisor(FeaturevisorOptions(
            datafile: datafile,
            stickyFeatures: ["source": EvaluatedFeature(enabled: true)],
            stickyVariables: ["setting": .string("parent")]
        ))
        let child = sdk.spawn()

        XCTAssertTrue(sdk.isEnabled("source"))
        XCTAssertEqual(sdk.getVariableString("setting"), "parent")
        XCTAssertFalse(child.isEnabled("source"))
        XCTAssertEqual(child.getVariableString("setting"), "datafile")
        XCTAssertTrue(sdk.isEnabled("byFeature"))
        XCTAssertFalse(child.isEnabled("byFeature"))
        XCTAssertFalse(sdk.isEnabled("byGlobal"))
        XCTAssertTrue(child.isEnabled("byGlobal"))
    }

    func testChildDelegatesParentEventsForDatafileSet() {
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))
        let child = sdk.spawn()

        let called = ConcurrencyBox(false)
        let unsub = child.on(.datafileSet) { _ in called.value = true }
        sdk.setDatafile(TestFixtures.basicDatafile())
        unsub()

        XCTAssertTrue(called.value)
    }

    func testChildEventsCarryPayloadsAndCloseDelegatedSubscriptions() {
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))
        let child = sdk.spawn(["country": .string("nl")])
        let contextPayloads = ConcurrencyBox<[EventPayload]>([])
        let stickyPayloads = ConcurrencyBox<[EventPayload]>([])
        let delegatedCalls = ConcurrencyBox(0)

        _ = child.on(.contextSet) { payload in contextPayloads.mutate { $0.append(payload) } }
        _ = child.on(.stickyFeaturesSet) { payload in stickyPayloads.mutate { $0.append(payload) } }
        _ = child.on(.datafileSet) { _ in delegatedCalls.mutate { $0 += 1 } }

        child.setContext(["plan": .string("pro")])
        child.setStickyFeatures(["test": EvaluatedFeature(enabled: true)])

        XCTAssertEqual(contextPayloads.value[0].params["replaced"], .bool(false))
        XCTAssertEqual(
            contextPayloads.value[0].params["context"],
            .object(["country": .string("nl"), "plan": .string("pro")])
        )
        XCTAssertEqual(stickyPayloads.value[0].params["replaced"], .bool(false))
        XCTAssertEqual(stickyPayloads.value[0].params["features"], .array([.string("test")]))

        child.close()
        child.close()
        sdk.setDatafile(TestFixtures.basicDatafile())
        XCTAssertEqual(delegatedCalls.value, 0)
    }

    func testChildContextMatchesJavaScriptSnapshotAndNewParentKeyBehavior() {
        let sdk = createFeaturevisor(FeaturevisorOptions(context: [
            "country": .string("nl"),
            "plan": .string("free"),
        ]))
        let child = sdk.spawn(["country": .string("de")])

        sdk.setContext(["plan": .string("pro"), "locale": .string("de-DE")])

        XCTAssertEqual(child.getContext(), [
            "country": .string("de"),
            "plan": .string("free"),
            "locale": .string("de-DE"),
        ])
    }
}
