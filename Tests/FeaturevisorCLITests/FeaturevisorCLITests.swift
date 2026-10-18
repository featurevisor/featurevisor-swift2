import XCTest
import Featurevisor
@testable import FeaturevisorCLI

private final class FeatureCheckResolver: CheckVariableResolver {
    var enabled = false
    var variation: String? = "beta"
    var variationError: Error?
    var calls: [String] = []

    func checkGlobalVariable(_: String) throws -> AnyValue? { nil }
    func checkFeatureVariable(_: String, _: String) throws -> AnyValue? { nil }
    func checkFeatureEnabled(_ feature: String) throws -> Bool {
        calls.append("enabled:\(feature)")
        return enabled
    }
    func checkFeatureVariation(_ feature: String) throws -> String? {
        calls.append("variation:\(feature)")
        if let variationError { throw variationError }
        return variation
    }
}

private final class CountingSegmentResolver: CheckVariableResolver, CheckSegmentResolver, CheckSegmentDefinitionValidator {
    var validations: [String: Int] = [:]
    var resolutions: [String: Int] = [:]
    let available: Set<String>
    let matches: [String: Bool]

    init(available: Set<String>, matches: [String: Bool]) {
        self.available = available
        self.matches = matches
    }

    func checkGlobalVariable(_: String) throws -> AnyValue? { nil }
    func checkFeatureVariable(_: String, _: String) throws -> AnyValue? { nil }
    func checkFeatureEnabled(_: String) throws -> Bool { false }
    func checkFeatureVariation(_: String) throws -> String? { nil }

    func validateSegmentDefinition(_ segment: String) throws {
        validations[segment, default: 0] += 1
        guard available.contains(segment) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "segment \"\(segment)\" definition is missing"])
        }
    }

    func checkSegment(_ segment: String) throws -> Bool {
        resolutions[segment, default: 0] += 1
        return matches[segment] ?? false
    }
}

private final class ValueCheckResolver: CheckVariableResolver {
    var value: AnyValue?
    var error: Error?

    init(_ value: AnyValue?) {
        self.value = value
    }

    func checkGlobalVariable(_: String) throws -> AnyValue? {
        if let error { throw error }
        return value
    }
    func checkFeatureVariable(_: String, _: String) throws -> AnyValue? { try checkGlobalVariable("") }
    func checkFeatureEnabled(_: String) throws -> Bool { false }
    func checkFeatureVariation(_: String) throws -> String? { nil }
}

final class FeaturevisorCLITests: XCTestCase {
    func testHumanExpectationLabelsAreOneBasedWhileStructuredPathsStayZeroBased() {
        let ordinary: [String: Any] = [
            "path": ["assertions", 0, "children", 0, "expectedValue"] as [Any],
            "expected": 2, "actual": 1,
        ]
        XCTAssertEqual(humanExpectationError(ordinary), "Child 1, expectedValue: expected 2, received 1")
        let evaluation: [String: Any] = [
            "path": ["assertions", 0, "children", 1, "expectedEvaluation", "variableValue"] as [Any],
            "expected": 2, "actual": 1,
        ]
        XCTAssertEqual(humanExpectationError(evaluation), "Child 2, expectedEvaluation.variableValue: expected 2, received 1")
        let check: [String: Any] = [
            "path": ["checks", 0] as [Any], "expected": true, "actual": false,
        ]
        XCTAssertEqual(humanExpectationError(check), "checks[1]: expected true, received false")
        XCTAssertEqual(humanCheckMessage("children[0].checks[0] failed: mismatch"), "mismatch")
        XCTAssertEqual((ordinary["path"] as? [Any])?[3] as? Int, 0)
    }
    func testJSONNumbersRemainDistinctFromBooleansInExpectedValues() throws {
        let raw = try JSONSerialization.jsonObject(
            with: Data(
                #"{"values":[0,false,1,true],"nested":{"zero":0,"disabled":false,"one":1,"enabled":true},"ratio":1.5}"#.utf8
            )
        )

        XCTAssertEqual(
            CLIHelpers.anyToAnyValue(raw),
            .object([
                "values": .array([.int(0), .bool(false), .int(1), .bool(true)]),
                "nested": .object([
                    "zero": .int(0),
                    "disabled": .bool(false),
                    "one": .int(1),
                    "enabled": .bool(true),
                ]),
                "ratio": .double(1.5),
            ])
        )
    }

