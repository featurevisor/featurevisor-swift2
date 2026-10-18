import Foundation
import XCTest
@testable import Featurevisor

final class V4ConformanceTests: XCTestCase {
    private func decodeValue(_ value: Any) throws -> AnyValue {
        try JSONDecoder().decode(
            [AnyValue].self,
            from: JSONSerialization.data(withJSONObject: [value])
        )[0]
    }

    private func v3Fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: "conformance/sdk-v3.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testV9RequiredFeatureGroups() throws {
        let fixture = try v3Fixture()
        XCTAssertEqual(fixture["version"] as? Int, 15)
        let inputs = fixture["requiredFeatureGroupInputs"] as! [[String: Bool]]
        for group in fixture["requiredFeatureGroups"] as! [[String: Any]] {
            let requirements = group["requirements"]!
            let results = group["results"] as! [Bool]
            for (index, input) in inputs.enumerated() {
                let raw: [String: Any] = [
                    "schemaVersion": "2",
                    "revision": "groups",
                    "segments": [:],
                    "features": [
                        "a": ["bucketBy": "userId", "traffic": []],
                        "b": ["bucketBy": "userId", "traffic": []],
                        "gated": [
                            "bucketBy": "userId",
                            "requiredFeatures": requirements,
                            "traffic": [["key": "all", "segments": "*", "percentage": 100_000]],
                        ],
                    ],
                    "variables": [:],
                ]
                let datafile = try JSONDecoder().decode(
                    DatafileContent.self,
                    from: JSONSerialization.data(withJSONObject: raw)
                )
                let sticky: StickyFeatures = [
                    "a": EvaluatedFeature(enabled: input["a"]!),
                    "b": EvaluatedFeature(enabled: input["b"]!),
                ]
                let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .fatal, stickyFeatures: sticky))
                XCTAssertEqual(sdk.isEnabled("gated"), results[index], group["name"] as! String)
            }
        }
    }

    func testRequiredFeaturesEvaluationCases() throws {
        let fixture = try v3Fixture()
        let contract = try XCTUnwrap(fixture["requiredFeatures"] as? [String: Any])
        let cases = try XCTUnwrap(contract["evaluationCases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        let datafile = try DatafileContent.fromData(JSONSerialization.data(withJSONObject: contract["datafile"]!))
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .fatal))
        defer { sdk.close() }
        for testCase in cases {
            let name = try XCTUnwrap(testCase["name"] as? String)
            let context = try JSONDecoder().decode(Context.self, from: JSONSerialization.data(withJSONObject: testCase["context"] ?? [:]))
            let evaluation: Evaluation
            switch testCase["type"] as? String {
            case "flag":
                evaluation = sdk.evaluateFlag(try XCTUnwrap(testCase["feature"] as? String), context: context)
            case "variation":
                evaluation = sdk.evaluateVariation(try XCTUnwrap(testCase["feature"] as? String), context: context)
            case "variable":
                let variable = try XCTUnwrap(testCase["variable"] as? String)
                if let feature = testCase["feature"] as? String {
                    evaluation = sdk.evaluateVariable(feature, variable, context: context)
                } else {
                    evaluation = sdk.evaluateVariable(variable, context: context)
                }
            default:
                XCTFail("Unknown evaluation type in \(name)")
                continue
            }
            let actual = try JSONDecoder().decode([String: AnyValue].self, from: JSONEncoder().encode(evaluation))
            let expected = try XCTUnwrap(testCase["expected"] as? [String: Any])
            XCTAssertFalse(expected.isEmpty, name)
            for (key, value) in expected {
                XCTAssertEqual(actual[key], try decodeValue(value), "\(name): \(key)")
            }
        }
    }

    func testV9RequiredVariableMixedSourcesAndAccumulation() throws {
        let fixture = try v3Fixture()
        let contract = fixture["requiredVariables"] as! [String: Any]
        let datafile = try JSONDecoder().decode(
            DatafileContent.self,
            from: JSONSerialization.data(withJSONObject: contract["datafile"]!)
        )
        let expected = contract["expected"] as! [String: Any]
        for testCase in contract["stickyCases"] as! [[String: Any]] {
            let stickyVariables = try JSONDecoder().decode(
                StickyVariables.self,
                from: JSONSerialization.data(withJSONObject: testCase["stickyVariables"]!)
            )
            let stickyFeatures = try JSONDecoder().decode(
                StickyFeatures.self,
                from: JSONSerialization.data(withJSONObject: testCase["stickyFeatures"]!)
            )
            let sdk = createFeaturevisor(FeaturevisorOptions(
                datafile: datafile,
                logLevel: .fatal,
                stickyFeatures: stickyFeatures,
                stickyVariables: stickyVariables
            ))
            let matched = testCase["matched"] as! Bool
            let expectedValue = matched ? expected["matchedValue"] as! String : expected["defaultValue"] as! String
            XCTAssertEqual(sdk.isEnabled("gated"), matched)
            XCTAssertEqual(sdk.getVariableString("featureOverride", "message"), expectedValue)
            XCTAssertEqual(sdk.getVariableString("root"), expectedValue)
            XCTAssertEqual(sdk.getVariableString("override"), expectedValue)
            XCTAssertEqual(sdk.getVariable("accumulated"), try decodeValue(testCase["accumulated"]!))
        }
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .fatal))
        XCTAssertNil(sdk.getVariableJSON("malformed"))
        XCTAssertEqual(sdk.getVariableString("nullGate"), expected["matchedValue"] as? String)
    }

    func testPortableV4CasesTwiceThroughGetterAndDetailedEvaluation() throws {
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: "conformance/sdk-v4-cases.json"))
        let fixture = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
        XCTAssertEqual(fixture["version"] as? Int, 1)
        XCTAssertEqual((fixture["cases"] as? [[String: Any]])?.count, 255)

        for testCase in fixture["cases"] as! [[String: Any]] {
            let name = testCase["name"] as! String
            let expected = testCase["expected"] as! [String: Any]
            let expectedReason = expected["reason"] as! String
            let datafileJSON = try JSONSerialization.data(withJSONObject: testCase["datafile"]!)
            let contextJSON = try JSONSerialization.data(withJSONObject: testCase["context"] ?? [:])

            let datafile: DatafileContent
            do {
                datafile = try JSONDecoder().decode(DatafileContent.self, from: datafileJSON)
            } catch {
                XCTAssertEqual(expectedReason, EvaluationReason.error.rawValue, "\(name): typed decode failed unexpectedly")
                continue
            }
            let context = try JSONDecoder().decode(Context.self, from: contextJSON)
            let variablesBeforeEvaluation = datafile.variables
            let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .fatal))
            let expectedValue = try decodeValue(expected["value"] ?? NSNull())
            let expectedGetterValue: AnyValue? = expectedReason == EvaluationReason.error.rawValue ? nil : expectedValue

            for iteration in 1...2 {
                XCTAssertEqual(
                    sdk.getVariable("subject", context),
                    expectedGetterValue,
                    "\(name), getter iteration \(iteration)"
                )
                let evaluation = sdk.evaluateVariable("subject", context: context)
                XCTAssertEqual(evaluation.reason.rawValue, expectedReason, "\(name), evaluation iteration \(iteration)")
                if expectedReason != EvaluationReason.error.rawValue {
                    XCTAssertEqual(evaluation.variableValue, expectedValue, "\(name), detailed value iteration \(iteration)")
                } else {
                    XCTAssertNil(evaluation.variableValue, "\(name), error value iteration \(iteration)")
                }
                if let value = expected["variableOverrideIndex"] as? Int {
                    XCTAssertEqual(evaluation.variableOverrideIndex, value, name)
                }
                if let value = expected["variableOverrideKey"] as? String {
                    XCTAssertEqual(evaluation.variableOverrideKey, value, name)
                }
                if let value = expected["variableOverridePath"] as? [String] {
                    XCTAssertEqual(evaluation.variableOverridePath, value, name)
                }
                if let value = expected["variableOverridePaths"] as? [[String]] {
                    XCTAssertEqual(evaluation.variableOverridePaths, value, name)
                }
            }
            XCTAssertEqual(datafile.variables, variablesBeforeEvaluation, "\(name) mutated variable inputs")
            sdk.close()
        }
    }

    func testFirstMatchRepresentationsRemainEquivalentAcrossChildrenAndDatafileUpdates() throws {
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: "conformance/sdk-v4-cases.json"))
        let fixture = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
        let cases = fixture["cases"] as! [[String: Any]]

        func datafile(named name: String) throws -> DatafileContent {
            let testCase = try XCTUnwrap(cases.first { $0["name"] as? String == name })
            return try JSONDecoder().decode(
                DatafileContent.self,
                from: JSONSerialization.data(withJSONObject: testCase["datafile"]!)
            )
        }

        let precomputed = try datafile(named: "first match precomputed parsed: child")
        let runtime = try datafile(named: "first match runtime parsed: child")
        let root = createFeaturevisor(FeaturevisorOptions(
            datafile: precomputed,
            context: [
                "region": .string("eu"),
                "country": .string("be"),
                "eligible": .bool(true),
                "denied": .bool(true),
            ],
            logLevel: .fatal
        ))
        let blockedChild = root.spawn(["country": .string("nl")])
        let allowedChild = root.spawn(
            ["country": .string("nl")],
            options: SpawnOptions(stickyVariables: ["permission": .bool(true)])
        )
        let parentValue: AnyValue = .object([
            "stage": .string("parent"),
            "rows": .array([.object(["id": .int(1), "tags": .array([.string("parent")])])]),
            "flags": .array([.string("a")]),
        ])
        let childValue: AnyValue = .object([
            "stage": .string("parent"),
            "rows": .array([
                .object(["id": .int(0), "tags": .array([])]),
                .object(["id": .int(1), "tags": .array([.string("parent"), .string("child")])]),
            ]),
            "flags": .array([.string("a")]),
        ])

        func assertValues(program: Bool, file: StaticString = #filePath, line: UInt = #line) {
            for _ in 0..<2 {
                XCTAssertEqual(root.getVariable("subject"), parentValue, file: file, line: line)
                XCTAssertEqual(blockedChild.getVariable("subject"), parentValue, file: file, line: line)
                XCTAssertEqual(allowedChild.getVariable("subject"), childValue, file: file, line: line)
            }
            XCTAssertEqual(
                allowedChild.evaluateVariable("subject").variableOverridePaths,
                program ? [["parent"], ["parent", "child"]] : nil,
                file: file,
                line: line
            )
        }

        assertValues(program: false)
        root.setDatafile(runtime, replace: true)
        assertValues(program: true)
        root.setDatafile(precomputed)
        assertValues(program: false)
    }
}
