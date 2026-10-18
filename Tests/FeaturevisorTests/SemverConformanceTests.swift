import Foundation
import XCTest
@testable import Featurevisor

final class SemverConformanceTests: XCTestCase {
    func testPortableComparisons() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "conformance/semver.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(fixture["kind"] as? String, "featurevisor.semver")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        let cases = fixture["cases"] as! [[String: Any]]
        XCTAssertEqual(cases.count, 44)
        for entry in cases {
            for reverse in [false, true] {
                let a = entry[reverse ? "right" : "left"] as! String
                let b = entry[reverse ? "left" : "right"] as! String
                let label = "\(entry["name"]!) reverse=\(reverse)"
                let order = (entry["order"] as? Int ?? 0) * (reverse ? -1 : 1)
                let valid = entry["order"] is Int
                let operators = [
                    "semverEquals": order == 0, "semverNotEquals": order != 0,
                    "semverGreaterThan": order > 0, "semverGreaterThanOrEquals": order >= 0,
                    "semverLessThan": order < 0, "semverLessThanOrEquals": order <= 0,
                ]
                for (operation, matched) in operators {
                    let condition = Condition.predicate(.init(attribute: "version", operator: operation, value: .string(b)))
                    XCTAssertEqual(allConditionsAreMatched(condition, context: ["version": .string(a)]), valid && matched, label + operation)
                    for featureSource in [false, true] {
                        for negated in [false, true] {
                            var requirement: [String: Any] = ["variable": "source", "operator": operation, "value": b]
                            if featureSource { requirement["feature"] = "sourceFeature" }
                            if negated { requirement = ["not": [requirement]] }
                            let raw: [String: Any] = [
                                "schemaVersion": "2", "revision": "semver", "segments": [:],
                                "features": [
                                    "sourceFeature": ["bucketBy": "userId", "variablesSchema": ["source": ["type": "string", "defaultValue": a]], "traffic": [["key": "all", "segments": "*", "percentage": 100000, "enabled": true]]],
                                    "gate": [
                                    "bucketBy": "userId", "conditions": [requirement],
                                    "traffic": [["key": "all", "segments": "*", "percentage": 100000, "enabled": true]],
                                ]],
                                "variables": [
                                    "source": ["type": "string", "defaultValue": a],
                                    "gate": ["type": "boolean", "defaultValue": true, "disabledValue": false, "conditions": [requirement]],
                                ],
                            ]
                            let data = try JSONSerialization.data(withJSONObject: raw)
                            let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try DatafileContent.fromJSON(String(decoding: data, as: UTF8.self)), logLevel: .fatal))
                            let flag = sdk.evaluateFlag("gate")
                            let variable = sdk.evaluateVariable("gate")
                            sdk.close()
                            if valid {
                                XCTAssertNotEqual(flag.reason, .error, label + operation)
                                XCTAssertNotEqual(variable.reason, .error, label + operation)
                                XCTAssertEqual(flag.enabled, matched != negated, label + operation)
                                XCTAssertEqual(variable.variableValue, .bool(matched != negated), label + operation)
                            } else {
                                XCTAssertEqual(flag.reason, .error, label + operation)
                                XCTAssertEqual(variable.reason, .error, label + operation)
                            }
                        }
                    }
                }
                if let order = entry["order"] as? Int {
                    let expected = reverse ? -order : order
                    XCTAssertEqual(try compareVersions(a, b), expected < 0 ? .lessThan : expected > 0 ? .greaterThan : .equal, label)
                } else {
                    XCTAssertThrowsError(try compareVersions(a, b), label)
                }
            }
        }
    }
}
