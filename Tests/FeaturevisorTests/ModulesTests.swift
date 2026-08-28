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

        let sdk = createFeaturevisor(FeaturevisorOptions(
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
        let sdk = createFeaturevisor(FeaturevisorOptions(logLevel: .fatal))

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

        let sdk = createFeaturevisor(FeaturevisorOptions(
            logLevel: .info,
            onDiagnostic: { diagnostic in
                diagnostics.value.append(diagnostic)
            }
        ))

        sdk.on(.error) { payload in
            if case .object(let diagnostic)? = payload.params["diagnostic"],
               case .string(let code)? = diagnostic["code"] {
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
        let sdk = createFeaturevisor(FeaturevisorOptions(
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

        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, modules: [module]))
        let evaluation = sdk.evaluateFlag("exp")

        XCTAssertEqual(bucketKeySeen.value, "from-before.exp")
        XCTAssertEqual(evaluation.bucketValue, 50_000)
        XCTAssertEqual(evaluation.reason, .forced)
    }

    func testModuleDiagnosticLevelIsIndependentFromInstanceLevel() {
        let observed = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
        let module = FeaturevisorModule(
            name: "observer",
            setup: { api in
                api.onDiagnostic({ diagnostic in
                    observed.value.append(diagnostic)
                }, options: FeaturevisorModuleDiagnosticOptions(logLevel: .debug))
            }
        )
        let sdk = createFeaturevisor(FeaturevisorOptions(
            logLevel: .fatal,
            modules: [module]
        ))

        _ = sdk.isEnabled("missing")

        XCTAssertTrue(observed.value.contains {
            $0.code == "feature_not_found" &&
                $0.details["featureKey"] == .string("missing") &&
                $0.details["reason"] == .string("feature_not_found")
        })
    }

    func testCanonicalModulePhaseOrder() {
        let order = ConcurrencyBox<[String]>([])
        func module(_ name: String) -> FeaturevisorModule {
            FeaturevisorModule(
                name: name,
                before: { options in order.value.append("before:\(name)"); return options },
                beforeEvaluation: { options in order.value.append("beforeEvaluation:\(name)"); return options },
                after: { evaluation, _ in order.value.append("after:\(name)"); return evaluation },
                afterEvaluation: { evaluation, _ in order.value.append("afterEvaluation:\(name)"); return evaluation }
            )
        }
        let sdk = createFeaturevisor(FeaturevisorOptions(logLevel: .fatal, modules: [module("first"), module("second")]))
        _ = sdk.evaluateFlag("missing")
        XCTAssertEqual(order.value, [
            "before:first", "before:second",
            "beforeEvaluation:first", "beforeEvaluation:second",
            "afterEvaluation:first", "afterEvaluation:second",
            "after:first", "after:second",
        ])
    }

    func testRequiredFeaturesAndDefaultsUseUnifiedModules() throws {
        let raw = #"{"schemaVersion":"2","revision":"modules","segments":{"allowed":{"conditions":{"attribute":"allow","operator":"equals","value":true}}},"features":{"required":{"bucketBy":"userId","traffic":[{"key":"all","segments":"allowed","percentage":100000}]},"dependent":{"bucketBy":"userId","requiredFeatures":["required"],"traffic":[{"key":"all","segments":"*","percentage":100000}]}},"variables":{}}"#
        let datafile = try JSONDecoder().decode(DatafileContent.self, from: Data(raw.utf8))
        let module = FeaturevisorModule(name: "required-context", beforeEvaluation: { options in
            var updated = options
            if updated.featureKey == "required" { updated.dependencies.context["allow"] = .bool(true) }
            if updated.type == .variable { updated.dependencies.defaultVariableValue = .string("module-default") }
            return updated
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .fatal, modules: [module]))
        XCTAssertTrue(sdk.isEnabled("dependent", ["userId": .string("u")]))
        XCTAssertEqual(sdk.getVariable("missing"), .string("module-default"))
        XCTAssertNil(sdk.evaluateVariable("missing").featureKey)
    }
}