    func testCLIParser() {
        let opts = CLIParser.parse([
            "test",
            "--keyPattern=foo",
            "--with-scopes",
            "--with-tags",
            "--schemaVersion=1",
            "--schema-version=2",
            "--n=10",
            "--projectDirectoryPath=/tmp/project",
            "--set=staging",
            "--case=opaque",
            "--json",
            "--pretty",
            "--coverage",
            "--uncovered",
        ])

        XCTAssertEqual(opts.command, "test")
        XCTAssertEqual(opts.keyPattern, "foo")
        XCTAssertTrue(opts.withScopes)
        XCTAssertTrue(opts.withTags)
        XCTAssertEqual(opts.schemaVersion, "2")
        XCTAssertEqual(opts.n, 10)
        XCTAssertEqual(opts.projectDirectoryPath, "/tmp/project")
        XCTAssertEqual(opts.set, "staging")
        XCTAssertEqual(opts.caseID, "opaque")
        XCTAssertTrue(opts.json)
        XCTAssertTrue(opts.pretty)
        XCTAssertTrue(opts.coverage)
        XCTAssertTrue(opts.uncovered)
    }

    func testScenarioEntityFilter() {
        XCTAssertEqual(CLIParser.parse(["test", "--entityType=scenario"]).entityType, "scenario")
    }

    func testScenarioReportUsesCheckPathsAndPreservesArbitraryPayloadKeys() throws {
        let errors = structuredReportErrors([[
            "message": "original failure",
            "type": "check",
            "path": ["checks", 0] as [Any],
            "expected": true,
            "actual": false,
            "details": [
                "evaluated": [[
                    "path": [0] as [Any],
                    "reference": ["path": "custom"],
                ]],
                "payload": ["checks": "keep checks", "custom": "keep custom"],
            ],
        ]], type: "scenario", assertionIndex: 0, failed: true)

        let error = try XCTUnwrap(errors.first)
        let path = try XCTUnwrap(error["path"] as? [Any])
        XCTAssertEqual(path[0] as? String, "checks")
        XCTAssertEqual(path[1] as? Int, 0)
        XCTAssertEqual(error["message"] as? String, "Check did not match")
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        let evaluated = try XCTUnwrap((details["evaluated"] as? [[String: Any]])?.first)
        let evaluatedPath = try XCTUnwrap(evaluated["path"] as? [Any])
        XCTAssertEqual(evaluatedPath[0] as? String, "checks")
        XCTAssertEqual(evaluatedPath[1] as? Int, 0)
        XCTAssertEqual((evaluated["reference"] as? [String: String])?["path"], "custom")
        let payload = try XCTUnwrap(details["payload"] as? [String: String])
        XCTAssertEqual(payload["checks"], "keep checks")
        XCTAssertEqual(payload["custom"], "keep custom")
    }

