import Foundation
import XCTest
@testable import Featurevisor

final class MutualExclusionTests: XCTestCase {
    func testLegacyFeatureRangesAreIgnored() throws {
        for ranges in ["[[0, 10000]]", "[[0, 100000]]", "[]", "null", #"{"removed": true}"#, #""ignored""#] {
            for percentage in [0, 25_000, 50_000, 100_000] {
                let datafile = try DatafileContent.fromJSON("""
                {
                    "schemaVersion": "2", "revision": "legacy", "segments": {},
                    "features": {"experiment": {
                        "bucketBy": "userId", "ranges": \(ranges),
                        "variations": [{"value": "a"}, {"value": "b"}],
                        "traffic": [{"key": "all", "segments": "*", "percentage": \(percentage),
                            "allocation": [{"variation": "a", "range": [0, 50000]},
                                {"variation": "b", "range": [50000, 100000]}]}]
                    }}
                }
                """)
                let encoded = try JSONEncoder().encode(datafile.features["experiment"]!)
                let feature = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                XCTAssertNil(feature["ranges"])
                for bucket in [10_000, 40_000, 60_000] {
                    let module = FeaturevisorModule(name: "bucket", bucketValue: { _ in bucket })
                    let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
                    let sdk = createFeaturevisor(FeaturevisorOptions(
                        datafile: datafile,
                        logLevel: .warn,
                        onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } },
                        modules: [module]
                    ))
                    defer { sdk.close() }
                    let context: Context = ["userId": .string("123")]
                    let enabled = percentage > 0 && bucket <= percentage
                    let evaluation = sdk.evaluateFlag("experiment", context: context)
                    XCTAssertEqual(evaluation.enabled, enabled, "\(ranges), \(percentage), \(bucket)")
                    XCTAssertEqual(evaluation.reason, enabled || percentage == 0 ? .rule : .noMatch)
                    XCTAssertEqual(sdk.getVariation("experiment", context), enabled ? (bucket < 50_000 ? "a" : "b") : nil)
                    XCTAssertTrue(diagnostics.value.isEmpty, "Ignored ranges must not cause warnings or errors")
                }
            }
        }
    }

    func testRequiredFeaturesMutualExclusionWithNormalHashing() throws {
        let datafile = try DatafileContent.fromJSON("""
        {
            "schemaVersion": "2", "revision": "requirements", "segments": {},
            "features": {
                "allocation": {"bucketBy": "userId", "variations": [{"value": "a"}, {"value": "b"}, {"value": "holdout"}],
                    "traffic": [{"key": "all", "segments": "*", "percentage": 100000,
                        "allocation": [{"variation": "a", "range": [0, 40000]}, {"variation": "b", "range": [40000, 80000]}, {"variation": "holdout", "range": [80000, 100000]}]}]},
                "experimentA": {"bucketBy": "userId", "requiredFeatures": [{"feature": "allocation", "variation": "a"}],
                    "traffic": [{"key": "all", "segments": "*", "percentage": 100000}]},
                "experimentB": {"bucketBy": "userId", "requiredFeatures": [{"feature": "allocation", "variation": "b"}],
                    "traffic": [{"key": "all", "segments": "*", "percentage": 100000}]},
                "primary": {"bucketBy": "userId", "traffic": [{"key": "all", "segments": "*", "percentage": 50000}]},
                "secondary": {"bucketBy": "userId", "requiredFeatures": [{"feature": "primary", "enabled": false}],
                    "traffic": [{"key": "all", "segments": "*", "percentage": 100000}]}
            }
        }
        """)
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile))
        defer { sdk.close() }
        var aCount = 0
        var bCount = 0
        var holdoutCount = 0
        var primaryCount = 0
        for user in 0..<20_000 {
            let context: Context = ["userId": .string("user-\(user)")]
            let a = sdk.isEnabled("experimentA", context)
            let b = sdk.isEnabled("experimentB", context)
            let primary = sdk.isEnabled("primary", context)
            let secondary = sdk.isEnabled("secondary", context)
            XCTAssertFalse(a && b, "user \(user)")
            XCTAssertNotEqual(primary, secondary, "user \(user)")
            let variation = sdk.getVariation("allocation", context)
            XCTAssertEqual(a, variation == "a")
            XCTAssertEqual(b, variation == "b")
            XCTAssertEqual(!a && !b, variation == "holdout")
            let bReversed = sdk.isEnabled("experimentB", context)
            let aReversed = sdk.isEnabled("experimentA", context)
            let secondaryReversed = sdk.isEnabled("secondary", context)
            let primaryReversed = sdk.isEnabled("primary", context)
            XCTAssertEqual(bReversed, b)
            XCTAssertEqual(aReversed, a)
            XCTAssertEqual(secondaryReversed, secondary)
            XCTAssertEqual(primaryReversed, primary)
            XCTAssertEqual(sdk.evaluateVariation("allocation", context: context).reason, .allocated)
            if a { aCount += 1 }
            if b { bCount += 1 }
            if variation == "holdout" { holdoutCount += 1 }
            if primary { primaryCount += 1 }
        }
        XCTAssertTrue((7000...9000).contains(aCount), "Allocation A population: \(aCount)")
        XCTAssertTrue((7000...9000).contains(bCount), "Allocation B population: \(bCount)")
        XCTAssertTrue((3000...5000).contains(holdoutCount), "Holdout population: \(holdoutCount)")
        XCTAssertTrue((9000...11000).contains(primaryCount), "Priority population: \(primaryCount)")
        print("20,000 users: A=\(aCount), B=\(bCount), holdout=\(holdoutCount), primary=\(primaryCount); zero overlap in both evaluation orders")
    }
}
