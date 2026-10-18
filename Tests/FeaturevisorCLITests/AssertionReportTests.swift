import Foundation
import XCTest
import Featurevisor
@testable import FeaturevisorCLI

final class AssertionReportTests: XCTestCase {
    func testOrdinaryFailuresKeepTypesAuthoredPathsAndValues() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"reports","segments":{},"features":{"subject":{"bucketBy":"userId","variablesSchema":{"a.b":{"type":"object","defaultValue":{"actual":0}}},"traffic":[{"key":"all","segments":"*","percentage":100000,"enabled":true}]}},"variables":{"subject":{"type":"object","defaultValue":{"actual":0}}}}"#)
        let command = TestCommand()
        var options = CLIOptions()
        options.silentTestOutput = true
        let cache = [command.datafileCacheKey(nil): datafile]
        var feature: [String: Any] = [
            "expectedToBeEnabled": false, "expectedVariation": "café 日本 🚀",
            "expectedVariables": ["a.b": ["expected": false]],
            "expectedEvaluations": [
                "flag": ["reason": "wrong"], "variation": ["reason": "wrong"],
                "variables": ["a.b": ["reason": "wrong"]],
            ],
        ]
        feature["children"] = [feature]
        let result = command.runFeatureTest(featureKey: "subject", test: ["assertions": [feature]], options: options, datafileCache: cache)
        XCTAssertFalse(result.ok)
        let errors = structuredReportErrors(try XCTUnwrap(result.reports.first).errors, type: "feature", assertionIndex: 7, failed: true)
        XCTAssertEqual(errors.count, 12)
        for base: [Any] in [["assertions", 7], ["assertions", 7, "children", 0]] {
            try assertError(errors, type: "flag", path: base + ["expectedToBeEnabled"], expected: false, actual: true)
            try assertError(errors, type: "variation", path: base + ["expectedVariation"], expected: "café 日本 🚀", actual: NSNull())
            try assertError(errors, type: "variable", path: base + ["expectedVariables", "a.b"], expected: ["expected": false], actual: ["actual": 0])
            for path: [Any] in [["expectedEvaluations", "flag", "reason"], ["expectedEvaluations", "variation", "reason"], ["expectedEvaluations", "variables", "a.b", "reason"]] {
                let error = try XCTUnwrap(errors.first { sameJSON($0["path"], base + path) })
                XCTAssertEqual(error["type"] as? String, "evaluation")
                XCTAssertEqual(error["expected"] as? String, "wrong")
                XCTAssertNotEqual(error["actual"] as? String, "wrong")
                XCTAssertNotNil(error["actual"])
            }
        }
        let global: [String: Any] = [
            "expectedValue": NSNull(), "expectedEvaluation": ["variableValue": false],
            "checks": [["path": "actual", "operator": "equals", "value": 1]],
            "children": [["expectedValue": NSNull(), "expectedEvaluation": ["variableValue": false]]],
        ]
        let globalResult = command.runGlobalVariableTest(variableKey: "subject", test: ["assertions": [global]], options: options, datafileCache: cache)
        XCTAssertFalse(globalResult.ok)
        let globalErrors = structuredReportErrors(try XCTUnwrap(globalResult.reports.first).errors, type: "variable", assertionIndex: 9, failed: true)
        XCTAssertEqual(globalErrors.count, 5)
        for base: [Any] in [["assertions", 9], ["assertions", 9, "children", 0]] {
            try assertError(globalErrors, type: "variable", path: base + ["expectedValue"], expected: NSNull(), actual: ["actual": 0])
            try assertError(globalErrors, type: "evaluation", path: base + ["expectedEvaluation", "variableValue"], expected: false, actual: ["actual": 0])
        }
        let segment = command.runSegmentTest(segmentKey: "all", test: ["assertions": [["expectedToMatch": false]]], segmentsByKey: ["all": ["conditions": "*"]], options: options)
        XCTAssertFalse(segment.ok)
        let segmentErrors = structuredReportErrors(try XCTUnwrap(segment.reports.first).errors, type: "segment", assertionIndex: 3, failed: true)
        try assertError(segmentErrors, type: "segment", path: ["assertions", 3, "expectedToMatch"], expected: false, actual: true)
    }

    private func assertError(_ errors: [[String: Any]], type: String, path: [Any], expected: Any, actual: Any, file: StaticString = #filePath, line: UInt = #line) throws {
        let error = try XCTUnwrap(errors.first { sameJSON($0["path"], path) }, "Missing path \(path)", file: file, line: line)
        XCTAssertEqual(error["type"] as? String, type, file: file, line: line)
        XCTAssertTrue(sameJSON(error["expected"], expected), "Incorrect expected value: \(error)", file: file, line: line)
        XCTAssertTrue(sameJSON(error["actual"], actual), "Incorrect actual value: \(error)", file: file, line: line)
        XCTAssertEqual(error["message"] as? String, "\(type) expectation did not match", file: file, line: line)
        let raw = try JSONSerialization.data(withJSONObject: error)
        let decoded = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        XCTAssertTrue(decoded.keys.contains("expected"), file: file, line: line)
        XCTAssertTrue(decoded.keys.contains("actual"), file: file, line: line)
    }

    private func sameJSON(_ left: Any?, _ right: Any) -> Bool {
        guard let left else { return false }
        return (try? JSONSerialization.data(withJSONObject: left, options: [.sortedKeys, .fragmentsAllowed])) ==
            (try? JSONSerialization.data(withJSONObject: right, options: [.sortedKeys, .fragmentsAllowed]))
    }
}
