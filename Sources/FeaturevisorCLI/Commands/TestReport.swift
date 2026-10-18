import Foundation
import Featurevisor

func parseTestExecutionProtocol(_ raw: Any) throws -> [[String: Any]] {
    guard let document = raw as? [String: Any] else {
        throw reportError("Test execution protocol output must be an object")
    }
    guard document["kind"] as? String == "featurevisor.test-execution" else {
        throw reportError("Test execution protocol kind must be featurevisor.test-execution")
    }
    guard let version = document["schemaVersion"] as? NSNumber,
          String(cString: version.objCType) != "c",
          version.doubleValue == 1,
          version.doubleValue.rounded() == version.doubleValue else {
        throw reportError("Test execution protocol schemaVersion must be the number 1")
    }
    guard let rawTests = document["tests"] as? [Any],
          rawTests.allSatisfy({ $0 is [String: Any] }) else {
        throw reportError("Test execution protocol tests must be an array of objects")
    }
    return rawTests.map { $0 as! [String: Any] }
}

final class TestCoverageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: Any]] = [:]

    func record(evaluation: Evaluation, set: String, environment: String?, target: String?) {
        var base: [String: Any] = [
            "set": set.isEmpty ? NSNull() : set,
            "environment": environment ?? NSNull(),
            "target": target ?? NSNull(),
        ]
        if let featureKey = evaluation.featureKey { base["featureKey"] = featureKey }
        if let variableKey = evaluation.variableKey { base["variableKey"] = variableKey }
        if let ruleKey = evaluation.ruleKey { base["ruleKey"] = ruleKey }
        if let variation = evaluation.variation?.value { base["variation"] = variation }
        var paths = evaluation.variableOverridePaths ?? []
        if paths.isEmpty, let path = evaluation.variableOverridePath, !path.isEmpty { paths = [path] }
        if paths.isEmpty, let key = evaluation.variableOverrideKey { paths = [[key]] }
        guard base["ruleKey"] != nil || !paths.isEmpty || evaluation.variableOverrideIndex != nil else { return }
        if paths.isEmpty {
            if let index = evaluation.variableOverrideIndex { base["overrideIndex"] = index }
            add(base)
        } else {
            for path in paths {
                var entry = base
                entry["overridePath"] = path
                add(entry)
            }
        }
    }

    func selections() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.sorted().compactMap { values[$0] }
    }

    private func add(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        let key = String(decoding: data, as: UTF8.self)
        lock.lock()
        values[key] = value
        lock.unlock()
    }
}

private struct ReportCounts {
    var specsPassed = 0
    var specsFailed = 0
    var assertionsPassed = 0
    var assertionsFailed = 0
    var entitySpecsPassed = 0
    var entitySpecsFailed = 0
    var entityAssertionsPassed = 0
    var entityAssertionsFailed = 0
    var scenarioSpecsPassed = 0
    var scenarioSpecsFailed = 0
    var scenarioCasesPassed = 0
    var scenarioCasesFailed = 0

    var json: [String: Any] {
        [
            "specs": ["passed": specsPassed, "failed": specsFailed],
            "assertions": ["passed": assertionsPassed, "failed": assertionsFailed],
            "entitySpecs": ["passed": entitySpecsPassed, "failed": entitySpecsFailed],
            "entityAssertions": ["passed": entityAssertionsPassed, "failed": entityAssertionsFailed],
            "scenarioSpecs": ["passed": scenarioSpecsPassed, "failed": scenarioSpecsFailed],
            "scenarioCases": ["passed": scenarioCasesPassed, "failed": scenarioCasesFailed],
        ]
    }
}

private final class SwiftTestReport {
    var passed = true
    var counts = ReportCounts()
    var results: [[String: Any]] = []
    var errors: [[String: Any]] = []
    var uncovered: [[String: Any]]?
    var coverage: [String: Any]?

