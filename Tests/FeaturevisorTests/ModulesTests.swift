import XCTest
@testable import Featurevisor

final class ModulesTests: XCTestCase {
    enum TestModuleError: Error {
        case closeFailed
    }

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

    func testRemovedModulesAreClosed() {
        let closed = ConcurrencyBox<[String]>([])
        let sdk = createInstance(InstanceOptions(logLevel: .fatal))

        let unsubscribe = sdk.addModule(FeaturevisorModule(
            name: "dynamic",
            close: {
                closed.value.append("dynamic")
            }
        ))

        XCTAssertNotNil(unsubscribe)
        unsubscribe?()
        unsubscribe?()

        _ = sdk.addModule(FeaturevisorModule(
            name: "dynamic",
            close: {
                closed.value.append("dynamic-again")
            }
        ))
        sdk.removeModule("dynamic")

        XCTAssertEqual(closed.value, ["dynamic", "dynamic-again"])
    }

    func testModuleCloseErrorsAreReportedAndDoNotStopCleanup() {
        let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
        let errorEventCodes = ConcurrencyBox<[String]>([])
        let closed = ConcurrencyBox<[String]>([])

        let sdk = createInstance(InstanceOptions(
            logLevel: .info,
            onDiagnostic: { diagnostic in
                diagnostics.value.append(diagnostic)
            }
        ))

        sdk.on(.error) { payload in
            if case .string(let code)? = payload.params["code"] {
                errorEventCodes.value.append(code)
            }
        }

        _ = sdk.addModule(FeaturevisorModule(
            name: "first",
            close: {
                closed.value.append("first")
                throw TestModuleError.closeFailed
            }
        ))
        _ = sdk.addModule(FeaturevisorModule(
            name: "second",
            close: {
                closed.value.append("second")
            }
        ))

        sdk.close()

        XCTAssertEqual(closed.value, ["first", "second"])
        XCTAssertTrue(diagnostics.value.contains {
            $0.code == "module_close_error" &&
                $0.level == .error &&
                $0.moduleName == "first" &&
                $0.originalError?.contains("closeFailed") == true
        })
        XCTAssertTrue(errorEventCodes.value.contains("module_close_error"))
    }

    func testModuleUnsubscribeReportsCloseErrors() {
        let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
        let sdk = createInstance(InstanceOptions(
            logLevel: .info,
            onDiagnostic: { diagnostic in
                diagnostics.value.append(diagnostic)
            }
        ))

        let unsubscribe = sdk.addModule(FeaturevisorModule(
            name: "dynamic",
            close: {
                throw TestModuleError.closeFailed
            }
        ))

        XCTAssertNotNil(unsubscribe)
        unsubscribe?()
        unsubscribe?()

        XCTAssertEqual(diagnostics.value.filter { $0.code == "module_close_error" && $0.moduleName == "dynamic" }.count, 1)
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
