import Foundation
import XCTest
@testable import Featurevisor

final class UnifiedConformanceTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "conformance/\(name).json"))) as? [String: Any])
    }

    private func decode<T: Decodable>(_ value: Any, as: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }

    private func compare(_ evaluation: Evaluation, expected: [String: Any], name: String) throws {
        XCTAssertFalse(expected.isEmpty, "\(name): missing expected evaluation fields")
        let actual = try JSONDecoder().decode([String: AnyValue].self, from: JSONEncoder().encode(evaluation))
        for (key, value) in expected {
            if key == "value" { XCTAssertEqual(evaluation.variableValue ?? .null, try decode(value, as: AnyValue.self), name) }
            else if key == "error", value is Bool { XCTAssertEqual(evaluation.error != nil, value as! Bool, name) }
            else { XCTAssertEqual(actual[key], try decode(value, as: AnyValue.self), "\(name): \(key)") }
        }
    }

    func testDiagnosticsFixtureRevisionCacheAndReentry() throws {
        let fixture = try fixture("sdk-diagnostics")
        XCTAssertEqual(fixture["kind"] as? String, "featurevisor.sdk-diagnostics")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases + cases {
            let owner = ConcurrencyBox<Featurevisor?>(nil)
            let seen = ConcurrencyBox<[[String: AnyValue]]>([])
            let reentering = ConcurrencyBox<Bool>(false)
            let sdk = createFeaturevisor(FeaturevisorOptions(logLevel: .error, onDiagnostic: { diagnostic in
                guard diagnostic.code == "conditions_parse_error" else { return }
                seen.mutate { $0.append([
                    "code": .string(diagnostic.code), "level": .string(String(describing: diagnostic.level)),
                    "details": .object(diagnostic.details), "revision": .string(owner.value!.getRevision()),
                ]) }
                if diagnostic.details["entityType"] == .string("feature"), !reentering.value {
                    reentering.mutate { $0 = true }
                    defer { reentering.mutate { $0 = false } }
                    let before = seen.value.count
                    if case let .string(key)? = diagnostic.details["entityKey"] { _ = owner.value!.isEnabled(key) }
                    else { XCTFail("missing feature entityKey") }
                    XCTAssertEqual(seen.value.count, before, "reentry diagnostics")
                }
            }))
            owner.mutate { $0 = sdk }
            defer { owner.mutate { $0 = nil }; sdk.close() }
            let operations = try XCTUnwrap(item["operations"] as? [[String: Any]])
            XCTAssertFalse(operations.isEmpty)
            for operation in operations {
                let before = seen.value.count
                let result: Bool
                switch try XCTUnwrap(operation["action"] as? String) {
                case "setDatafile":
                    result = sdk.setDatafile(try decode(try XCTUnwrap(operation["datafile"])), replace: try XCTUnwrap(operation["replace"] as? Bool))
                case "isEnabled": result = sdk.isEnabled(try XCTUnwrap(operation["feature"] as? String))
                default: XCTFail("unsupported diagnostics action"); continue
                }
                XCTAssertEqual(result, try XCTUnwrap(operation["expectedResult"] as? Bool))
                let expected: [[String: AnyValue]] = try decode(try XCTUnwrap(operation["diagnostics"]))
                var unmatched = Array(seen.value.dropFirst(before))
                for diagnostic in expected {
                    if let index = unmatched.firstIndex(of: diagnostic) { unmatched.remove(at: index) }
                    else { XCTFail("missing diagnostic \(diagnostic)") }
                }
                XCTAssertTrue(unmatched.isEmpty, "unexpected diagnostics \(unmatched)")
            }
        }
    }

    func testAllUnifiedCasesTwiceAndOrdinaryGetters() throws {
        let fixture = try fixture("sdk-conditions")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        XCTAssertEqual(fixture["capability"] as? String, "unified-conditions")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        var executed = [0, 0]
        for item in cases {
            let name = item["name"] as! String
            let datafile: DatafileContent = try decode(item["datafile"]!)
            let before = try datafile.toJSON(pretty: true)
            let context: Context = try decode(item["context"] ?? [:])
            let options = item["options"] as? [String: Any] ?? [:]
            let seen = ConcurrencyBox<[[String: AnyValue]]>([])
            let module = FeaturevisorModule(name: "capture", beforeEvaluation: { options in
                if options.dependencyOf != nil {
                    var row: [String: AnyValue] = [:]
                    if !options.featureKey.isEmpty { row["feature"] = .string(options.featureKey) }
                    if let variable = options.variableKey { row["variable"] = .string(variable) }
                    if let purpose = options.dependencyPurpose { row["dependencyPurpose"] = .string(purpose) }
                    seen.mutate { $0.append(row) }
                }
                return options
            })
            let sdk = createFeaturevisor(FeaturevisorOptions(
                datafile: datafile, logLevel: .fatal,
                stickyFeatures: try options["stickyFeatures"].map { try decode($0, as: StickyFeatures.self) },
                stickyVariables: try options["stickyVariables"].map { try decode($0, as: StickyVariables.self) },
                modules: [module]
            ))
            defer { sdk.close() }
            let type = try XCTUnwrap(item["type"] as? String)
            XCTAssertTrue(["flag", "variable"].contains(type), name)
            for attempt in 0..<2 {
                seen.mutate { $0 = [] }
                let evaluation: Evaluation
                if item["type"] as? String == "flag" { evaluation = sdk.evaluateFlag(item["feature"] as! String, context: context) }
                else if let feature = item["feature"] as? String { evaluation = sdk.evaluateVariable(feature, item["variable"] as! String, context: context) }
                else { evaluation = sdk.evaluateVariable(item["variable"] as! String, context: context) }
                try compare(evaluation, expected: item["expected"] as! [String: Any], name: name)
                if let expected = item["dependencies"] {
                    XCTAssertEqual(seen.value, try decode(expected, as: [[String: AnyValue]].self), name)
                }
                if item["type"] as? String == "flag" {
                    let expected = try XCTUnwrap(item["expected"] as? [String: Any])
                    let enabled: AnyValue = try decode(expected["enabled"] ?? NSNull())
                    XCTAssertEqual(sdk.isEnabled(item["feature"] as! String, context), enabled == .bool(true), name)
                } else {
                    let value = (item["feature"] as? String).map { sdk.getVariable($0, item["variable"] as! String, context) } ?? sdk.getVariable(item["variable"] as! String, context)
                    XCTAssertEqual(value ?? .null, try decode((item["expected"] as! [String: Any])["value"] ?? NSNull(), as: AnyValue.self), name)
                }
                executed[attempt] += 1
            }
            XCTAssertEqual(try datafile.toJSON(pretty: true), before, name)
        }
        XCTAssertEqual(executed, [cases.count, cases.count])
    }

    func testAllCompositionCasesTwiceAndOwnership() throws {
        let fixture = try fixture("sdk-composition")
        XCTAssertEqual(fixture["version"] as? Int, 2)
        XCTAssertEqual(fixture["capability"] as? String, "composition-and-overrides")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        var executed = [0, 0]
        let datafile: DatafileContent = try decode(fixture["datafile"]!)
        let before = try datafile.toJSON(pretty: true)
        for item in cases {
            let name = item["name"] as! String
            let sdk = createFeaturevisor(FeaturevisorOptions(
                datafile: datafile, logLevel: .fatal,
                stickyFeatures: try item["stickyFeatures"].map { try decode($0, as: StickyFeatures.self) },
                stickyVariables: try item["stickyVariables"].map { try decode($0, as: StickyVariables.self) }
            ))
            defer { sdk.close() }
            let key = item["variable"] as! String
            let context: Context = try decode(item["context"] ?? [:])
            let expected: AnyValue = try decode(item["expectedValue"]!)
            for attempt in 0..<2 {
                XCTAssertEqual(sdk.getVariable(key, context) ?? .null, expected, name)
                let evaluation = sdk.evaluateVariable(key, context: context)
                try compare(evaluation, expected: item["expectedEvaluation"] as! [String: Any], name: name)
                XCTAssertEqual(evaluation.variableValue ?? .null, expected, name)
                executed[attempt] += 1
            }
            XCTAssertEqual(try datafile.toJSON(pretty: true), before, name)
        }
        XCTAssertEqual(executed, [cases.count, cases.count])
    }
}