    func append(spec: [String: Any], type: String, passed specPassed: Bool, cases: [[String: Any]]) {
        results.append(spec)
        if specPassed {
            counts.specsPassed += 1
            if type == "scenario" { counts.scenarioSpecsPassed += 1 } else { counts.entitySpecsPassed += 1 }
        } else {
            passed = false
            counts.specsFailed += 1
            if type == "scenario" { counts.scenarioSpecsFailed += 1 } else { counts.entitySpecsFailed += 1 }
        }
        for testCase in cases {
            if testCase["passed"] as? Bool == true {
                counts.assertionsPassed += 1
                if type == "scenario" { counts.scenarioCasesPassed += 1 } else { counts.entityAssertionsPassed += 1 }
            } else {
                counts.assertionsFailed += 1
                if type == "scenario" { counts.scenarioCasesFailed += 1 } else { counts.entityAssertionsFailed += 1 }
            }
        }
    }

    func append(error: Error) {
        passed = false
        errors.append(["message": error.localizedDescription])
    }

    var json: [String: Any] {
        var value: [String: Any] = [
            "schemaVersion": 1,
            "runner": "swift",
            "passed": passed,
            "summary": counts.json,
            "results": results,
            "errors": errors,
        ]
        if let uncovered { value["uncovered"] = uncovered }
        if let coverage { value["coverage"] = coverage }
        return value
    }
}

extension TestCommand {
    func run(_ options: CLIOptions) -> Int32 {
        let report = SwiftTestReport()
        let collector = options.coverage ? TestCoverageCollector() : nil
        do {
            let rootConfig = try reportJSON(options.projectDirectoryPath, ["config", "--json"]) as? [String: Any]
            guard let rootConfig else { throw reportError("Configuration output was not an object") }
            let sets = try CLIHelpers.projectSets(options: options, config: rootConfig)
            var exactCaseMatched = false
            var exactCaseErrors: [Error] = []
            for set in sets {
                var current = options
                current.set = set
                current.silentTestOutput = true
                current.coverageSink = collector
                let tests: [[String: Any]]
                do {
                    tests = try reportTests(options: current)
                } catch {
                    if !options.caseID.isEmpty, sets.count > 1 {
                        exactCaseErrors.append(error)
                        continue
                    }
                    throw error
                }
                if !options.caseID.isEmpty, tests.isEmpty { continue }
                if !options.caseID.isEmpty { exactCaseMatched = true }
                let segments = try reportSegments(options: current)
                let cache = try reportDatafileCache(options: current, config: rootConfig)
                for test in tests {
                    try appendReportTest(test, options: current, segments: segments, cache: cache, report: report)
                }
                if options.uncovered {
                    if report.uncovered == nil { report.uncovered = [] }
                    report.uncovered?.append(try reportUncovered(options: current))
                }
            }
            if !options.caseID.isEmpty, !exactCaseMatched {
                if let error = exactCaseErrors.first { throw error }
                throw reportError("No test case matched --case=\(options.caseID)")
            }
        } catch {
            report.append(error: error)
        }
        if let collector {
            report.coverage = ["mode": "observed-selections", "selections": collector.selections()]
        }
        if options.json {
            writeReportJSON(report.json, pretty: options.pretty)
        } else {
            writeHumanReport(report.json, onlyFailures: options.onlyFailures)
        }
        return report.passed ? 0 : 1
    }

