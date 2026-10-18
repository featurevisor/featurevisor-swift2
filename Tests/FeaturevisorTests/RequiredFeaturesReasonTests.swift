import XCTest
@testable import Featurevisor

final class RequiredFeaturesReasonTests: XCTestCase {
    func testUnmetFeatureReasonInEvaluationAndCallbacks() throws {
        let observed = ConcurrencyBox<[EvaluationReason]>([])
        let module = FeaturevisorModule(name: "observe", afterEvaluation: { evaluation, _ in
            if evaluation.featureKey == "subject" {
                observed.mutate { $0.append(evaluation.reason) }
            }
            return evaluation
        })
        let datafile = try DatafileContent.fromJSON(#"""
        {"schemaVersion":"2","revision":"reason","segments":{},"features":{
            "subject":{"bucketBy":"userId","requiredFeatures":["missing"],"traffic":[]}
        }}
        """#)
        let f = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .fatal, modules: [module]))
        defer { f.close() }
        let evaluation = f.evaluateFlag("subject")
        XCTAssertEqual(evaluation.reason, .conditionsUnmet)
        XCTAssertEqual(evaluation.enabled, false)
        XCTAssertEqual(observed.value, [.conditionsUnmet])
        let encoded = try JSONEncoder().encode(evaluation)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(wire["reason"] as? String, "conditions_unmet")
        XCTAssertEqual(evaluation.conditions, .list([.feature(FeatureCondition(feature: "missing"))]))
        XCTAssertNil(wire["requiredFeatures"])
        XCTAssertNil(EvaluationReason(rawValue: "required_features_unmet"))
        XCTAssertNil(EvaluationReason(rawValue: "required_variables_unmet"))
        XCTAssertNil(EvaluationReason(rawValue: "required"))
    }
}
