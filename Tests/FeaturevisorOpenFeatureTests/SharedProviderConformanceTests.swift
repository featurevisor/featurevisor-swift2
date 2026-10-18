import Foundation
import XCTest
import Featurevisor
import FeaturevisorOpenFeature
import OpenFeature

final class SharedProviderConformanceTests: XCTestCase {
    func testClientEmptyTargetingKeyLimit() async throws {
        let fixture = try fixture()
        let provider = try provider(fixture)
        await OpenFeatureAPI.shared.setProviderAndWait(
            provider: provider,
            initialContext: ImmutableContext(attributes: ["userId": .string("forced")])
        )
        let client = OpenFeatureAPI.shared.getClient()
        XCTAssertTrue(client.getBooleanValue(key: "targetOnly", defaultValue: false))
        await OpenFeatureAPI.shared.setEvaluationContextAndWait(
            evaluationContext: ImmutableContext(targetingKey: "", structure: ImmutableStructure(attributes: ["userId": .string("forced")]))
        )
        XCTAssertTrue(client.getBooleanValue(key: "targetOnly", defaultValue: false))
        await OpenFeatureAPI.shared.setEvaluationContextAndWait(
            evaluationContext: ImmutableContext(attributes: ["userId": .string("")])
        )
        XCTAssertFalse(client.getBooleanValue(key: "targetOnly", defaultValue: false))
        provider.close()
    }

    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "openfeature-provider", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func provider(_ fixture: [String: Any], targetingKeyField: String = "userId") throws -> FeaturevisorOpenFeatureProvider {
        let datafile = try JSONSerialization.data(withJSONObject: fixture["datafile"]!)
        return FeaturevisorOpenFeatureProvider(
            options: FeaturevisorOptions(datafile: try DatafileContent.fromJSON(String(decoding: datafile, as: UTF8.self)), logLevel: .fatal),
            targetingKeyField: targetingKeyField
        )
    }

    private func value(_ source: Any) -> Value {
        if let map = source as? [String: Any] { return .structure(map.mapValues(value)) }
        if let text = source as? String { return .string(text) }
        if let number = source as? NSNumber { return .boolean(number.boolValue) }
        return .null
    }

    private func context(_ source: [String: Any]) -> ImmutableContext {
        var attributes = source
        let targetingKey = attributes.removeValue(forKey: "targetingKey") as? String ?? ""
        return ImmutableContext(targetingKey: targetingKey, structure: ImmutableStructure(attributes: attributes.mapValues(value)))
    }

    private func errorCode(_ wire: String) -> ErrorCode? {
        switch wire {
        case "FLAG_NOT_FOUND": return .flagNotFound
        case "TYPE_MISMATCH": return .typeMismatch
        case "GENERAL": return .general
        default: return nil
        }
    }

    private func reason(_ wire: String) -> String {
        switch wire {
        case "TARGETING_MATCH": return Reason.targetingMatch.rawValue
        case "DEFAULT": return Reason.defaultReason.rawValue
        case "DISABLED": return Reason.disabled.rawValue
        case "ERROR": return Reason.error.rawValue
        case "SPLIT": return Reason.split.rawValue
        default: return wire
        }
    }

    func testSharedProviderConformance() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture["kind"] as? String, "featurevisor.openfeature-provider")
        XCTAssertEqual(fixture["schemaVersion"] as? Int, 1)
        XCTAssertEqual((fixture["cases"] as? [Any])?.count, 16)
        let provider = try provider(fixture)
        defer { provider.close() }

        for item in try XCTUnwrap(fixture["cases"] as? [[String: Any]]) {
            let name = try XCTUnwrap(item["name"] as? String)
            let key = try XCTUnwrap(item["flagKey"] as? String)
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])
            let source = try XCTUnwrap(item["context"] as? [String: Any])
            let input = context(source)
            let before = input.asMap()
            switch item["type"] as? String {
            case "boolean":
                let result = try provider.getBooleanEvaluation(key: key, defaultValue: item["default"] as! Bool, context: input)
                XCTAssertEqual(result.value, expected["value"] as? Bool, name)
                if let expectedReason = expected["reason"] as? String { XCTAssertEqual(result.reason, reason(expectedReason), name) }
                if let error = expected["errorCode"] as? String { XCTAssertEqual(result.errorCode, errorCode(error), name) }
                else { XCTAssertNil(result.errorCode, name) }
            case "string":
                let result = try provider.getStringEvaluation(key: key, defaultValue: item["default"] as! String, context: input)
                XCTAssertEqual(result.value, expected["value"] as? String, name)
                if let expectedReason = expected["reason"] as? String { XCTAssertEqual(result.reason, reason(expectedReason), name) }
                XCTAssertEqual(result.variant, expected["variant"] as? String, name)
                if let error = expected["errorCode"] as? String { XCTAssertEqual(result.errorCode, errorCode(error), name) }
                else { XCTAssertNil(result.errorCode, name) }
            case "object":
                let fallback = value(item["default"]!)
                let result = try provider.getObjectEvaluation(key: key, defaultValue: fallback, context: input)
                XCTAssertEqual(result.value, value(expected["value"]!), name)
                if let expectedReason = expected["reason"] as? String { XCTAssertEqual(result.reason, reason(expectedReason), name) }
                if let error = expected["errorCode"] as? String { XCTAssertEqual(result.errorCode, errorCode(error), name) }
                else { XCTAssertNil(result.errorCode, name) }
            default:
                XCTFail("Unknown shared case type: \(name)")
            }
            XCTAssertEqual(input.asMap(), before, "\(name) input mutated")
        }

        for item in try XCTUnwrap(fixture["targetingCases"] as? [[String: Any]]) {
            if item["name"] as? String == "empty overrides field" { continue }
            let source = try XCTUnwrap(item["context"] as? [String: Any])
            let input = context(source)
            let before = input.asMap()
            let result = try provider.getBooleanEvaluation(key: "targetOnly", defaultValue: false, context: input)
            XCTAssertEqual(result.value, item["expectedValue"] as? Bool, item["name"] as? String ?? "")
            XCTAssertEqual(input.asMap(), before)
        }
        // The upstream context returns an empty string for both omitted and explicit empty keys.
        // An explicit attribute is the available workaround for the custom empty case.
        let custom = try self.provider(fixture, targetingKeyField: "accountId")
        defer { custom.close() }
        let customInput = ImmutableContext(attributes: ["accountId": .string("")])
        let customBefore = customInput.asMap()
        XCTAssertTrue(try custom.getBooleanEvaluation(key: "accountTargeted", defaultValue: false, context: customInput).value)
        XCTAssertEqual(customInput.asMap(), customBefore)
    }
}