    private func appendReportTest(
        _ test: [String: Any],
        options: CLIOptions,
        segments: [String: Any],
        cache: [String: DatafileContent],
        report: SwiftTestReport
    ) throws {
        let discriminators = ["feature", "segment", "variable", "scenario"].filter { test.keys.contains($0) }
        guard discriminators.count == 1, let type = discriminators.first, let entityKey = test[type] as? String else {
            throw reportError("test must contain exactly one of feature, segment, variable, or scenario")
        }
        let execution: TestExecutionResult
        if type == "feature" {
            execution = runFeatureTest(featureKey: entityKey, test: test, options: options, datafileCache: cache)
        } else if type == "variable" {
            execution = runGlobalVariableTest(variableKey: entityKey, test: test, options: options, datafileCache: cache)
        } else if type == "scenario" {
            execution = runScenarioTest(scenarioKey: entityKey, test: test, options: options, datafileCache: cache)
        } else {
            execution = runSegmentTest(segmentKey: entityKey, test: test, segmentsByKey: segments, options: options, datafileCache: cache)
        }
        let metadata = test["_test"] as? [String: Any]
        let setValue: Any = metadata?["set"] ?? (options.set.isEmpty ? NSNull() : options.set)
        let source = metadata?["source"] as? String ?? test["key"] as? String ?? ""
        let storageKey = test["key"] as? String ?? entityKey
        var cases: [[String: Any]] = []
        for index in execution.reports.indices {
            let assertion = index < execution.assertions.count ? execution.assertions[index] : [:]
            let assertionReport = execution.reports[index]
            let caseMetadata = assertion["_case"] as? [String: Any]
            let id = caseMetadata?["id"] as? String ?? fallbackCaseID(set: setValue, type: type, key: storageKey, index: index)
            let authoredAssertionIndex = (caseMetadata?["assertionIndex"] as? NSNumber)?.intValue ?? index
            let errors = structuredReportErrors(assertionReport.errors, type: type, assertionIndex: authoredAssertionIndex, failed: !assertionReport.passed)
            var rerunArgs = ["test", "--case=\(id)"]
            if !options.projectDirectoryPath.isEmpty { rerunArgs.append("--projectDirectoryPath=\(options.projectDirectoryPath)") }
            if let set = setValue as? String { rerunArgs.append("--set=\(set)") }
            rerunArgs.append(contentsOf: options.targets.map { "--target=\($0)" })
            cases.append([
                "id": id,
                "description": assertion["description"] as? String ?? assertionReport.description,
                "environment": assertion["environment"] as? String ?? NSNull(),
                "target": assertion["target"] as? String ?? NSNull(),
                "context": assertion["context"] as? [String: Any] ?? [:],
                "matrixValues": caseMetadata?["matrixValues"] as? [String: Any] ?? [:],
                "passed": assertionReport.passed,
                "errors": errors,
                "rerun": ["command": "swift run featurevisor", "args": rerunArgs],
            ])
        }
        let spec: [String: Any] = [
            "type": type,
            "key": entityKey,
            "source": source,
            "set": setValue,
            "passed": execution.ok,
            "cases": cases,
        ]
        report.append(spec: spec, type: type, passed: execution.ok, cases: cases)
    }

    private func reportTests(options: CLIOptions) throws -> [[String: Any]] {
        var args = ["list", "--tests", "--execution-protocol", "--apply-matrix", "--execution-metadata", "--json"]
        if !options.caseID.isEmpty { args.append("--case=\(options.caseID)") }
        if !options.keyPattern.isEmpty { args.append("--keyPattern=\(options.keyPattern)") }
        if !options.assertionPattern.isEmpty { args.append("--assertionPattern=\(options.assertionPattern)") }
        if !options.entityType.isEmpty { args.append("--entityType=\(options.entityType)") }
        if !options.set.isEmpty { args.append("--set=\(options.set)") }
        return try parseTestExecutionProtocol(try reportJSON(options.projectDirectoryPath, args))
    }

    private func reportSegments(options: CLIOptions) throws -> [String: Any] {
        var args = ["list", "--segments", "--json"]
        if !options.set.isEmpty { args.append("--set=\(options.set)") }
        guard let values = try reportJSON(options.projectDirectoryPath, args) as? [[String: Any]] else {
            throw reportError("Segment listing output was not an array")
        }
        return Dictionary(uniqueKeysWithValues: values.compactMap { value in
            (value["key"] as? String).map { ($0, value as Any) }
        })
    }

    private func reportTargetKeys(options: CLIOptions) throws -> [String] {
        var args = ["list", "--targets", "--json"]
        if !options.set.isEmpty { args.append("--set=\(options.set)") }
        guard let values = try reportJSON(options.projectDirectoryPath, args) as? [[String: Any]] else {
            throw reportError("Target listing output was not an array")
        }
        return values.compactMap { $0["key"] as? String }
    }

