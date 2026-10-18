import Foundation
import Featurevisor

private struct TestSummary {
    var passedTests = 0
    var failedTests = 0
    var passedAssertions = 0
    var failedAssertions = 0
}

struct AssertionReport {
    let description: String
    let passed: Bool
    let messages: [String]
    let errors: [[String: Any]]

    init(description: String, passed: Bool, messages: [String], errors: [[String: Any]] = []) {
        self.description = description
        self.passed = passed
        self.messages = messages
        self.errors = errors
    }
}

struct TestExecutionResult {
    let ok: Bool
    let passed: Int
    let failed: Int
    let assertions: [[String: Any]]
    let reports: [AssertionReport]
}

struct TestCommand {
    func runLegacy(_ options: CLIOptions) -> Int32 {
        guard let config = CLIHelpers.runJSON(projectDirectoryPath: options.projectDirectoryPath, args: ["config", "--json"]) as? [String: Any] else {
            return 1
        }

        let segments = loadSegments(options)
        if !options.targets.isEmpty {
            let availableTargets = loadTargetKeys(options)
            if let unknown = options.targets.first(where: { !availableTargets.contains($0) }) {
                print("Unknown target \"\(unknown)\". Available targets: \(availableTargets.isEmpty ? "none" : availableTargets.joined(separator: ", ")).")
                return 1
            }
        }
        let datafileCache = buildDatafileCache(options: options, config: config)

        var testArgs = ["list", "--tests", "--applyMatrix", "--json"]
        if !options.keyPattern.isEmpty { testArgs.append("--keyPattern=\(options.keyPattern)") }
        if !options.assertionPattern.isEmpty { testArgs.append("--assertionPattern=\(options.assertionPattern)") }
        if !options.entityType.isEmpty { testArgs.append("--entityType=\(options.entityType)") }
        if !options.set.isEmpty { testArgs.append("--set=\(options.set)") }

        guard let tests = CLIHelpers.runJSON(projectDirectoryPath: options.projectDirectoryPath, args: testArgs) as? [[String: Any]] else {
            return 1
        }

        var summary = TestSummary()

        for test in tests {
            let discriminatorCount = ["feature", "segment", "variable", "scenario"].filter { test.keys.contains($0) }.count
            if discriminatorCount != 1 {
                summary.failedTests += 1
                summary.failedAssertions += 1
                if !options.quiet { print("test must contain exactly one of feature, segment, variable, or scenario") }
                continue
            }
            if let featureKey = test["feature"] as? String {
                if !options.targets.isEmpty,
                   let assertions = test["assertions"] as? [[String: Any]],
                   !assertions.contains(where: { assertion in
                       guard let target = assertion["target"] as? String else { return true }
                       return options.targets.contains(target)
                   }) {
                    continue
                }
                let result = runFeatureTest(
                    featureKey: featureKey,
                    test: test,
                    options: options,
                    datafileCache: datafileCache
                )
                summary.passedTests += result.ok ? 1 : 0
                summary.failedTests += result.ok ? 0 : 1
                summary.passedAssertions += result.passed
                summary.failedAssertions += result.failed
                continue
            }

            if let variableKey = test["variable"] as? String {
                let result = runGlobalVariableTest(variableKey: variableKey, test: test, options: options, datafileCache: datafileCache)
                summary.passedTests += result.ok ? 1 : 0
                summary.failedTests += result.ok ? 0 : 1
                summary.passedAssertions += result.passed
                summary.failedAssertions += result.failed
                continue
            }

            if let scenarioKey = test["scenario"] as? String {
                let result = runScenarioTest(scenarioKey: scenarioKey, test: test, options: options, datafileCache: datafileCache)
                summary.passedTests += result.ok ? 1 : 0
                summary.failedTests += result.ok ? 0 : 1
                summary.passedAssertions += result.passed
                summary.failedAssertions += result.failed
                continue
            }

            if let segmentKey = test["segment"] as? String {
                let result = runSegmentTest(segmentKey: segmentKey, test: test, segmentsByKey: segments, options: options, datafileCache: datafileCache)
                summary.passedTests += result.ok ? 1 : 0
                summary.failedTests += result.ok ? 0 : 1
                summary.passedAssertions += result.passed
                summary.failedAssertions += result.failed
                continue
            }
        }

        print("\n---\n")
        if summary.failedTests == 0 {
            print("\u{001B}[32mTest specs: \(summary.passedTests) passed, \(summary.failedTests) failed\u{001B}[0m")
            print("\u{001B}[32mAssertions: \(summary.passedAssertions) passed, \(summary.failedAssertions) failed\u{001B}[0m")
            return 0
        }

        print("\u{001B}[31mTest specs: \(summary.passedTests) passed, \(summary.failedTests) failed\u{001B}[0m")
        print("\u{001B}[31mAssertions: \(summary.passedAssertions) passed, \(summary.failedAssertions) failed\u{001B}[0m")
        return 1
    }

