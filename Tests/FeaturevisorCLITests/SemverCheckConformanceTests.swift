import Foundation
import XCTest
import Featurevisor
@testable import FeaturevisorCLI

final class SemverCheckConformanceTests: XCTestCase {
    func testPortableSemverChecks() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "conformance/semver.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(fixture["kind"] as? String, "featurevisor.semver")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        let cases = fixture["cases"] as! [[String: Any]]
        XCTAssertEqual(cases.count, 44)
        for entry in cases {
            for reverse in [false, true] {
                let left = entry[reverse ? "right" : "left"] as! String
                let right = entry[reverse ? "left" : "right"] as! String
                let order = (entry["order"] as? Int ?? 0) * (reverse ? -1 : 1)
                let valid = entry["order"] is Int
                let operators = [
                    "semverEquals": order == 0, "semverNotEquals": order != 0,
                    "semverGreaterThan": order > 0, "semverGreaterThanOrEquals": order >= 0,
                    "semverLessThan": order < 0, "semverLessThanOrEquals": order <= 0,
                ]
                let raw: [String: Any] = [
                    "schemaVersion": "2", "revision": "semver", "features": [:], "segments": [:],
                    "variables": ["left": ["type": "string", "defaultValue": left], "right": ["type": "string", "defaultValue": right]],
                ]
                let encoded = try JSONSerialization.data(withJSONObject: raw)
                let datafile = try DatafileContent.fromJSON(String(decoding: encoded, as: UTF8.self))
                let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile))
                defer { sdk.close() }
                for (operation, matched) in operators {
                    for compareTo in [false, true] {
                        for negated in [false, true] {
                            var check: [String: Any] = ["variable": "left", "operator": operation, "value": right]
                            if compareTo { check.removeValue(forKey: "value"); check["compareTo"] = ["variable": "right"] }
                            if negated { check = ["not": [check]] }
                            let outcome = evaluateAssertionChecksDetailed(["checks": [check]], ownerVariable: nil, resolver: NativeCheckResolver(sdk, diagnostics: CheckDiagnosticCollector()), datafile: datafile)
                            let label = "\(entry["name"]!) \(operation) reverse=\(reverse) compareTo=\(compareTo) negated=\(negated)"
                            XCTAssertEqual(outcome.hadError, !valid, label)
                            XCTAssertEqual(outcome.failures.isEmpty, valid && (matched != negated), label)
                            if !valid {
                                XCTAssertEqual(outcome.reportErrors.count, 1, label)
                                XCTAssertEqual(outcome.reportErrors.first?["type"] as? String, "check", label)
                            }
                        }
                    }
                }
            }
        }
    }
}