    private func reportDatafileCache(options: CLIOptions, config: [String: Any]) throws -> [String: DatafileContent] {
        let environments = CLIHelpers.stringArray(config["environments"])
        let environmentValues: [String?] = environments.isEmpty ? [nil] : environments.map(Optional.some)
        let availableTargets = try reportTargetKeys(options: options)
        if let unknown = options.targets.first(where: { !availableTargets.contains($0) }) {
            throw reportError("Unknown target \"\(unknown)\". Available targets: \(availableTargets.joined(separator: ", "))")
        }
        let targets = options.targets.isEmpty ? availableTargets : options.targets
        var cache: [String: DatafileContent] = [:]
        for environment in environmentValues {
            cache[datafileCacheKey(environment)] = try reportDatafile(options: options, environment: environment, target: nil)
            for target in targets {
                cache[targetDatafileCacheKey(environment, target)] = try reportDatafile(options: options, environment: environment, target: target)
            }
        }
        return cache
    }

    private func reportDatafile(options: CLIOptions, environment: String?, target: String?) throws -> DatafileContent {
        var args = ["build"]
        if let environment { args.append("--environment=\(environment)") }
        if let inflate = options.inflate { args.append("--inflate=\(inflate)") }
        if let target { args.append("--target=\(target)") }
        if !options.set.isEmpty { args.append("--set=\(options.set)") }
        args.append("--json")
        let result = FeaturevisorProcess.run(projectDirectoryPath: options.projectDirectoryPath, args: args)
        guard result.code == 0 else { throw reportError(processMessage(result, args: args)) }
        do { return try DatafileContent.fromJSON(result.stdout) }
        catch { throw reportError("Could not parse datafile JSON: \(error.localizedDescription)") }
    }

    private func reportUncovered(options: CLIOptions) throws -> [String: Any] {
        func keys(_ entity: String) throws -> [String] {
            var args = ["list", "--\(entity)", "--without-tests", "--json"]
            if !options.set.isEmpty { args.append("--set=\(options.set)") }
            guard let values = try reportJSON(options.projectDirectoryPath, args) as? [[String: Any]] else {
                throw reportError("Uncovered \(entity) output was not an array")
            }
            return values.compactMap { $0["key"] as? String }.sorted()
        }
        return [
            "set": options.set.isEmpty ? NSNull() : options.set,
            "features": try keys("features"),
            "variables": try keys("variables"),
        ]
    }

}

private func reportJSON(_ project: String, _ args: [String]) throws -> Any {
    let result = FeaturevisorProcess.run(projectDirectoryPath: project, args: args)
    guard result.code == 0 else { throw reportError(processMessage(result, args: args)) }
    guard let data = result.stdout.data(using: .utf8) else { throw reportError("Command output was not UTF-8") }
    do { return try JSONSerialization.jsonObject(with: data) }
    catch { throw reportError("Could not parse JSON from npx featurevisor \(args.joined(separator: " ")): \(error.localizedDescription)") }
}

private func processMessage(_ result: ProcessResult, args: [String]) -> String {
    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
    return "Command failed: npx featurevisor \(args.joined(separator: " "))\(detail.isEmpty ? "" : "\n\(detail)")"
}