    func runGlobalVariableTest(variableKey: String, test: [String: Any], options: CLIOptions, datafileCache: [String: DatafileContent]) -> TestExecutionResult {
        let segmentDefinitions = test["_segments"] as? [String: Any] ?? [:]
        var assertions = test["assertions"] as? [[String: Any]] ?? []
        if !options.targets.isEmpty {
            assertions = assertions.filter { assertion in
                guard let target = assertion["target"] as? String else { return true }
                return options.targets.contains(target)
            }
        }
        var passed = 0
        var failed = 0
        var reports: [AssertionReport] = []
        for assertion in assertions {
            let description = assertion["description"] as? String ?? "assertion"
            let key = datafileCacheKeyForAssertion(assertion, datafileCache: datafileCache)
            guard let datafile = datafileCache[key] else {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: ["=> datafile not found for assertion"]))
                continue
            }
            do {
                try preflightExpandedAssertionChecks(assertion, ownerVariable: variableKey, datafile: datafile, segmentDefinitions: segmentDefinitions)
            } catch {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: [error.localizedDescription], errors: [["message": error.localizedDescription, "type": "check", "expected": "valid check references", "actual": NSNull()]]))
                continue
            }
            if !options.silentTestOutput, options.showDatafile, let text = try? datafile.toJSON(pretty: true) {
                print("")
                print(text)
                print("")
            }
            let built = sdkForAssertion(datafile: datafile, assertion: assertion, options: options, segmentDefinitions: test["_segments"] as? [String: Any] ?? [:])
            let sdk = built.sdk
            let context = CLIHelpers.parseContext(assertion["context"] as? [String: Any])
            sdk.setContext(context)
            var messages: [String] = []
            var structuredErrors: [[String: Any]] = []
            evaluateGlobalVariableExpectation(
                variableKey: variableKey,
                assertion: assertion,
                evaluation: sdk.evaluateVariable(variableKey, options: variableOverrideOptions(assertion)),
                messages: &messages,
                errors: &structuredErrors
            )
            let rootChecks = evaluateAssertionChecksDetailed(assertion, ownerVariable: variableKey, resolver: NativeCheckResolver(sdk, diagnostics: built.diagnostics, segmentDefinitions: segmentDefinitions, context: context, segmentGates: built.segmentGates), datafile: datafile)
            messages.append(contentsOf: rootChecks.failures)
            structuredErrors.append(contentsOf: rootChecks.reportErrors)
            if let children = assertion["children"] as? [[String: Any]] {
                for (childIndex, childAssertion) in children.enumerated() {
                    let child = sdk.spawn(
                        CLIHelpers.parseContext(childAssertion["context"] as? [String: Any]),
                        options: SpawnOptions(
                            stickyFeatures: CLIHelpers.anyToSticky(childAssertion["stickyFeatures"]) ?? [:],
                            stickyVariables: CLIHelpers.anyToStickyVariables(childAssertion["stickyVariables"]) ?? [:]
                        )
                    )
                    evaluateGlobalVariableExpectation(
                        variableKey: variableKey,
                        assertion: childAssertion,
                        evaluation: child.evaluateVariable(variableKey, options: variableOverrideOptions(childAssertion)),
                        childIndex: childIndex,
                        messages: &messages,
                        errors: &structuredErrors
                    )
                    let childContext = mergedContext(context, CLIHelpers.parseContext(childAssertion["context"] as? [String: Any]))
                    let childChecks = evaluateAssertionChecksDetailed(childAssertion, ownerVariable: variableKey, resolver: NativeCheckResolver(child, diagnostics: built.diagnostics, segmentDefinitions: segmentDefinitions, context: childContext, segmentGates: built.segmentGates), datafile: datafile, prefix: "children[\(childIndex)].", basePath: ["children", childIndex], childIndex: childIndex)
                    messages.append(contentsOf: childChecks.failures)
                    structuredErrors.append(contentsOf: childChecks.reportErrors)
                    child.close()
                }
            }
            sdk.close()
            if messages.isEmpty { passed += 1 } else { failed += 1 }
            reports.append(AssertionReport(description: description, passed: messages.isEmpty, messages: messages, errors: structuredErrors))
        }
        let ok = failed == 0
        if !options.silentTestOutput && (!options.onlyFailures || !ok) {
            let testKey = test["key"] as? String ?? variableKey
            let status = ok ? "passed" : "failed"
            print("\nTesting: \(testKey)")
            print("  variable \"\(variableKey)\":")
            for report in reports {
                if report.passed { if !options.onlyFailures { print("  \u{2714} \(report.description)") } }
                else { print("\u{001B}[31m  \u{2718} \(report.description)\u{001B}[0m"); report.messages.forEach { print("\u{001B}[31m    \($0)\u{001B}[0m") } }
            }
            print("  => \(status) (\(passed) passed, \(failed) failed)")
        }
        return TestExecutionResult(ok: ok, passed: passed, failed: failed, assertions: assertions, reports: reports)
    }

    func runScenarioTest(scenarioKey: String, test: [String: Any], options: CLIOptions, datafileCache: [String: DatafileContent]) -> TestExecutionResult {
        let segmentDefinitions = test["_segments"] as? [String: Any] ?? [:]
        var assertions = test["assertions"] as? [[String: Any]] ?? []
        if !options.targets.isEmpty {
            assertions = assertions.filter { assertion in
                guard let target = assertion["target"] as? String else { return true }
                return options.targets.contains(target)
            }
        }
        if assertions.isEmpty {
            return TestExecutionResult(
                ok: false,
                passed: 0,
                failed: 1,
                assertions: [[:]],
                reports: [AssertionReport(description: "assertion", passed: false, messages: ["scenario assertion needs checks or children"])]
            )
        }
        var passed = 0
        var failed = 0
        var reports: [AssertionReport] = []
        for assertion in assertions {
            let description = assertion["description"] as? String ?? "assertion"
            let key = datafileCacheKeyForAssertion(assertion, datafileCache: datafileCache)
            guard let datafile = datafileCache[key] else {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: ["=> datafile not found for scenario assertion"]))
                continue
            }
            do {
                try preflightExpandedAssertionChecks(assertion, ownerVariable: nil, datafile: datafile, segmentDefinitions: segmentDefinitions)
            } catch {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: [error.localizedDescription], errors: [["message": error.localizedDescription, "type": "check", "expected": "valid check references", "actual": NSNull()]]))
                continue
            }
            if !options.silentTestOutput, options.showDatafile, let text = try? datafile.toJSON(pretty: true) { print("\n\(text)\n") }
            let built = sdkForAssertion(datafile: datafile, assertion: assertion, options: options, segmentDefinitions: test["_segments"] as? [String: Any] ?? [:])
            let sdk = built.sdk
            let rootContext = CLIHelpers.parseContext(assertion["context"] as? [String: Any])
            sdk.setContext(rootContext)
            var messages: [String] = []
            var structuredErrors: [[String: Any]] = []
            let hasChecks = assertion.keys.contains("checks")
            let children = assertion["children"] as? [[String: Any]] ?? []
            if !hasChecks && children.isEmpty { messages.append("scenario assertion needs checks or children") }
            let rootChecks = evaluateAssertionChecksDetailed(assertion, ownerVariable: nil, resolver: NativeCheckResolver(sdk, diagnostics: built.diagnostics, segmentDefinitions: segmentDefinitions, context: rootContext, segmentGates: built.segmentGates), datafile: datafile)
            messages.append(contentsOf: rootChecks.failures)
            structuredErrors.append(contentsOf: rootChecks.reportErrors)
            for (childIndex, childAssertion) in children.enumerated() {
                    let child = sdk.spawn(
                        CLIHelpers.parseContext(childAssertion["context"] as? [String: Any]),
                        options: SpawnOptions(
                            stickyFeatures: CLIHelpers.anyToSticky(childAssertion["stickyFeatures"]) ?? [:],
                            stickyVariables: CLIHelpers.anyToStickyVariables(childAssertion["stickyVariables"]) ?? [:]
                        )
                    )
                    if !childAssertion.keys.contains("checks") { messages.append("children[\(childIndex)].checks: expected a nonempty array") }
                    let childContext = mergedContext(rootContext, CLIHelpers.parseContext(childAssertion["context"] as? [String: Any]))
                    let childChecks = evaluateAssertionChecksDetailed(childAssertion, ownerVariable: nil, resolver: NativeCheckResolver(child, diagnostics: built.diagnostics, segmentDefinitions: segmentDefinitions, context: childContext, segmentGates: built.segmentGates), datafile: datafile, prefix: "children[\(childIndex)].", basePath: ["children", childIndex], childIndex: childIndex)
                    messages.append(contentsOf: childChecks.failures)
                    structuredErrors.append(contentsOf: childChecks.reportErrors)
                    child.close()
            }
            sdk.close()
            if messages.isEmpty { passed += 1 } else { failed += 1 }
            reports.append(AssertionReport(description: description, passed: messages.isEmpty, messages: messages, errors: structuredErrors))
        }
        let ok = failed == 0
        if !options.silentTestOutput && (!options.onlyFailures || !ok) {
            print("\nTesting scenario: \(test["key"] as? String ?? scenarioKey)")
            for report in reports {
                if report.passed { if !options.onlyFailures { print("  \u{2714} \(report.description)") } }
                else { print("\u{001B}[31m  \u{2718} \(report.description)\u{001B}[0m"); report.messages.forEach { print("\u{001B}[31m    \($0)\u{001B}[0m") } }
            }
            print("  => \(ok ? "passed" : "failed") (\(passed) passed, \(failed) failed)")
        }
        return TestExecutionResult(ok: ok, passed: passed, failed: failed, assertions: assertions, reports: reports)
    }

    private func mergedContext(_ root: Context, _ child: Context) -> Context {
        root.merging(child) { _, childValue in childValue }
    }

    func loadSegments(_ options: CLIOptions) -> [String: Any] {
        var args = ["list", "--segments", "--json"]
        if !options.set.isEmpty { args.append("--set=\(options.set)") }
        guard let arr = CLIHelpers.runJSON(projectDirectoryPath: options.projectDirectoryPath, args: args) as? [[String: Any]] else {
            return [:]
        }
        var output: [String: Any] = [:]
        for item in arr {
            if let key = item["key"] as? String {
                output[key] = item
            }
        }
        return output
    }

    func datafileCacheKey(_ environment: String?) -> String {
        selectionDatafileCacheKey(environment, nil)
    }

    func targetDatafileCacheKey(_ environment: String?, _ target: String) -> String {
        selectionDatafileCacheKey(environment, target)
    }

    private func selectionDatafileCacheKey(_ environment: String?, _ target: String?) -> String {
        // A pair of optional strings cannot fail JSON encoding.
        let encoded = try! JSONEncoder().encode([environment, target])
        return String(decoding: encoded, as: UTF8.self)
    }

    func datafileCacheKeyForAssertion(_ assertion: [String: Any], datafileCache: [String: DatafileContent]) -> String {
        let env = assertion["environment"] as? String
        let target = assertion["target"] as? String
        if let target {
            return targetDatafileCacheKey(env, target)
        }
        return datafileCacheKey(env)
    }

    private func loadTargetKeys(_ options: CLIOptions) -> [String] {
        var args = ["list", "--targets", "--json"]
        if !options.set.isEmpty { args.append("--set=\(options.set)") }
        guard let targets = CLIHelpers.runJSON(projectDirectoryPath: options.projectDirectoryPath, args: args) as? [[String: Any]] else {
            return []
        }
        return targets.compactMap { $0["key"] as? String }
    }

    func buildDatafileCache(options: CLIOptions, config: [String: Any]) -> [String: DatafileContent] {
        var cache: [String: DatafileContent] = [:]
        let envs = CLIHelpers.stringArray(config["environments"])
        let environments: [String?] = envs.isEmpty ? [nil] : envs.map(Optional.some)
        let availableTargets = loadTargetKeys(options)
        let targetKeys = options.targets.isEmpty ? availableTargets : options.targets

        for environment in environments {
            guard let base = CLIHelpers.buildDatafileJSON(
                projectDirectoryPath: options.projectDirectoryPath,
                environment: environment,
                inflate: options.inflate,
                set: options.set
            ) else { continue }

            cache[datafileCacheKey(environment)] = base

            for target in targetKeys {
                if let targetDatafile = CLIHelpers.buildDatafileJSON(
                    projectDirectoryPath: options.projectDirectoryPath,
                    environment: environment,
                    inflate: options.inflate,
                    target: target,
                    set: options.set
                ) {
                    cache[targetDatafileCacheKey(environment, target)] = targetDatafile
                }
            }
        }

        return cache
    }

    func sdkForAssertion(datafile: DatafileContent, assertion: [String: Any], options: CLIOptions, segmentDefinitions: [String: Any] = [:]) -> (sdk: Featurevisor, diagnostics: CheckDiagnosticCollector, segmentGates: [String: String]) {
        let prepared = prepareSegmentGates(datafile, definitions: segmentDefinitions)
        let datafile = prepared.datafile
        let sticky = CLIHelpers.anyToSticky(assertion["stickyFeatures"])
        let stickyVariables = CLIHelpers.anyToStickyVariables(assertion["stickyVariables"])
        let forcedAt = CLIHelpers.doubleValue(assertion["at"])
        let module = FeaturevisorModule(name: "test-module", bucketValue: { options in
            if let at = forcedAt {
                return Int(at * 1000)
            }
            return options.bucketValue
        })

        let diagnostics = CheckDiagnosticCollector()
        var modules = [module]
        if let sink = options.coverageSink {
            let set = options.set
            let environment = assertion["environment"] as? String
            let target = assertion["target"] as? String
            modules.append(FeaturevisorModule(name: "test-coverage", afterEvaluation: { evaluation, _ in
                if !prepared.gates.values.contains(evaluation.featureKey ?? "") {
                    sink.record(evaluation: evaluation, set: set, environment: environment, target: target)
                }
                return evaluation
            }))
        }
        let sdk = createFeaturevisor(
            FeaturevisorOptions(
                datafile: datafile,
                logLevel: CLIHelpers.logLevel(options),
                onDiagnostic: { diagnostics.record($0) },
                stickyFeatures: sticky,
                stickyVariables: stickyVariables,
                modules: modules
            )
        )
        if options.quiet && !options.verbose {
            _ = sdk.on(.error) { diagnostics.recordErrorEvent($0) }
        }
        return (sdk, diagnostics, prepared.gates)
    }

    func runFeatureTest(
        featureKey: String,
        test: [String: Any],
        options: CLIOptions,
        datafileCache: [String: DatafileContent]
    ) -> TestExecutionResult {
        guard var assertions = test["assertions"] as? [[String: Any]] else {
            return TestExecutionResult(ok: false, passed: 0, failed: 1, assertions: [[:]], reports: [AssertionReport(description: "assertion", passed: false, messages: ["test must contain a nonempty assertions array"])])
        }
        if !options.targets.isEmpty {
            assertions = assertions.filter { assertion in
                guard let target = assertion["target"] as? String else { return true }
                return options.targets.contains(target)
            }
            if assertions.isEmpty { return TestExecutionResult(ok: true, passed: 0, failed: 0, assertions: [], reports: []) }
        }

        let testKey = (test["key"] as? String) ?? featureKey
        var passed = 0
        var failed = 0
        var reports: [AssertionReport] = []

        for assertion in assertions {
            let description = (assertion["description"] as? String) ?? "assertion"
            let cacheKey = datafileCacheKeyForAssertion(assertion, datafileCache: datafileCache)

            guard let datafile = datafileCache[cacheKey] else {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: ["=> datafile not found for assertion"]))
                continue
            }

            do {
                try preflightExpandedAssertionChecks(
                    assertion,
                    ownerVariable: nil,
                    datafile: datafile,
                    segmentDefinitions: test["_segments"] as? [String: Any] ?? [:]
                )
            } catch {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: [error.localizedDescription], errors: [["message": error.localizedDescription, "type": "check", "expected": "valid check references", "actual": NSNull()]]))
                continue
            }

            if !options.silentTestOutput, options.showDatafile, let text = try? datafile.toJSON(pretty: true) {
                print("")
                print(text)
                print("")
            }

            let built = sdkForAssertion(datafile: datafile, assertion: assertion, options: options, segmentDefinitions: test["_segments"] as? [String: Any] ?? [:])
            let sdk = built.sdk

            var contextMap: [String: Any] = [:]
            if let assertionContext = assertion["context"] as? [String: Any] {
                contextMap.merge(assertionContext, uniquingKeysWith: { _, new in new })
            }
            let context = CLIHelpers.parseContext(contextMap)
            sdk.setContext(context)

            var assertionFailed = false
            var messages: [String] = []
            var structuredErrors: [[String: Any]] = []
            func recordMismatch(
                type: String, expected: Any?, actual: Any?, variableKey: String? = nil,
                childIndex: Int? = nil, evaluationType: String? = nil, evaluationKey: String? = nil
            ) {
                messages.append(formatMismatch(type: type, expected: expected, actual: actual, variableKey: variableKey, childIndex: childIndex, evaluationType: evaluationType, evaluationKey: evaluationKey))
                var path: [Any] = childIndex.map { ["children", $0] } ?? []
                switch type {
                case "flag": path += ["expectedToBeEnabled"]
                case "variation": path += ["expectedVariation"]
                case "variable": path += ["expectedVariables", variableKey!]
                default:
                    path += ["expectedEvaluations"]
                    if let variableKey { path += ["variables", variableKey] }
                    else { path += [evaluationType!] }
                    path += [evaluationKey!]
                }
                structuredErrors.append(expectationReportError(type: type, path: path, expected: expected, actual: actual))
            }

            if let expectedEnabled = assertion["expectedToBeEnabled"] as? Bool {
                let actual = sdk.isEnabled(featureKey, context)
                if actual != expectedEnabled {
                    assertionFailed = true
                    recordMismatch(type: "flag", expected: expectedEnabled, actual: actual)
                }
            }

            if let expectedVariation = assertion["expectedVariation"] {
                let overrideOptions = OverrideOptions(defaultVariationValue: assertion["defaultVariationValue"] as? String)
                let actual = sdk.getVariation(featureKey, context, overrideOptions)
                let ok: Bool
                if expectedVariation is NSNull {
                    ok = (actual == nil)
                } else {
                    ok = (actual == (expectedVariation as? String))
                }
                if !ok {
                    assertionFailed = true
                    recordMismatch(type: "variation", expected: expectedVariation, actual: actual)
                }
            }

            if let expectedVariables = assertion["expectedVariables"] as? [String: Any] {
                for (variableKey, expected) in expectedVariables {
                    let defaultValue = (assertion["defaultVariableValues"] as? [String: Any]).flatMap { $0[variableKey] }.map(CLIHelpers.anyToAnyValue)
                    let actual = sdk.getVariable(featureKey, variableKey, context, OverrideOptions(defaultVariableValue: defaultValue))
                    let schemaType = datafile.features[featureKey]?.variablesSchema?[variableKey]?.type
                    if !CLIHelpers.compareExpected(actual, expected: expected, schemaType: schemaType) {
                        assertionFailed = true
                        recordMismatch(type: "variable", expected: expected, actual: actual?.rawValue, variableKey: variableKey)
                    }
                }
            }

            if let expectedEvaluations = assertion["expectedEvaluations"] as? [String: Any] {
                if let expectedFlag = expectedEvaluations["flag"] as? [String: Any] {
                    let evaluation = sdk.evaluateFlag(featureKey, context: context)
                    for (key, expected) in expectedFlag {
                        let actual = CLIHelpers.evaluationFieldValue(evaluation, key: key)
                        if !CLIHelpers.compareAnyExpected(actual, expected: expected) {
                            assertionFailed = true
                            recordMismatch(type: "evaluation", expected: expected, actual: actual, evaluationType: "flag", evaluationKey: key)
                        }
                    }
                }

                if let expectedVariation = expectedEvaluations["variation"] as? [String: Any] {
                    let evaluation = sdk.evaluateVariation(featureKey, context: context)
                    for (key, expected) in expectedVariation {
                        let actual = CLIHelpers.evaluationFieldValue(evaluation, key: key)
                        if !CLIHelpers.compareAnyExpected(actual, expected: expected) {
                            assertionFailed = true
                            recordMismatch(type: "evaluation", expected: expected, actual: actual, evaluationType: "variation", evaluationKey: key)
                        }
                    }
                }

                if let expectedVariables = expectedEvaluations["variables"] as? [String: Any] {
                    for (variableKey, rawExpected) in expectedVariables {
                        guard let expectedVariableEval = rawExpected as? [String: Any] else {
                            assertionFailed = true
                            continue
                        }
                        let evaluation = sdk.evaluateVariable(featureKey, variableKey, context: context)
                        for (key, expected) in expectedVariableEval {
                            let actual = CLIHelpers.evaluationFieldValue(evaluation, key: key)
                            if !CLIHelpers.compareAnyExpected(actual, expected: expected) {
                                assertionFailed = true
                                recordMismatch(type: "evaluation", expected: expected, actual: actual, variableKey: variableKey, evaluationType: "variable", evaluationKey: key)
                            }
                        }
                    }
                }
            }

            let rootChecks = evaluateAssertionChecksDetailed(assertion, ownerVariable: nil, resolver: NativeCheckResolver(sdk, diagnostics: built.diagnostics, segmentDefinitions: test["_segments"] as? [String: Any] ?? [:], context: context, segmentGates: built.segmentGates), datafile: datafile)
            if !rootChecks.failures.isEmpty { assertionFailed = true; messages += rootChecks.failures; structuredErrors += rootChecks.reportErrors }

            if let children = assertion["children"] as? [[String: Any]] {
                var childIndex = 0
                for childAssertion in children {
                    var childContextMap = contextMap
                    if let childContext = childAssertion["context"] as? [String: Any] {
                        childContextMap.merge(childContext, uniquingKeysWith: { _, new in new })
                    }
                    let childContext = CLIHelpers.parseContext(childContextMap)
                    // A child owns its sticky values. It does not inherit the parent assertion's.
                    let child = sdk.spawn(
                        childContext,
                        options: SpawnOptions(
                            stickyFeatures: CLIHelpers.anyToSticky(childAssertion["stickyFeatures"]) ?? [:],
                            stickyVariables: CLIHelpers.anyToStickyVariables(childAssertion["stickyVariables"]) ?? [:]
                        )
                    )

                    if let expectedEnabled = childAssertion["expectedToBeEnabled"] as? Bool,
                       child.isEnabled(featureKey) != expectedEnabled {
                        assertionFailed = true
                        recordMismatch(type: "flag", expected: expectedEnabled, actual: child.isEnabled(featureKey), childIndex: childIndex)
                    }
                    if let expectedVariation = childAssertion["expectedVariation"] {
                        let actual = child.getVariation(featureKey)
                        let ok: Bool
                        if expectedVariation is NSNull {
                            ok = (actual == nil)
                        } else {
                            ok = (actual == (expectedVariation as? String))
                        }
                        if !ok {
                            assertionFailed = true
                            recordMismatch(type: "variation", expected: expectedVariation, actual: actual, childIndex: childIndex)
                        }
                    }
                    if let expectedVariables = childAssertion["expectedVariables"] as? [String: Any] {
                        for (variableKey, expected) in expectedVariables {
                            let actual = child.getVariable(featureKey, variableKey)
                            let schemaType = datafile.features[featureKey]?.variablesSchema?[variableKey]?.type
                            if !CLIHelpers.compareExpected(actual, expected: expected, schemaType: schemaType) {
                                assertionFailed = true
                                recordMismatch(type: "variable", expected: expected, actual: actual?.rawValue, variableKey: variableKey, childIndex: childIndex)
                            }
                        }
                    }

                    if let expectedEvaluations = childAssertion["expectedEvaluations"] as? [String: Any] {
                        if let expectedFlag = expectedEvaluations["flag"] as? [String: Any] {
                            let evaluation = child.evaluateFlag(featureKey)
                            for (key, expected) in expectedFlag {
                                let actual = CLIHelpers.evaluationFieldValue(evaluation, key: key)
                                if !CLIHelpers.compareAnyExpected(actual, expected: expected) {
                                    assertionFailed = true
                                    recordMismatch(type: "evaluation", expected: expected, actual: actual, childIndex: childIndex, evaluationType: "flag", evaluationKey: key)
                                }
                            }
                        }

                        if let expectedVariation = expectedEvaluations["variation"] as? [String: Any] {
                            let evaluation = child.evaluateVariation(featureKey)
                            for (key, expected) in expectedVariation {
                                let actual = CLIHelpers.evaluationFieldValue(evaluation, key: key)
                                if !CLIHelpers.compareAnyExpected(actual, expected: expected) {
                                    assertionFailed = true
                                    recordMismatch(type: "evaluation", expected: expected, actual: actual, childIndex: childIndex, evaluationType: "variation", evaluationKey: key)
                                }
                            }
                        }

                        if let expectedVariables = expectedEvaluations["variables"] as? [String: Any] {
                            for (variableKey, rawExpected) in expectedVariables {
                                guard let expectedVariableEval = rawExpected as? [String: Any] else {
                                    assertionFailed = true
                                    continue
                                }
                                let evaluation = child.evaluateVariable(featureKey, variableKey)
                                for (key, expected) in expectedVariableEval {
                                    let actual = CLIHelpers.evaluationFieldValue(evaluation, key: key)
                                    if !CLIHelpers.compareAnyExpected(actual, expected: expected) {
                                        assertionFailed = true
                                        recordMismatch(type: "evaluation", expected: expected, actual: actual, variableKey: variableKey, childIndex: childIndex, evaluationType: "variable", evaluationKey: key)
                                    }
                                }
                            }
                        }
                    }
                    let childChecks = evaluateAssertionChecksDetailed(childAssertion, ownerVariable: nil, resolver: NativeCheckResolver(child, diagnostics: built.diagnostics, segmentDefinitions: test["_segments"] as? [String: Any] ?? [:], context: childContext, segmentGates: built.segmentGates), datafile: datafile, prefix: "children[\(childIndex)].", basePath: ["children", childIndex], childIndex: childIndex)
                    if !childChecks.failures.isEmpty { assertionFailed = true; messages += childChecks.failures; structuredErrors += childChecks.reportErrors }
                    child.close()
                    childIndex += 1
                }
            }

            sdk.close()

            if assertionFailed {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: messages, errors: structuredErrors))
            } else {
                passed += 1
                reports.append(AssertionReport(description: description, passed: true, messages: []))
            }
        }

        let ok = failed == 0
        if !options.silentTestOutput && (!options.onlyFailures || !ok) {
            print("")
            print("Testing: \(testKey)")
            print("  feature \"\(featureKey)\":")
            for report in reports {
                if report.passed {
                    if !options.onlyFailures {
                        print("  \u{2714} \(report.description)")
                    }
                    continue
                }

                print("\u{001B}[31m  \u{2718} \(report.description)\u{001B}[0m")
                for message in report.messages {
                    print("\u{001B}[31m    \(message)\u{001B}[0m")
                }
            }
            print("  => \(ok ? "passed" : "failed") (\(passed) passed, \(failed) failed)")
        }
        return TestExecutionResult(ok: ok, passed: passed, failed: failed, assertions: assertions, reports: reports)
    }

    func runSegmentTest(
        segmentKey: String,
        test: [String: Any],
        segmentsByKey: [String: Any],
        options: CLIOptions,
        datafileCache: [String: DatafileContent] = [:]
    ) -> TestExecutionResult {
        let definitions = test["_segments"] as? [String: Any] ?? segmentsByKey
        guard var assertions = test["assertions"] as? [[String: Any]],
              let segment = definitions[segmentKey] as? [String: Any],
              let rawConditions = segment["conditions"] else {
            return TestExecutionResult(ok: false, passed: 0, failed: 1, assertions: [[:]], reports: [AssertionReport(description: "assertion", passed: false, messages: ["segment test data is unavailable"])])
        }

        if !options.targets.isEmpty {
            assertions = assertions.filter { assertion in
                guard let target = assertion["target"] as? String else { return true }
                return options.targets.contains(target)
            }
        }
        let testKey = (test["key"] as? String) ?? segmentKey
        _ = rawConditions
        var passed = 0
        var failed = 0
        var reports: [AssertionReport] = []

        for assertion in assertions {
            let context = CLIHelpers.parseContext(assertion["context"] as? [String: Any])
            let description = (assertion["description"] as? String) ?? "assertion"
            let cacheKey = datafileCacheKeyForAssertion(assertion, datafileCache: datafileCache)
            let selected = datafileCache[cacheKey]
            if selected == nil, assertion["environment"] != nil || assertion["target"] != nil {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: ["datafile not found for assertion"]))
                continue
            }
            let datafile = selected ?? DatafileContent(schemaVersion: "4", revision: "segment", segments: [:], features: [:])
            let actual: Bool
            do {
                try preflightSegmentReferences(segmentKey, datafile: datafile, definitions: definitions)
                try preflightExpandedAssertionChecks(assertion, ownerVariable: nil, datafile: datafile, segmentDefinitions: definitions)
                let built = sdkForAssertion(datafile: datafile, assertion: assertion, options: options, segmentDefinitions: definitions)
                defer { built.sdk.close() }
                built.sdk.setContext(context)
                let resolver = NativeCheckResolver(built.sdk, diagnostics: built.diagnostics, segmentDefinitions: definitions, context: context, segmentGates: built.segmentGates)
                actual = try resolver.checkSegment(segmentKey)
                let checks = evaluateAssertionChecksDetailed(assertion, ownerVariable: nil, resolver: resolver, datafile: datafile)
                if !checks.failures.isEmpty { throw NSError(domain: "FeaturevisorCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: checks.failures.joined(separator: "; ")]) }
                for (index, childAssertion) in (assertion["children"] as? [[String: Any]] ?? []).enumerated() {
                    let child = built.sdk.spawn(CLIHelpers.parseContext(childAssertion["context"] as? [String: Any]), options: SpawnOptions(
                        stickyFeatures: CLIHelpers.anyToSticky(childAssertion["stickyFeatures"]),
                        stickyVariables: CLIHelpers.anyToStickyVariables(childAssertion["stickyVariables"])
                    ))
                    defer { child.close() }
                    let childResolver = NativeCheckResolver(child, diagnostics: built.diagnostics, segmentDefinitions: definitions, segmentGates: built.segmentGates)
                    if let expected = childAssertion["expectedToMatch"] as? Bool,
                       try childResolver.checkSegment(segmentKey) != expected {
                        throw NSError(domain: "FeaturevisorCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "children[\(index)]: segment expectation did not match"])
                    }
                    let checks = evaluateAssertionChecksDetailed(childAssertion, ownerVariable: nil, resolver: childResolver, datafile: datafile, prefix: "children[\(index)].", basePath: ["children", index], childIndex: index)
                    if !checks.failures.isEmpty { throw NSError(domain: "FeaturevisorCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: checks.failures.joined(separator: "; ")]) }
                }
            } catch {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: [error.localizedDescription]))
                continue
            }
            let expected = (assertion["expectedToMatch"] as? Bool) ?? false
            if actual == expected {
                passed += 1
                reports.append(AssertionReport(description: description, passed: true, messages: []))
            } else {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: [formatMismatch(type: "segment", expected: expected, actual: actual)], errors: [expectationReportError(type: "segment", path: ["expectedToMatch"], expected: expected, actual: actual)]))
            }
        }

        let ok = failed == 0
        if !options.silentTestOutput && (!options.onlyFailures || !ok) {
            print("")
            print("Testing: \(testKey)")
            print("  segment \"\(segmentKey)\":")
            for report in reports {
                if report.passed {
                    if !options.onlyFailures {
                        print("  \u{2714} \(report.description)")
                    }
                    continue
                }
                print("\u{001B}[31m  \u{2718} \(report.description)\u{001B}[0m")
                for message in report.messages {
                    print("\u{001B}[31m    \(message)\u{001B}[0m")
                }
            }
            print("  => \(ok ? "passed" : "failed") (\(passed) passed, \(failed) failed)")
        }
        return TestExecutionResult(ok: ok, passed: passed, failed: failed, assertions: assertions, reports: reports)
    }

    private func formatMismatch(
        type: String,
        expected: Any?,
        actual: Any?,
        variableKey: String? = nil,
        childIndex: Int? = nil,
        evaluationType: String? = nil,
        evaluationKey: String? = nil
    ) -> String {
        var section: String
        switch type {
        case "flag":
            section = "expectedToBeEnabled"
        case "variation":
            section = "expectedVariation"
        case "variable":
            section = "expectedVariables"
        case "evaluation":
            section = "expectedEvaluations"
        case "segment":
            section = "expectedToMatch"
        default:
            section = type
        }

        if let childIndex {
            section = "children[\(childIndex)].\(section)"
        }

        if type == "variable", let variableKey {
            return "=> \(section).\(variableKey): expected \"\(display(expected))\", received \"\(display(actual))\""
        }

        if type == "evaluation" {
            if let variableKey, let evaluationKey {
                section = "\(section).variables.\(variableKey).\(evaluationKey)"
            } else if let evaluationType, let evaluationKey {
                section = "\(section).\(evaluationType).\(evaluationKey)"
            }
        }

        return "=> \(section): expected \"\(display(expected))\", received \"\(display(actual))\""
    }

    private func variableOverrideOptions(_ assertion: [String: Any]) -> OverrideOptions {
        OverrideOptions(defaultVariableValue: assertion["defaultVariableValue"].map(CLIHelpers.anyToAnyValue))
    }

    private func evaluateGlobalVariableExpectation(
        variableKey: String,
        assertion: [String: Any],
        evaluation: Evaluation,
        childIndex: Int? = nil,
        messages: inout [String],
        errors: inout [[String: Any]]
    ) {
        let base: [Any] = childIndex.map { ["children", $0] } ?? []
        if let expected = assertion["expectedValue"],
           !CLIHelpers.compareExpected(evaluation.variableValue, expected: expected) {
            errors.append(expectationReportError(type: "variable", path: base + ["expectedValue"], expected: expected, actual: evaluation.variableValue?.rawValue))
            messages.append(formatGlobalVariableMismatch(
                section: "expectedValue",
                expected: expected,
                actual: evaluation.variableValue?.rawValue,
                childIndex: childIndex
            ))
        }
        if let expectedEvaluation = assertion["expectedEvaluation"] as? [String: Any] {
            for (field, expected) in expectedEvaluation {
                let actual = CLIHelpers.evaluationFieldValue(evaluation, key: field)
                if !CLIHelpers.compareAnyExpected(actual, expected: expected) {
                    errors.append(expectationReportError(type: "evaluation", path: base + ["expectedEvaluation", field], expected: expected, actual: actual))
                    messages.append(formatGlobalVariableMismatch(
                        section: "expectedEvaluation.\(field)",
                        expected: expected,
                        actual: actual,
                        childIndex: childIndex
                    ))
                }
            }
        }
    }

    private func formatGlobalVariableMismatch(section: String, expected: Any?, actual: Any?, childIndex: Int?) -> String {
        let prefix = childIndex.map { "children[\($0)]." } ?? ""
        return "=> \(prefix)\(section): expected \(display(expected)), received \(display(actual))"
    }

    private func display(_ value: Any?) -> String {
        guard let value else { return "null" }
        if value is NSNull { return "null" }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let int = value as? Int { return String(int) }
        if let double = value as? Double { return String(double) }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }
}
