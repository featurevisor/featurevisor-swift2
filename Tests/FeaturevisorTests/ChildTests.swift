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