private func reportError(_ message: String) -> NSError {
    NSError(domain: "FeaturevisorCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func fallbackCaseID(set: Any, type: String, key: String, index: Int) -> String {
    let value: [Any] = [set, type, key, index, NSNull()]
    let data = try? JSONSerialization.data(withJSONObject: value)
    return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

func expectationReportError(type: String, path: [Any], expected: Any?, actual: Any?) -> [String: Any] {
    [
        "message": "\(type) expectation did not match", "type": type, "path": path,
        "expected": expected ?? NSNull(), "actual": actual ?? NSNull(),
    ]
}

func structuredReportErrors(_ originals: [[String: Any]], type: String, assertionIndex: Int, failed: Bool) -> [[String: Any]] {
    if originals.isEmpty { return failed ? [["message": "Native assertion failed"]] : [] }
    return originals.map { original in
        var error = original
        let base: [Any] = type == "scenario" ? [] : ["assertions", assertionIndex]
        if let localPath = error["path"] as? [Any] {
            error["path"] = base + localPath
        }
        if var details = error["details"] as? [String: Any], let evaluated = details["evaluated"] as? [[String: Any]] {
            var traceBase = base
            if let childIndex = details["childIndex"] as? Int { traceBase += ["children", childIndex] }
            details["evaluated"] = evaluated.map { originalTrace in
                var trace = originalTrace
                if let path = trace["path"] as? [Any] {
                    trace["path"] = traceBase + ["checks"] + path
                }
                return trace
            }
            error["details"] = details
        }
        if error["type"] as? String == "check", error["expected"] as? Bool == true, error["actual"] as? Bool == false {
            error["message"] = "Check did not match"
        }
        return error
    }
}

private func writeReportJSON(_ report: [String: Any], pretty: Bool) {
    let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: options) else { return }
    print(String(decoding: data, as: UTF8.self))
}

private func writeHumanReport(_ report: [String: Any], onlyFailures: Bool) {
    let results = report["results"] as? [[String: Any]] ?? []
    for spec in results {
        if onlyFailures, spec["passed"] as? Bool == true { continue }
        print("\nTesting: \(spec["source"] as? String ?? "")")
        let type = spec["type"] as? String ?? "entity"
        let key = spec["key"] as? String ?? ""
        print("  \(type) \"\(key)\":")
        for (caseIndex, testCase) in (spec["cases"] as? [[String: Any]] ?? []).enumerated() {
            if onlyFailures, testCase["passed"] as? Bool == true { continue }
            let passed = testCase["passed"] as? Bool == true
            print("  \(passed ? "✔" : "✘") \(humanCaseLabel(testCase, index: caseIndex))")
            if !passed {
                for error in testCase["errors"] as? [[String: Any]] ?? [] {
                    var label = humanExpectationError(error)
                    if error["type"] as? String == "check", let path = error["path"] as? [Any] {
                        label = reportPath(path)
                        if let details = error["details"] as? [String: Any] {
                            if let key = details["checkKey"] as? String { label += " \"\(key)\"" }
                            if let description = details["checkDescription"] as? String { label += ": \(description)" }
                            if let segment = segmentKeyFromCheckDetails(details) { label += " [segment \"\(segment)\"]" }
                        }
                        label += ": \(humanCheckMessage(error["message"] as? String ?? ""))"
                    }
                    print("      ✘ \(label)")
                }
                if let rerun = testCase["rerun"] as? [String: Any], let command = rerun["command"] as? String, let args = rerun["args"] as? [String] {
                    print("      Rerun (POSIX shell): \(command) \(args.map(shellQuote).joined(separator: " "))")
                }
            }
        }
    }
    let summary = report["summary"] as? [String: [String: Int]] ?? [:]
    print("")
    for (key, label) in [("entitySpecs", "Entity specs"), ("entityAssertions", "Entity assertions"), ("scenarioSpecs", "Scenario specs"), ("scenarioCases", "Scenario cases"), ("assertions", "Total cases")] {
        let value = summary[key] ?? [:]
        print("\(label): \(value["passed"] ?? 0) passed, \(value["failed"] ?? 0) failed")
    }
    if let uncovered = report["uncovered"] as? [[String: Any]] {
        print("\nDefinitions without associated specs (not evaluation coverage):")
        for entry in uncovered {
            if let set = entry["set"] as? String { print("  Set: \(set)") }
            let features = entry["features"] as? [String] ?? []
            let variables = entry["variables"] as? [String] ?? []
            print("  Features: \(features.isEmpty ? "none" : features.joined(separator: ", "))")
            print("  Global variables: \(variables.isEmpty ? "none" : variables.joined(separator: ", "))")
        }
    }
    if let coverage = report["coverage"] as? [String: Any] {
        print("\nObserved rule and override selections (not branch coverage):")
        let selections = coverage["selections"] as? [[String: Any]] ?? []
        if selections.isEmpty { print("  No selections observed") }
        for selection in selections { print("  \(humanCoverageSelection(selection))") }
    }
    if let errors = report["errors"] as? [[String: Any]] { for error in errors { fputs((error["message"] as? String ?? "") + "\n", stderr) } }
    print("")
}

func segmentKeyFromCheckDetails(_ details: [String: Any]) -> String? {
    guard let evaluated = details["evaluated"] as? [[String: Any]] else { return nil }
    for trace in evaluated {
        if let reference = trace["reference"] as? [String: Any], let segment = reference["segment"] as? String {
            return segment
        }
    }
    return nil
}

private func reportPath(_ path: [Any]) -> String {
    var value = ""
    for part in path {
        if let index = part as? Int { value += "[\(index + 1)]" }
        else if let number = part as? NSNumber { value += "[\(number.intValue + 1)]" }
        else if let property = part as? String { value += value.isEmpty ? property : ".\(property)" }
    }
    return value
}

private func humanCaseLabel(_ testCase: [String: Any], index: Int) -> String {
    let description = testCase["description"] as? String ?? ""
    let label = description.isEmpty ? "assertion \(index + 1)" : description
    var details: [String] = []
    if let values = testCase["matrixValues"] as? [String: Any], !values.isEmpty {
        let formatted = values.keys.sorted().map { key -> String in
            let value = values[key] ?? NSNull()
            let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed, .sortedKeys])
            let encoded = data.map { String(decoding: $0, as: UTF8.self) } ?? "[null]"
            return "\(key)=\(String(encoded.dropFirst().dropLast()))"
        }
        details.append("matrix \(formatted.joined(separator: ", "))")
    }
    if let target = testCase["target"] as? String, !target.isEmpty { details.append("target \(target)") }
    return details.isEmpty ? label : "\(label) (\(details.joined(separator: "; ")))"
}