    func testPortableCheckFixtureThroughFreshNativeInstances() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/test-checks.json")
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        XCTAssertEqual(fixture["version"] as? Int, 3)
        let datafileObject = try XCTUnwrap(fixture["datafile"])
        let datafileData = try JSONSerialization.data(withJSONObject: datafileObject)
        let datafile = try JSONDecoder().decode(DatafileContent.self, from: datafileData)
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 255)

        var executedAnyCases = 0
        for testCase in cases {
            let name = testCase["name"] as? String ?? "unnamed"
            let diagnostics = CheckDiagnosticCollector()
            let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .fatal, onDiagnostic: { diagnostics.record($0) }))
            let assertion = ["checks": testCase["checks"] as Any]
            let outcome = evaluateAssertionChecksDetailed(
                assertion,
                ownerVariable: testCase["owner"] as? String,
                resolver: NativeCheckResolver(sdk, diagnostics: diagnostics),
                datafile: datafile
            )
            sdk.close()
            if name.lowercased().contains("includesany") { executedAnyCases += 1 }
            XCTAssertEqual(outcome.failures.isEmpty, testCase["passed"] as? Bool, "\(name): \(outcome.failures)")
            XCTAssertEqual(outcome.hadError, testCase["error"] as? Bool ?? false, "\(name): \(outcome.failures)")
        }
        XCTAssertEqual(executedAnyCases, 36)
    }

    func testFeatureChecksValidateBothGettersAndPreserveFatalErrors() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"checks","segments":{},"features":{"checkout":{"bucketBy":"userId","traffic":[]}},"variables":{}}"#)
        let resolver = FeatureCheckResolver()
        let passing: [String: Any] = ["checks": [
            ["feature": "checkout", "variation": "beta"],
            ["and": [
                ["feature": "checkout", "enabled": false],
                ["feature": "checkout", "enabled": false, "variation": "beta"],
            ]],
        ]]
        XCTAssertTrue(evaluateAssertionChecks(passing, ownerVariable: nil, resolver: resolver, datafile: datafile).isEmpty)
        resolver.variation = ""
        XCTAssertTrue(evaluateAssertionChecks(["checks": [["feature": "checkout", "variation": ""]]], ownerVariable: nil, resolver: resolver, datafile: datafile).isEmpty)

        resolver.variation = "beta"
        resolver.calls.removeAll()
        let failing: [String: Any] = ["checks": [["feature": "checkout", "enabled": true, "variation": "wrong"]]]
        let failures = evaluateAssertionChecks(failing, ownerVariable: nil, resolver: resolver, datafile: datafile)
        XCTAssertEqual(resolver.calls, ["enabled:checkout", "variation:checkout"])
        XCTAssertTrue(failures.first?.contains("expected enabled=true, actual enabled=false") == true, "\(failures)")
        XCTAssertTrue(failures.first?.contains("expected variation=\"wrong\", actual variation=\"beta\"") == true, "\(failures)")

        let invalid: [[String: Any]] = [
            ["feature": "checkout"],
            ["feature": "checkout", "enabled": true, "operator": "equals", "value": true],
            ["feature": "checkout", "variation": 1],
            ["feature": "", "enabled": false],
        ]
        for leaf in invalid {
            let assertion: [String: Any] = ["checks": [["or": [["feature": "checkout", "enabled": false], leaf]]]]
            XCTAssertTrue(evaluateAssertionChecksDetailed(assertion, ownerVariable: nil, resolver: resolver, datafile: datafile).hadError, "\(leaf)")
        }

        let missing: [String: Any] = ["checks": [["not": [["feature": "missing", "enabled": false]]]]]
        let missingOutcome = evaluateAssertionChecksDetailed(missing, ownerVariable: nil, resolver: resolver, datafile: datafile)
        XCTAssertTrue(missingOutcome.hadError)
        XCTAssertTrue(missingOutcome.failures.first?.contains("absent from the selected datafile") == true)

        resolver.calls.removeAll()
        resolver.variationError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "native variation failure"])
        let fatal: [String: Any] = ["checks": [["or": [
            ["feature": "checkout", "enabled": true, "variation": "beta"],
            ["feature": "checkout", "variation": "beta"],
        ]]]]
        let outcome = evaluateAssertionChecksDetailed(fatal, ownerVariable: nil, resolver: resolver, datafile: datafile)
        XCTAssertEqual(resolver.calls, ["enabled:checkout", "variation:checkout"])
        XCTAssertTrue(outcome.hadError)
        XCTAssertTrue(outcome.failures.first?.contains("native variation failure") == true, "\(outcome.failures)")
    }

    func testSegmentChecksValidateNestEvaluateAndReportEvidence() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"segment-checks","segments":{},"features":{},"variables":{}}"#)
        let definitions: [String: Any] = [
            "all": ["conditions": "*"],
            "dutch": ["conditions": [["attribute": "country", "operator": "equals", "value": "nl"]]],
            "adult": ["conditions": ["and": [
                ["attribute": "country", "operator": "equals", "value": "nl"],
                ["attribute": "age", "operator": "greaterThanOrEquals", "value": 18],
            ]]],
        ]
        let diagnostics = CheckDiagnosticCollector()
        let prepared = prepareSegmentGates(datafile, definitions: definitions)
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: prepared.datafile, logLevel: .error))
        sdk.setContext(["country": .string("nl"), "age": .int(21)])
        defer { sdk.close() }
        let resolver = NativeCheckResolver(
            sdk,
            diagnostics: diagnostics,
            segmentDefinitions: definitions,
            context: ["country": .string("nl"), "age": .int(21)],
            segmentGates: prepared.gates
        )
        let passing: [String: Any] = ["checks": [
            ["segment": "all", "matches": true],
            ["segment": "dutch", "matches": true],
            ["and": [
                ["segment": "adult", "matches": true],
                ["not": [["segment": "dutch", "matches": false]]],
            ]],
            ["or": [
                ["segment": "dutch", "matches": false],
                ["segment": "adult", "matches": true],
            ]],
        ]]
        XCTAssertTrue(evaluateAssertionChecks(passing, ownerVariable: nil, resolver: resolver, datafile: datafile).isEmpty)

        let failing: [String: Any] = ["checks": [[
            "key": "audience", "description": "Audience is excluded",
            "segment": "dutch", "matches": false,
        ]]]
        let outcome = evaluateAssertionChecksDetailed(failing, ownerVariable: nil, resolver: resolver, datafile: datafile)
        XCTAssertTrue(outcome.failures.first?.contains("segment \"dutch\"") == true, "\(outcome.failures)")
        let details = try XCTUnwrap(outcome.reportErrors.first?["details"] as? [String: Any])
        let evidence = try XCTUnwrap((details["evaluated"] as? [[String: Any]])?.first)
        XCTAssertEqual((evidence["reference"] as? [String: String])?["segment"], "dutch")
        XCTAssertEqual(evidence["property"] as? String, "matches")
        XCTAssertEqual(evidence["operator"] as? String, "equals")
        XCTAssertEqual(evidence["expected"] as? Bool, false)
        XCTAssertEqual(evidence["actual"] as? Bool, true)
        XCTAssertEqual(segmentKeyFromCheckDetails(details), "dutch")

        let missing: [String: Any] = ["checks": [["or": [
            ["segment": "dutch", "matches": true],
            ["segment": "missing", "matches": false],
        ]]]]
        let missingOutcome = evaluateAssertionChecksDetailed(missing, ownerVariable: nil, resolver: resolver, datafile: datafile)
        XCTAssertTrue(missingOutcome.hadError)
        XCTAssertTrue(missingOutcome.failures.first?.contains("segment \"missing\"") == true)

        let invalid: [[String: Any]] = [
            ["segment": "", "matches": true],
            ["segment": "dutch"],
            ["segment": "dutch", "matches": "yes"],
            ["matches": false],
            ["segment": "dutch", "matches": true, "operator": "equals", "value": true],
            ["segment": "dutch", "matches": true, "feature": "checkout"],
            ["segment": "dutch", "matches": true, "target": "other"],
        ]
        for leaf in invalid {
            let invalidOutcome = evaluateAssertionChecksDetailed(["checks": [leaf]], ownerVariable: nil, resolver: resolver, datafile: datafile)
            XCTAssertTrue(invalidOutcome.hadError, "\(leaf)")
        }
    }

    func testSegmentChecksUseRootAndMergedChildContextOutsideTargetDatafile() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"segment-context","segments":{},"features":{},"variables":{"subject":{"type":"string","defaultValue":"ready"}}}"#)
        let definitions: [String: Any] = [
            "dutch": ["conditions": [["attribute": "country", "operator": "equals", "value": "nl"]]],
            "dutch-pro": ["conditions": [
                ["attribute": "country", "operator": "equals", "value": "nl"],
                ["attribute": "plan", "operator": "equals", "value": "pro"],
            ]],
        ]
        let command = TestCommand()
        let options = CLIParser.parse(["test", "--quiet", "--target=thin"])
        let cache = [command.targetDatafileCacheKey(nil, "thin"): datafile]
        let scenario: [String: Any] = [
            "scenario": "segment-context",
            "_segments": definitions,
            "assertions": [[
                "context": ["country": "nl"],
                "target": "thin",
                "at": 0.1,
                "checks": [["segment": "dutch", "matches": true]],
                "children": [[
                    "context": ["plan": "pro"],
                    "stickyVariables": ["subject": "ignored"],
                    "checks": [["segment": "dutch-pro", "matches": true]],
                ]],
            ]],
        ]
        XCTAssertTrue(command.runScenarioTest(scenarioKey: "segment-context", test: scenario, options: options, datafileCache: cache).ok)

        let variable: [String: Any] = [
            "variable": "subject",
            "_segments": definitions,
            "assertions": [[
                "context": ["country": "nl"],
                "target": "thin",
                "expectedValue": "ready",
                "checks": [["segment": "dutch", "matches": true]],
            ]],
        ]
        XCTAssertTrue(command.runGlobalVariableTest(variableKey: "subject", test: variable, options: options, datafileCache: cache).ok)
    }

    func testSegmentValidationDoesNotEvaluateSkippedBranchesOrDuplicateReachedLeaves() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"counts","segments":{},"features":{},"variables":{}}"#)
        let resolver = CountingSegmentResolver(
            available: ["first", "skipped"],
            matches: ["first": true, "skipped": true]
        )
        let assertion: [String: Any] = ["checks": [["or": [
            ["segment": "first", "matches": true],
            ["segment": "skipped", "matches": true],
        ]]]]
        let outcome = evaluateAssertionChecksDetailed(assertion, ownerVariable: nil, resolver: resolver, datafile: datafile)
        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertEqual(resolver.validations, ["first": 1, "skipped": 1])
        XCTAssertEqual(resolver.resolutions, ["first": 1])
    }

    func testNamedCheckMetadataAndSiblingUniqueness() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"named","segments":{},"features":{},"variables":{"subject":{"type":"string","defaultValue":"ready"}}}"#)
        let diagnostics = CheckDiagnosticCollector()
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .error, onDiagnostic: { diagnostics.record($0) }))
        defer { sdk.close() }
        let named: [String: Any] = ["checks": [[
            "key": "status",
            "description": "Status is complete",
            "operator": "equals",
            "value": "wrong",
        ]]]
        let outcome = evaluateAssertionChecksDetailed(named, ownerVariable: "subject", resolver: NativeCheckResolver(sdk, diagnostics: diagnostics), datafile: datafile)
        XCTAssertTrue(outcome.failures.first?.contains("key=\"status\"") == true, "\(outcome.failures)")
        XCTAssertTrue(outcome.failures.first?.contains("left=\"ready\", right=\"wrong\"") == true, "\(outcome.failures)")
        let reportError = try XCTUnwrap(outcome.reportErrors.first)
        XCTAssertEqual(reportError["expected"] as? Bool, true)
        XCTAssertEqual(reportError["actual"] as? Bool, false)
        let details = try XCTUnwrap(reportError["details"] as? [String: Any])
        XCTAssertEqual(details["checkKey"] as? String, "status")
        let evaluated = try XCTUnwrap(details["evaluated"] as? [[String: Any]])
        XCTAssertEqual(evaluated.first?["expected"] as? String, "wrong")
        XCTAssertEqual(evaluated.first?["actual"] as? String, "ready")

        let absent: [String: Any] = ["checks": [[
            "key": "missing-value",
            "path": "absent",
            "operator": "equals",
            "value": "<missing>",
        ]]]
        let absentOutcome = evaluateAssertionChecksDetailed(absent, ownerVariable: "subject", resolver: NativeCheckResolver(sdk, diagnostics: diagnostics), datafile: datafile)
        let absentDetails = try XCTUnwrap(absentOutcome.reportErrors.first?["details"] as? [String: Any])
        let absentTrace = try XCTUnwrap((absentDetails["evaluated"] as? [[String: Any]])?.first)
        XCTAssertEqual(absentTrace["actualMissing"] as? Bool, true)
        XCTAssertEqual(absentTrace["expected"] as? String, "<missing>")
        XCTAssertEqual((absentTrace["actual"] as? [String: String])?["$type"], "undefined")

        let duplicate: [String: Any] = ["checks": [
            ["key": "same", "operator": "equals", "value": "ready"],
            ["key": "same", "operator": "equals", "value": "ready"],
        ]]
        let duplicateOutcome = evaluateAssertionChecksDetailed(duplicate, ownerVariable: "subject", resolver: NativeCheckResolver(sdk, diagnostics: diagnostics), datafile: datafile)
        XCTAssertTrue(duplicateOutcome.hadError)
        XCTAssertTrue(duplicateOutcome.failures.first?.contains("duplicate sibling key") == true)
    }

    func testEmptyChecksValidateAndCompareSupportedContainers() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"empty-checks","segments":{},"features":{},"variables":{"subject":{"type":"object","defaultValue":{}}}}"#)

        func outcome(_ value: AnyValue, _ operation: String, path: Any? = nil) -> CheckAssertionOutcome {
            var leaf: [String: Any] = ["operator": operation]
            if let path { leaf["path"] = path }
            return evaluateAssertionChecksDetailed(
                ["checks": [leaf]],
                ownerVariable: "subject",
                resolver: ValueCheckResolver(value),
                datafile: datafile
            )
        }

        for (value, operation) in [
            (AnyValue.string(""), "empty"),
            (.string(" "), "notEmpty"),
            (.array([]), "empty"),
            (.array([.null]), "notEmpty"),
            (.object([:]), "empty"),
            (.object(["value": .null]), "notEmpty"),
        ] {
            let result = outcome(value, operation)
            XCTAssertFalse(result.hadError, "\(value) \(operation): \(result.failures)")
            XCTAssertTrue(result.failures.isEmpty, "\(value) \(operation): \(result.failures)")
        }

        let nested = outcome(.object(["nested": .object(["items": .array([])])]), "empty", path: "nested.items")
        XCTAssertTrue(nested.failures.isEmpty, "\(nested.failures)")

        for value in [AnyValue.null, .int(0), .bool(false)] {
            for operation in ["empty", "notEmpty"] {
                let result = outcome(value, operation)
                if value == .null {
                    XCTAssertFalse(result.hadError, "\(operation): \(result.failures)")
                } else {
                    XCTAssertTrue(result.hadError, "\(value) \(operation): \(result.failures)")
                }
                XCTAssertFalse(result.failures.isEmpty)
            }
        }

        for operation in ["empty", "notEmpty"] {
            let missing = outcome(.object([:]), operation, path: "missing")
            XCTAssertFalse(missing.hadError, "\(operation): \(missing.failures)")
            XCTAssertFalse(missing.failures.isEmpty)
        }
    }

    func testEmptyCheckErrorsCannotBeSkippedOrInverted() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"empty-check-errors","segments":{},"features":{},"variables":{"subject":{"type":"object","defaultValue":{}}}}"#)
        let validFirst: [String: Any] = ["checks": [["or": [
            ["operator": "empty"],
            ["operator": "empty", "value": "invalid"],
        ]]]]
        let invalidShape = evaluateAssertionChecksDetailed(validFirst, ownerVariable: "subject", resolver: ValueCheckResolver(.object([:])), datafile: datafile)
        XCTAssertTrue(invalidShape.hadError)

        for invalidLeaf in [
            ["operator": "empty", "compareTo": ["variable": "subject"]] as [String: Any],
            ["operator": "notEmpty", "regexFlags": "i"] as [String: Any],
        ] {
            let result = evaluateAssertionChecksDetailed(["checks": [invalidLeaf]], ownerVariable: "subject", resolver: ValueCheckResolver(.object([:])), datafile: datafile)
            XCTAssertTrue(result.hadError, "\(invalidLeaf)")
        }

        let scalarOr: [String: Any] = ["checks": [["or": [
            ["operator": "empty"],
            ["operator": "equals", "value": 0],
        ]]]]
        let orOutcome = evaluateAssertionChecksDetailed(scalarOr, ownerVariable: "subject", resolver: ValueCheckResolver(.int(0)), datafile: datafile)
        XCTAssertTrue(orOutcome.hadError, "\(orOutcome.failures)")

        let scalarNot: [String: Any] = ["checks": [["not": [["operator": "notEmpty"]]]]]
        let notOutcome = evaluateAssertionChecksDetailed(scalarNot, ownerVariable: "subject", resolver: ValueCheckResolver(.bool(false)), datafile: datafile)
        XCTAssertTrue(notOutcome.hadError, "\(notOutcome.failures)")

        let getter = ValueCheckResolver(.object([:]))
        getter.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "getter failed"])
        let getterOutcome = evaluateAssertionChecksDetailed(scalarNot, ownerVariable: "subject", resolver: getter, datafile: datafile)
        XCTAssertTrue(getterOutcome.hadError)
        XCTAssertTrue(getterOutcome.failures.first?.contains("getter failed") == true)
    }

    func testNativeFeatureGetterDiagnosticsCannotSatisfyFalseExpectation() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"bad-feature","segments":{},"features":{"broken":{"bucketBy":"userId","conditions":[{"variable":"source","operator":"semverGreaterThan","value":"1.0.0"}],"traffic":[{"key":"all","segments":"*","percentage":100000,"enabled":true}]}},"variables":{"source":{"type":"string","defaultValue":"invalid"}}}"#)
        let diagnostics = CheckDiagnosticCollector()
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .error, onDiagnostic: { diagnostics.record($0) }))
        defer { sdk.close() }
        let assertion: [String: Any] = ["checks": [["not": [["feature": "broken", "enabled": false]]]]]
        let outcome = evaluateAssertionChecksDetailed(assertion, ownerVariable: nil, resolver: NativeCheckResolver(sdk, diagnostics: diagnostics), datafile: datafile)
        XCTAssertTrue(outcome.hadError, "\(outcome.failures)")
        XCTAssertTrue(outcome.failures.first?.contains("evaluation_error") == true, "\(outcome.failures)")
    }

    func testMalformedJSONGetterDiagnosticFailsNullCheckAtQuietLevel() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"malformed","segments":{},"features":{},"variables":{"source":{"type":"json","defaultValue":"{"}}}"#)
        let diagnostics = CheckDiagnosticCollector()
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .error, onDiagnostic: { diagnostics.record($0) }))
        defer { sdk.close() }
        func assertError(_ name: String, _ resolver: any CheckVariableResolver) {
            for operation in ["isNull", "empty", "notEmpty"] {
                let assertion: [String: Any] = ["checks": [["operator": operation]]]
                let outcome = evaluateAssertionChecksDetailed(assertion, ownerVariable: "source", resolver: resolver, datafile: datafile)
                XCTAssertTrue(outcome.hadError, "\(name) \(operation)")
                XCTAssertEqual(outcome.failures.count, 1, "\(name) \(operation)")
                XCTAssertTrue(outcome.failures.first?.contains("evaluation_error") == true, "\(name) \(operation): \(outcome.failures)")
            }
        }
        assertError("parent", NativeCheckResolver(sdk, diagnostics: diagnostics))
        let child = sdk.spawn()
        defer { child.close() }
        assertError("child", NativeCheckResolver(child, diagnostics: diagnostics))
    }

    func testNativeRunnerDispatchesScenariosAndReturnsFailureExitCode() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("featurevisor-swift-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let npx = temp.appendingPathComponent("npx")
        let script = #"""
        #!/bin/sh
        case "$*" in
          *"config --json"*) printf '%s\n' '{"environments":["production"]}' ;;
          *"list --segments --json"*) printf '%s\n' '[]' ;;
          *"list --targets --json"*) printf '%s\n' '[]' ;;
          *"list --tests"*)
            case "$*" in *"--entityType=scenario"*) ;; *) exit 13 ;; esac
            case "$*" in *"--execution-protocol"*) ;; *) exit 15 ;; esac
            if [ "$RUNNER_CASE" = malformed ]; then printf '%s\n' '{"kind":"featurevisor.test-execution","schemaVersion":1,"tests":[{"key":"scenario-native","scenario":"native","assertions":[{"environment":"production"}]}]}'; exit 0; fi
            if [ "$RUNNER_CASE" = empty ]; then printf '%s\n' '{"kind":"featurevisor.test-execution","schemaVersion":1,"tests":[{"key":"scenario-native","scenario":"native","assertions":[]}]}'; exit 0; fi
            if [ "$RUNNER_CASE" = mixed ]; then printf '%s\n' '{"kind":"featurevisor.test-execution","schemaVersion":1,"tests":[{"key":"scenario-native","scenario":"native","variable":"subject","assertions":[{"environment":"production","checks":[{"variable":"subject","operator":"equals","value":"ready"}]}]}]}'; exit 0; fi
            if [ "$RUNNER_CASE" = failure ]; then expected=wrong; else expected=ready; fi
            printf '{"kind":"featurevisor.test-execution","schemaVersion":1,"tests":[{"key":"scenario-native","scenario":"native","assertions":[{"environment":"production","description":"native scenario","checks":[{"variable":"subject","operator":"equals","value":"%s"}],"children":[{"stickyVariables":{"subject":"child"},"checks":[{"variable":"subject","operator":"equals","value":"child"}]}]}]}]}\n' "$expected" ;;
          *"build --environment=production --json"*) printf '%s\n' '{"schemaVersion":"2","revision":"1","segments":{},"features":{},"variables":{"subject":{"type":"string","defaultValue":"ready"}}}' ;;
          *) exit 14 ;;
        esac
        """#
        try script.write(to: npx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npx.path)
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(temp.path):\(oldPath)", 1)
        defer { setenv("PATH", oldPath, 1); unsetenv("RUNNER_CASE") }

        let options = CLIParser.parse(["test", "--projectDirectoryPath=\(temp.path)", "--entityType=scenario", "--onlyFailures"])
        XCTAssertEqual(TestCommand().run(options), 0)
        setenv("RUNNER_CASE", "failure", 1)
        XCTAssertEqual(TestCommand().run(options), 1)
        for malformed in ["malformed", "empty", "mixed"] {
            setenv("RUNNER_CASE", malformed, 1)
            XCTAssertEqual(TestCommand().run(options), 1, malformed)
        }
    }

    func testExecutionProtocolValidationRejectsMalformedDocuments() throws {
        XCTAssertEqual(try parseTestExecutionProtocol(["kind": "featurevisor.test-execution", "schemaVersion": 1, "tests": [[:]]]).count, 1)
        let invalid: [Any] = [
            [],
            ["schemaVersion": 1, "tests": []],
            ["kind": NSNull(), "schemaVersion": 1, "tests": []],
            ["kind": "wrong", "schemaVersion": 1, "tests": []],
            ["kind": "featurevisor.test-execution", "tests": []],
            ["kind": "featurevisor.test-execution", "schemaVersion": NSNull(), "tests": []],
            ["kind": "featurevisor.test-execution", "schemaVersion": true, "tests": []],
            ["kind": "featurevisor.test-execution", "schemaVersion": "1", "tests": []],
            ["kind": "featurevisor.test-execution", "schemaVersion": 2, "tests": []],
            ["kind": "featurevisor.test-execution", "schemaVersion": 1, "tests": NSNull()],
            ["kind": "featurevisor.test-execution", "schemaVersion": 1, "tests": [1]],
        ]
        for document in invalid {
            XCTAssertThrowsError(try parseTestExecutionProtocol(document), "\(document)")
        }
    }

    func testPreflightValidatesSkippedBranchesAndChildrenWithoutResolving() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"1","segments":{},"features":{},"variables":{"present":{"type":"string","defaultValue":"ready"}}}"#)
        let assertion: [String: Any] = [
            "checks": [["or": [
                ["variable": "present", "operator": "equals", "value": "ready"],
                ["variable": "missing", "operator": "equals", "value": "unused"],
            ]]],
            "children": [["checks": [["variable": "present", "operator": "equals", "compareTo": ["variable": "alsoMissing"]]]]],
        ]
        XCTAssertThrowsError(try preflightExpandedAssertionChecks(assertion, ownerVariable: nil, datafile: datafile, segmentDefinitions: [:]))
    }

    func testRepeatedTargets() {
        let opts = CLIParser.parse(["benchmark", "--target=web", "--target=mobile", "--target=web"])
        XCTAssertEqual(opts.targets, ["web", "mobile"])
    }

    func testTargetDatafileCacheKey() {
        let command = TestCommand()

        XCTAssertEqual(command.targetDatafileCacheKey(nil, "checkout"), #"[null,"checkout"]"#)
        XCTAssertEqual(command.targetDatafileCacheKey("production", "checkout"), #"["production","checkout"]"#)
    }

    func testTargetAssertionSelectsTargetDatafile() {
        let command = TestCommand()
        let cache = [
            #"["production",null]"#: DatafileContent(schemaVersion: "2", revision: "base", segments: [:], features: [:]),
            #"["production","checkout"]"#: DatafileContent(schemaVersion: "2", revision: "target", segments: [:], features: [:]),
        ]

        XCTAssertEqual(
            command.datafileCacheKeyForAssertion(
                ["environment": "production", "target": "checkout"],
                datafileCache: cache
            ),
            #"["production","checkout"]"#
        )
    }

    func testTargetAssertionDoesNotFallBackToBaseDatafile() {
        let command = TestCommand()
        let cache = [
            #"["production",null]"#: DatafileContent(schemaVersion: "2", revision: "base", segments: [:], features: [:]),
        ]

        XCTAssertEqual(
            command.datafileCacheKeyForAssertion(
                ["environment": "production", "target": "checkout"],
                datafileCache: cache
            ),
            #"["production","checkout"]"#
        )
    }

    func testNoEnvironmentTargetAssertionSelectsTargetDatafile() {
        let command = TestCommand()
        let cache = [
            #"[null,null]"#: DatafileContent(schemaVersion: "2", revision: "base", segments: [:], features: [:]),
            #"[null,"checkout"]"#: DatafileContent(schemaVersion: "2", revision: "target", segments: [:], features: [:]),
        ]

        XCTAssertEqual(
            command.datafileCacheKeyForAssertion(
                ["target": "checkout"],
                datafileCache: cache
            ),
            #"[null,"checkout"]"#
        )
    }

    func testDefaultCommandShowsHelp() {
        let code = CLI().run(args: [])
        XCTAssertEqual(code, 0)
    }
}
