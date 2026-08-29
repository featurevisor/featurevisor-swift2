import Foundation
import Featurevisor

private struct TestSummary {
    var passedTests = 0
    var failedTests = 0
    var passedAssertions = 0
    var failedAssertions = 0
}

private struct AssertionReport {
    let description: String
    let passed: Bool
    let messages: [String]
}

struct TestCommand {
    func run(_ options: CLIOptions) -> Int32 {
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

        guard let tests = CLIHelpers.runJSON(projectDirectoryPath: options.projectDirectoryPath, args: testArgs) as? [[String: Any]] else {
            return 1
        }

        var summary = TestSummary()

        for test in tests {
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

            if let segmentKey = test["segment"] as? String {
                let result = runSegmentTest(segmentKey: segmentKey, test: test, segmentsByKey: segments, options: options)
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

    private func runGlobalVariableTest(variableKey: String, test: [String: Any], options: CLIOptions, datafileCache: [String: DatafileContent]) -> (ok: Bool, passed: Int, failed: Int) {
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
            let sdk = sdkForAssertion(datafile: datafile, assertion: assertion, options: options)
            if let sticky = CLIHelpers.anyToStickyVariables(assertion["stickyVariables"]) { sdk.setStickyVariables(sticky, replace: true) }
            let context = CLIHelpers.parseContext(assertion["context"] as? [String: Any])
            let defaultValue = assertion["defaultVariableValue"].map(CLIHelpers.anyToAnyValue)
            let evaluation = sdk.evaluateVariable(variableKey, context: context, options: OverrideOptions(defaultVariableValue: defaultValue))
            var messages: [String] = []
            if let expected = assertion["expectedValue"], !CLIHelpers.compareExpected(evaluation.variableValue ?? defaultValue, expected: expected) {
                messages.append(formatMismatch(type: "variable", expected: expected, actual: (evaluation.variableValue ?? defaultValue)?.rawValue, variableKey: variableKey))
            }
            if let expectedEvaluation = assertion["expectedEvaluation"] as? [String: Any] {
                for (field, expected) in expectedEvaluation where !CLIHelpers.compareAnyExpected(CLIHelpers.evaluationFieldValue(evaluation, key: field), expected: expected) {
                    messages.append(formatMismatch(type: "evaluation", expected: expected, actual: CLIHelpers.evaluationFieldValue(evaluation, key: field), variableKey: variableKey, evaluationType: "variable", evaluationKey: field))
                }
            }
            if messages.isEmpty { passed += 1 } else { failed += 1 }
            reports.append(AssertionReport(description: description, passed: messages.isEmpty, messages: messages))
        }
        let ok = failed == 0
        if !options.onlyFailures || !ok {
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
        return (ok, passed, failed)
    }

    private func loadSegments(_ options: CLIOptions) -> [String: Any] {
        guard let arr = CLIHelpers.runJSON(projectDirectoryPath: options.projectDirectoryPath, args: ["list", "--segments", "--json"]) as? [[String: Any]] else {
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
        if let environment, !environment.isEmpty { return environment }
        return CLIHelpers.noEnvironmentKey
    }

    func targetDatafileCacheKey(_ environment: String?, _ target: String) -> String {
        if let environment, !environment.isEmpty {
            return "\(environment)-target-\(target)"
        }
        return "false-target-\(target)"
    }

    func datafileCacheKeyForAssertion(_ assertion: [String: Any], datafileCache: [String: DatafileContent]) -> String {
        let env = assertion["environment"] as? String
        let target = assertion["target"] as? String
        if let target {
            let targetKey = targetDatafileCacheKey(env, target)
            if datafileCache[targetKey] != nil {
                return targetKey
            }
        }
        return datafileCacheKey(env)
    }

    private func loadTargetKeys(_ options: CLIOptions) -> [String] {
        guard let targets = CLIHelpers.runJSON(projectDirectoryPath: options.projectDirectoryPath, args: ["list", "--targets", "--json"]) as? [[String: Any]] else {
            return []
        }
        return targets.compactMap { $0["key"] as? String }
    }

    private func buildDatafileCache(options: CLIOptions, config: [String: Any]) -> [String: DatafileContent] {
        var cache: [String: DatafileContent] = [:]
        let envs = CLIHelpers.stringArray(config["environments"])
        let environments: [String?] = envs.isEmpty ? [nil] : envs.map(Optional.some)
        let availableTargets = loadTargetKeys(options)
        let targetKeys = options.targets.isEmpty ? availableTargets : options.targets

        for environment in environments {
            guard let base = CLIHelpers.buildDatafileJSON(
                projectDirectoryPath: options.projectDirectoryPath,
                environment: environment,
                inflate: options.inflate
            ) else { continue }

            cache[datafileCacheKey(environment)] = base

            for target in targetKeys {
                if let targetDatafile = CLIHelpers.buildDatafileJSON(
                    projectDirectoryPath: options.projectDirectoryPath,
                    environment: environment,
                    inflate: options.inflate,
                    target: target
                ) {
                    cache[targetDatafileCacheKey(environment, target)] = targetDatafile
                }
            }
        }

        return cache
    }

    private func sdkForAssertion(datafile: DatafileContent, assertion: [String: Any], options: CLIOptions) -> Featurevisor {
        let sticky = CLIHelpers.anyToSticky(assertion["sticky"])
        let forcedAt = CLIHelpers.doubleValue(assertion["at"])
        let module = FeaturevisorModule(name: "test-module", bucketValue: { options in
            if let at = forcedAt {
                return Int(at * 1000)
            }
            return options.bucketValue
        })

        return createFeaturevisor(
            FeaturevisorOptions(
                datafile: datafile,
                logLevel: CLIHelpers.logLevel(options),
                stickyFeatures: sticky,
                modules: [module]
            )
        )
    }

    private func runFeatureTest(
        featureKey: String,
        test: [String: Any],
        options: CLIOptions,
        datafileCache: [String: DatafileContent]
    ) -> (ok: Bool, passed: Int, failed: Int) {
        guard var assertions = test["assertions"] as? [[String: Any]] else {
            return (false, 0, 1)
        }
        if !options.targets.isEmpty {
            assertions = assertions.filter { assertion in
                guard let target = assertion["target"] as? String else { return true }
                return options.targets.contains(target)
            }
            if assertions.isEmpty { return (true, 0, 0) }
        }

        let testKey = (test["key"] as? String) ?? featureKey
        var passed = 0
        var failed = 0
        var reports: [AssertionReport] = []

        for assertion in assertions {
            let description = (assertion["description"] as? String) ?? "assertion"
            let env = assertion["environment"] as? String
            let cacheKey = datafileCacheKeyForAssertion(assertion, datafileCache: datafileCache)

            guard let datafile = datafileCache[cacheKey] ?? datafileCache[datafileCacheKey(env)] else {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: ["=> datafile not found for assertion"]))
                continue
            }

            if options.showDatafile, let text = try? datafile.toJSON(pretty: true) {
                print("")
                print(text)
                print("")
            }

            let sdk = sdkForAssertion(datafile: datafile, assertion: assertion, options: options)

            var contextMap: [String: Any] = [:]
            if let assertionContext = assertion["context"] as? [String: Any] {
                contextMap.merge(assertionContext, uniquingKeysWith: { _, new in new })
            }
            let context = CLIHelpers.parseContext(contextMap)
            sdk.setContext(context)

            var assertionFailed = false
            var messages: [String] = []

            if let expectedEnabled = assertion["expectedToBeEnabled"] as? Bool {
                let actual = sdk.isEnabled(featureKey, context)
                if actual != expectedEnabled {
                    assertionFailed = true
                    messages.append(formatMismatch(type: "flag", expected: expectedEnabled, actual: actual))
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
                    messages.append(formatMismatch(type: "variation", expected: expectedVariation, actual: actual))
                }
            }

            if let expectedVariables = assertion["expectedVariables"] as? [String: Any] {
                for (variableKey, expected) in expectedVariables {
                    let defaultValue = (assertion["defaultVariableValues"] as? [String: Any]).flatMap { $0[variableKey] }.map(CLIHelpers.anyToAnyValue)
                    let actual = sdk.getVariable(featureKey, variableKey, context, OverrideOptions(defaultVariableValue: defaultValue))
                    let schemaType = datafile.features[featureKey]?.variablesSchema?[variableKey]?.type
                    if !CLIHelpers.compareExpected(actual, expected: expected, schemaType: schemaType) {
                        assertionFailed = true
                        messages.append(formatMismatch(type: "variable", expected: expected, actual: actual?.rawValue, variableKey: variableKey))
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
                            messages.append(formatMismatch(type: "evaluation", expected: expected, actual: actual, evaluationType: "flag", evaluationKey: key))
                        }
                    }
                }

                if let expectedVariation = expectedEvaluations["variation"] as? [String: Any] {
                    let evaluation = sdk.evaluateVariation(featureKey, context: context)
                    for (key, expected) in expectedVariation {
                        let actual = CLIHelpers.evaluationFieldValue(evaluation, key: key)
                        if !CLIHelpers.compareAnyExpected(actual, expected: expected) {
                            assertionFailed = true
                            messages.append(formatMismatch(type: "evaluation", expected: expected, actual: actual, evaluationType: "variation", evaluationKey: key))
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
                                messages.append(formatMismatch(type: "evaluation", expected: expected, actual: actual, variableKey: variableKey, evaluationType: "variable", evaluationKey: key))
                            }
                        }
                    }
                }
            }

            if let children = assertion["children"] as? [[String: Any]] {
                var childIndex = 0
                for childAssertion in children {
                    var childContextMap = contextMap
                    if let childContext = childAssertion["context"] as? [String: Any] {
                        childContextMap.merge(childContext, uniquingKeysWith: { _, new in new })
                    }
                    let childContext = CLIHelpers.parseContext(childContextMap)
                    let childSticky = CLIHelpers.anyToSticky(assertion["sticky"])
                    let child = sdk.spawn(childContext, options: SpawnOptions(stickyFeatures: childSticky))

                    if let expectedEnabled = childAssertion["expectedToBeEnabled"] as? Bool,
                       child.isEnabled(featureKey) != expectedEnabled {
                        assertionFailed = true
                        messages.append(formatMismatch(type: "flag", expected: expectedEnabled, actual: child.isEnabled(featureKey), childIndex: childIndex))
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
                            messages.append(formatMismatch(type: "variation", expected: expectedVariation, actual: actual, childIndex: childIndex))
                        }
                    }
                    if let expectedVariables = childAssertion["expectedVariables"] as? [String: Any] {
                        for (variableKey, expected) in expectedVariables {
                            let actual = child.getVariable(featureKey, variableKey)
                            let schemaType = datafile.features[featureKey]?.variablesSchema?[variableKey]?.type
                            if !CLIHelpers.compareExpected(actual, expected: expected, schemaType: schemaType) {
                                assertionFailed = true
                                messages.append(formatMismatch(type: "variable", expected: expected, actual: actual?.rawValue, variableKey: variableKey, childIndex: childIndex))
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
                                    messages.append(formatMismatch(type: "evaluation", expected: expected, actual: actual, childIndex: childIndex, evaluationType: "flag", evaluationKey: key))
                                }
                            }
                        }

                        if let expectedVariation = expectedEvaluations["variation"] as? [String: Any] {
                            let evaluation = child.evaluateVariation(featureKey)
                            for (key, expected) in expectedVariation {
                                let actual = CLIHelpers.evaluationFieldValue(evaluation, key: key)
                                if !CLIHelpers.compareAnyExpected(actual, expected: expected) {
                                    assertionFailed = true
                                    messages.append(formatMismatch(type: "evaluation", expected: expected, actual: actual, childIndex: childIndex, evaluationType: "variation", evaluationKey: key))
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
                                        messages.append(formatMismatch(type: "evaluation", expected: expected, actual: actual, variableKey: variableKey, childIndex: childIndex, evaluationType: "variable", evaluationKey: key))
                                    }
                                }
                            }
                        }
                    }
                    childIndex += 1
                }
            }

            if assertionFailed {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: messages))
            } else {
                passed += 1
                reports.append(AssertionReport(description: description, passed: true, messages: []))
            }
        }

        let ok = failed == 0
        if !options.onlyFailures || !ok {
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
        return (ok, passed, failed)
    }

    private func runSegmentTest(
        segmentKey: String,
        test: [String: Any],
        segmentsByKey: [String: Any],
        options: CLIOptions
    ) -> (ok: Bool, passed: Int, failed: Int) {
        guard let assertions = test["assertions"] as? [[String: Any]],
              let segment = segmentsByKey[segmentKey] as? [String: Any],
              let rawConditions = segment["conditions"] else {
            return (false, 0, 1)
        }

        let testKey = (test["key"] as? String) ?? segmentKey
        let conditions = CLIHelpers.anyToCondition(rawConditions)
        var passed = 0
        var failed = 0
        var reports: [AssertionReport] = []

        for assertion in assertions {
            let context = CLIHelpers.parseContext(assertion["context"] as? [String: Any])
            let actual = allConditionsAreMatched(conditions, context: context)
            let expected = (assertion["expectedToMatch"] as? Bool) ?? false
            let description = (assertion["description"] as? String) ?? "assertion"
            if actual == expected {
                passed += 1
                reports.append(AssertionReport(description: description, passed: true, messages: []))
            } else {
                failed += 1
                reports.append(AssertionReport(description: description, passed: false, messages: [formatMismatch(type: "segment", expected: expected, actual: actual)]))
            }
        }

        let ok = failed == 0
        if !options.onlyFailures || !ok {
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
        return (ok, passed, failed)
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