func humanExpectationError(_ error: [String: Any]) -> String {
    guard let path = error["path"] as? [Any], error.keys.contains("expected") else {
        return error["message"] as? String ?? ""
    }
    var offset = 0
    if path.count > 1, path[0] as? String == "assertions" { offset = 2 }
    var prefix = ""
    if path.count > offset + 1, path[offset] as? String == "children",
       let child = path[offset + 1] as? Int {
        prefix = "Child \(child + 1), "
        offset += 2
    }
    guard offset < path.count else { return error["message"] as? String ?? "" }
    return "\(prefix)\(reportPath(Array(path[offset...])))" +
        ": expected \(humanValue(error["expected"])), received \(humanValue(error["actual"]))"
}

func humanCheckMessage(_ message: String) -> String {
    message.replacingOccurrences(
        of: #"^(?:children\[[0-9]+\]\.)?checks\[[0-9]+\].*? (?:failed|error):\s*"#,
        with: "",
        options: .regularExpression
    ).replacingOccurrences(
        of: #"^(?:children\[[0-9]+\]\.)?checks\[[0-9]+\]:\s*"#,
        with: "",
        options: .regularExpression
    )
}

private func humanValue(_ value: Any?) -> String {
    guard let value else { return "undefined" }
    if let string = value as? String { return string }
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
        return String(decoding: data, as: UTF8.self)
    }
    return String(describing: value)
}

private func humanCoverageSelection(_ selection: [String: Any]) -> String {
    let feature = selection["featureKey"] as? String
    let variable = selection["variableKey"] as? String
    let owner = feature.map { "feature \($0)" } ?? "global"
    let subject = variable.map { ", variable \($0)" } ?? ""
    let variation = (selection["variation"] as? String).map { ", variation \($0)" } ?? ""
    let rule = (selection["ruleKey"] as? String).map { ", rule \($0)" } ?? ""
    let path = (selection["overridePath"] as? [Any]).map { ", override \(reportPath($0))" } ?? ""
    let index = (selection["overrideIndex"] as? Int).map { ", override \($0 + 1)" } ?? ""
    return "\(owner)\(subject)\(variation)\(rule)\(path)\(index)"
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
