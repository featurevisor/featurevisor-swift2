import XCTest
@testable import Featurevisor

final class InstanceTests: XCTestCase {
    func testLifecycleAndEvaluations() {
        let sdk = createInstance(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))

        XCTAssertEqual(sdk.getRevision(), "1")
        XCTAssertTrue(sdk.isEnabled("test", ["userId": .string("123")]))
        XCTAssertEqual(sdk.getVariation("test", ["userId": .string("123")]), "control")
        XCTAssertEqual(sdk.getVariableString("test", "color", ["userId": .string("123")]), "blue")
        XCTAssertEqual(sdk.getVariableInteger("test", "count", ["userId": .string("123")]), 2)

        let all = sdk.getAllEvaluations(["userId": .string("123")])
        XCTAssertEqual(all["test"]?.enabled, true)
    }

    func testSetContextAndStickyEvents() {
        let sdk = createInstance(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))

        let contextEvent = ConcurrencyBox(false)
        let stickyEvent = ConcurrencyBox(false)
        let u1 = sdk.on(.contextSet) { payload in
            contextEvent.value = payload.params["replaced"] == .bool(false)
        }
        let u2 = sdk.on(.stickySet) { payload in
            stickyEvent.value = payload.params["features"] == .array([.string("test")])
        }

        sdk.setContext(["country": .string("nl")])
        sdk.setSticky(["test": EvaluatedFeature(enabled: true)])

        u1(); u2()

        XCTAssertTrue(contextEvent.value)
        XCTAssertTrue(stickyEvent.value)
    }

    func testSetDatafileMergesByDefaultAndReplacesWhenRequested() {
        let sdk = createInstance(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))

        let secondDatafile = DatafileContent(
            schemaVersion: "2",
            revision: "2",
            featurevisorVersion: "3.0.0",
            segments: [:],
            features: [
                "second": Feature(
                    key: "second",
                    hash: nil,
                    deprecated: nil,
                    required: nil,
                    variablesSchema: nil,
                    disabledVariationValue: nil,
                    variations: nil,
                    bucketBy: .single("userId"),
                    traffic: [Traffic(key: "all", segments: .all, percentage: 100_000, enabled: true, variation: nil, variables: nil, variationWeights: nil, variableOverrides: nil, allocation: nil)],
                    force: nil,
                    ranges: nil
                ),
            ]
        )

        sdk.setDatafile(secondDatafile)
        XCTAssertNotNil(sdk.getFeature("test"))
        XCTAssertNotNil(sdk.getFeature("second"))
        XCTAssertEqual(sdk.getRevision(), "2")

        sdk.setDatafile(secondDatafile, replace: true)
        XCTAssertNil(sdk.getFeature("test"))
        XCTAssertNotNil(sdk.getFeature("second"))
    }

    func testDatafileSetEventIncludesReplaced() {
        let sdk = createInstance(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))
        let replaced = ConcurrencyBox<AnyValue?>(nil)

        let unsubscribe = sdk.on(.datafileSet) { payload in
            replaced.value = payload.params["replaced"]
        }

        var next = TestFixtures.basicDatafile()
        next.revision = "2"
        sdk.setDatafile(next, replace: true)
        unsubscribe()

        XCTAssertEqual(replaced.value, .bool(true))
    }
}
