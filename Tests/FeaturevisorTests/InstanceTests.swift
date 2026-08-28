import XCTest
import Dispatch
@testable import Featurevisor

final class InstanceTests: XCTestCase {
    func testLifecycleAndEvaluations() {
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))

        XCTAssertEqual(sdk.getRevision(), "1")
        XCTAssertEqual(sdk.getSchemaVersion(), "2")
        XCTAssertEqual(sdk.getFeatureKeys(), ["test"])
        XCTAssertTrue(sdk.hasVariations("test"))
        XCTAssertEqual(Set(sdk.getVariableKeys("test")), Set(["color", "count"]))
        XCTAssertTrue(sdk.isEnabled("test", ["userId": .string("123")]))
        XCTAssertEqual(sdk.getVariation("test", ["userId": .string("123")]), "control")
        XCTAssertEqual(sdk.getVariableString("test", "color", ["userId": .string("123")]), "blue")
        XCTAssertEqual(sdk.getVariableInteger("test", "count", ["userId": .string("123")]), 2)

        let all = sdk.getFeatureEvaluations(["userId": .string("123")])
        XCTAssertEqual(all["test"]?.enabled, true)
    }

    func testSetContextAndStickyEvents() {
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))

        let contextEvent = ConcurrencyBox(false)
        let stickyEvent = ConcurrencyBox(false)
        let u1 = sdk.on(.contextSet) { payload in
            contextEvent.value = payload.params["replaced"] == .bool(false)
        }
        let u2 = sdk.on(.stickyFeaturesSet) { payload in
            stickyEvent.value = payload.params["features"] == .array([.string("test")])
        }

        sdk.setContext(["country": .string("nl")])
        sdk.setStickyFeatures(["test": EvaluatedFeature(enabled: true)])

        u1(); u2()

        XCTAssertTrue(contextEvent.value)
        XCTAssertTrue(stickyEvent.value)
    }

    func testLifecycleMutationsReportDiagnostics() {
        let diagnostics = ConcurrencyBox<[String]>([])
        let sdk = createFeaturevisor(FeaturevisorOptions(
            logLevel: .debug,
            onDiagnostic: { diagnostic in
                diagnostics.mutate { $0.append(diagnostic.code) }
            }
        ))

        sdk.setDatafile(TestFixtures.basicDatafile())
        sdk.setStickyFeatures(["test": EvaluatedFeature(enabled: true)])
        sdk.setContext(["country": .string("nl")])

        XCTAssertTrue(diagnostics.value.contains("datafile_set"))
        XCTAssertTrue(diagnostics.value.contains("sticky_features_set"))
        XCTAssertTrue(diagnostics.value.contains("context_set"))
    }

    func testEvaluationWarningsUseDiagnostics() {
        var datafile = TestFixtures.basicDatafile()
        datafile.features["test"]?.deprecated = true
        let diagnostics = ConcurrencyBox<[String]>([])
        let sdk = createFeaturevisor(FeaturevisorOptions(
            datafile: datafile,
            onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic.code) } }
        ))

        _ = sdk.isEnabled("test", ["userId": .string("123")])

        XCTAssertTrue(diagnostics.value.contains("deprecated_feature"))
    }

    func testSetDatafileMergesByDefaultAndReplacesWhenRequested() {
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))

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
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: TestFixtures.basicDatafile()))
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

    func testConcurrentEvaluationAndStateUpdatesAreSafe() {
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: TestFixtures.basicDatafile(), logLevel: .fatal))
        let failures = ConcurrencyBox<[String]>([])

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            if index.isMultiple(of: 10) {
                sdk.setContext(["iteration": .int(index)])
                sdk.setStickyFeatures(["test": EvaluatedFeature(enabled: true)])
                var datafile = TestFixtures.basicDatafile()
                datafile.revision = "\(index)"
                sdk.setDatafile(datafile, replace: true)
            } else {
                if !sdk.isEnabled("test", ["userId": .string("user-\(index)")]) {
                    failures.mutate { $0.append("flag") }
                }
                if sdk.getVariableInteger("test", "count", ["userId": .string("user-\(index)")]) != 2 {
                    failures.mutate { $0.append("variable") }
                }
            }
        }

        XCTAssertTrue(failures.value.isEmpty)
    }

    func testConcurrentEventSubscriptionAndDeliveryAreSafe() {
        let sdk = createFeaturevisor(FeaturevisorOptions(logLevel: .fatal))
        let delivered = ConcurrencyBox(0)

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            let unsubscribe = sdk.on(.contextSet) { _ in delivered.mutate { $0 += 1 } }
            sdk.setContext(["iteration": .int(index)])
            unsubscribe()
        }

        XCTAssertGreaterThan(delivered.value, 0)
        sdk.close()
    }
}
