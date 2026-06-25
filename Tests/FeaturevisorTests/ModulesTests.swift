import XCTest
@testable import Featurevisor

final class ModulesTests: XCTestCase {
    func testModuleSetupDiagnosticsAddRemoveAndClose() {
        let setupCalled = ConcurrencyBox(false)
        let closeCalled = ConcurrencyBox(false)
        let setupRevision = ConcurrencyBox("")
        let moduleSawDatafileSet = ConcurrencyBox(false)
        let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])

        let module = FeaturevisorModule(
            name: "observer",
            setup: { api in
                setupCalled.value = true
                setupRevision.value = api.getRevision()
                api.onDiagnostic { diagnostic in
                    if diagnostic.code == "datafile_set" {
                        moduleSawDatafileSet.value = true
                    }
                }
                api.reportDiagnostic(FeaturevisorDiagnostic(level: .info, code: "module_ready", message: "Module ready"))
            },
            close: {
                closeCalled.value = true
            }
        )

        let sdk = createInstance(InstanceOptions(
            datafile: TestFixtures.basicDatafile(),
            logLevel: .info,
            onDiagnostic: { diagnostic in
                diagnostics.value.append(diagnostic)
            },
            modules: [module]
        ))

        XCTAssertTrue(setupCalled.value)
        XCTAssertEqual(setupRevision.value, "unknown")
        XCTAssertTrue(moduleSawDatafileSet.value)
        XCTAssertTrue(diagnostics.value.contains { $0.code == "module_ready" && $0.module == "observer" })

        XCTAssertNil(sdk.addModule(FeaturevisorModule(name: "observer")))
        XCTAssertTrue(diagnostics.value.contains { $0.code == "duplicate_module" && $0.level == .error && $0.moduleName == "observer" })

        let removable = FeaturevisorModule(name: "removable")
        XCTAssertNotNil(sdk.addModule(removable))
        sdk.removeModule("removable")

        sdk.close()
        XCTAssertTrue(closeCalled.value)
    }

    func testBeforeAfterAndBucketModules() {
        let bucketKeySeen = ConcurrencyBox("")

        let module = FeaturevisorModule(
            name: "transformer",
            before: { options in
                var updated = options
                updated.dependencies.context["userId"] = .string("from-before")
                return updated
            },
            bucketKey: { options in
                bucketKeySeen.value = options.bucketKey
                return options.bucketKey
            },
            bucketValue: { _ in
                50_000
            },
            after: { evaluation, _ in
                var updated = evaluation
                updated.reason = .forced
                return updated
            }
        )

        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [:],
            features: [
                "exp": Feature(
                    key: "exp",
                    hash: nil,
                    deprecated: nil,
                    required: nil,
                    variablesSchema: nil,
                    disabledVariationValue: nil,
                    variations: nil,
                    bucketBy: .single("userId"),
                    traffic: [Traffic(key: "all", segments: .all, percentage: 100_000, enabled: true, variation: nil, variables: nil, variationWeights: nil, variableOverrides: nil, allocation: nil)],
                    force: nil,
                    ranges: [[0, 10_000]]
                ),
            ]
        )

        let sdk = createInstance(InstanceOptions(datafile: datafile, modules: [module]))
        let evaluation = sdk.evaluateFlag("exp")

        XCTAssertEqual(bucketKeySeen.value, "from-before.exp")
        XCTAssertEqual(evaluation.bucketValue, 50_000)
        XCTAssertEqual(evaluation.reason, .forced)
    }
}
