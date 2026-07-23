import XCTest
@testable import Featurevisor

final class InstanceEvaluationDataProviderTests: XCTestCase {
    func testCachesCompiledRegularExpressionsByPatternAndFlags() {
        let reader = InstanceEvaluationDataProvider(
            datafile: TestFixtures.basicDatafile(),
            reportDiagnostic: { _ in }
        )
        let caseSensitive = Condition.predicate(.init(
            attribute: "browser",
            operator: "matches",
            value: .string("^chrome$")
        ))
        let caseInsensitive = Condition.predicate(.init(
            attribute: "browser",
            operator: "matches",
            value: .string("^chrome$"),
            regexFlags: "i"
        ))

        XCTAssertTrue(reader.allConditionsAreMatched(
            caseSensitive,
            context: ["browser": .string("chrome")]
        ))
        XCTAssertTrue(reader.allConditionsAreMatched(
            caseSensitive,
            context: ["browser": .string("chrome")]
        ))
        XCTAssertEqual(reader.getCachedRegexCount(), 1)

        XCTAssertTrue(reader.allConditionsAreMatched(
            caseInsensitive,
            context: ["browser": .string("Chrome")]
        ))
        XCTAssertEqual(reader.getCachedRegexCount(), 2)
    }

    func testRegularExpressionCacheSupportsConcurrentEvaluations() {
        let reader = InstanceEvaluationDataProvider(
            datafile: TestFixtures.basicDatafile(),
            reportDiagnostic: { _ in }
        )
        let condition = Condition.predicate(.init(
            attribute: "browser",
            operator: "matches",
            value: .string("^(chrome|firefox)$"),
            regexFlags: "i"
        ))

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            let value = index.isMultiple(of: 2) ? "Chrome" : "Firefox"
            XCTAssertTrue(reader.allConditionsAreMatched(
                condition,
                context: ["browser": .string(value)]
            ))
        }

        XCTAssertEqual(reader.getCachedRegexCount(), 1)
    }

    func testSharedV3ConformanceFixture() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "conformance/sdk-v3.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(fixture["version"] as? Int, 2)

        let bucketing = fixture["bucketing"] as! [String: Any]
        let expected = bucketing["allocationExpectations"] as! [String: String]
        let reader = InstanceEvaluationDataProvider(datafile: TestFixtures.basicDatafile(), reportDiagnostic: { _ in })
        let traffic = Traffic(
            key: "all",
            segments: .all,
            percentage: 100000,
            enabled: nil,
            variation: nil,
            variables: nil,
            variationWeights: nil,
            variableOverrides: nil,
            allocation: [
                Allocation(variation: "control", range: [0, 50000]),
                Allocation(variation: "treatment", range: [50000, 100000]),
            ]
        )

        for (bucket, variation) in expected {
            XCTAssertEqual(reader.getMatchedAllocation(traffic, bucketValue: Int(bucket)!)?.variation, variation)
        }

        let numericBucketKeys = fixture["numericBucketKeys"] as! [[String: Any]]
        for testCase in numericBucketKeys {
            let value = (testCase["value"] as! NSNumber).doubleValue
            let expectedValue = testCase["expected"] as! String
            XCTAssertEqual(
                getBucketKey(
                    featureKey: "feature",
                    bucketBy: .single("value"),
                    context: ["value": .double(value)]
                ),
                "\(expectedValue).feature"
            )
        }

        let regularExpressions = fixture["regularExpressions"] as! [String: Any]
        let portableCases = regularExpressions["portableCases"] as! [[String: Any]]
        for testCase in portableCases {
            let pattern = testCase["pattern"] as! String
            let flags = testCase["flags"] as! String
            let value = testCase["value"] as! String
            let expected = testCase["expected"] as! Bool
            let condition = Condition.predicate(.init(
                attribute: "value",
                operator: "matches",
                value: .string(pattern),
                regexFlags: flags.isEmpty ? nil : flags
            ))
            XCTAssertEqual(
                reader.allConditionsAreMatched(condition, context: ["value": .string(value)]),
                expected,
                "pattern \(pattern), flags \(flags), value \(value)"
            )
        }

        let conditionCases = fixture["conditionCases"] as! [[String: Any]]
        for testCase in conditionCases {
            let conditionData = try JSONSerialization.data(withJSONObject: testCase["condition"]!)
            let contextData = try JSONSerialization.data(withJSONObject: testCase["context"]!)
            let condition = try JSONDecoder().decode(Condition.self, from: conditionData)
            let context = try JSONDecoder().decode(Context.self, from: contextData)
            XCTAssertEqual(
                reader.allConditionsAreMatched(condition, context: context),
                testCase["expected"] as! Bool,
                testCase["name"] as! String
            )
        }

        let defaults = fixture["defaults"] as! [String: Any]
        let aggregateCase = defaults["aggregateCase"] as! [String: Any]
        let datafileData = try JSONSerialization.data(withJSONObject: aggregateCase["datafile"]!)
        let datafile = try JSONDecoder().decode(DatafileContent.self, from: datafileData)
        let featurevisor = createFeaturevisor(FeaturevisorOptions(datafile: datafile))
        let evaluated = featurevisor.getAllEvaluations(
            [:],
            [],
            OverrideOptions(
                defaultVariationValue: (aggregateCase["defaultVariationValue"] as! String)
            )
        )["experiment"]
        let expectedDefault = aggregateCase["expected"] as! [String: Any]
        XCTAssertEqual(evaluated?.enabled, expectedDefault["enabled"] as? Bool)
        XCTAssertEqual(evaluated?.variation, expectedDefault["variation"] as? String)
    }

    func testGetters() {
        let reader = InstanceEvaluationDataProvider(datafile: TestFixtures.basicDatafile(), reportDiagnostic: { _ in })

        XCTAssertEqual(reader.getRevision(), "1")
        XCTAssertEqual(reader.getSchemaVersion(), "2")
        XCTAssertNotNil(reader.getFeature("test"))
        XCTAssertNotNil(reader.getSegment("nl"))
    }

    func testMatchedTrafficAndForce() {
        let reader = InstanceEvaluationDataProvider(datafile: TestFixtures.basicDatafile(), reportDiagnostic: { _ in })
        let feature = reader.getFeature("test")!

        let traffic = reader.getMatchedTraffic(feature.traffic, context: ["userId": .string("123")])
        XCTAssertEqual(traffic?.key, "1")

        let force = reader.getMatchedForce(feature, context: ["userId": .string("forced")])
        XCTAssertEqual(force.force?.variation, "control")
        XCTAssertEqual(force.index, 0)
    }

    func testNotSegmentsNegateImplicitAnd() {
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [
                "mobile": Segment(key: "mobile", conditions: .tree(.predicate(.init(attribute: "device", operator: "equals", value: .string("mobile"))))),
                "desktop": Segment(key: "desktop", conditions: .tree(.predicate(.init(attribute: "device", operator: "equals", value: .string("desktop"))))),
                "nl": Segment(key: "nl", conditions: .tree(.predicate(.init(attribute: "country", operator: "equals", value: .string("nl"))))),
            ],
            features: [:]
        )
        let reader = InstanceEvaluationDataProvider(datafile: datafile, reportDiagnostic: { _ in })

        let notAll = GroupSegment.not([.key("mobile"), .key("nl")])
        XCTAssertFalse(reader.allSegmentsAreMatched(notAll, context: ["device": .string("mobile"), "country": .string("nl")]))
        XCTAssertTrue(reader.allSegmentsAreMatched(notAll, context: ["device": .string("desktop"), "country": .string("nl")]))
        XCTAssertFalse(reader.allSegmentsAreMatched(.not([]), context: [:]))
    }

    func testNotSegmentsWithNestedOrMeanNoneMatch() {
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [
                "mobile": Segment(key: "mobile", conditions: .tree(.predicate(.init(attribute: "device", operator: "equals", value: .string("mobile"))))),
                "desktop": Segment(key: "desktop", conditions: .tree(.predicate(.init(attribute: "device", operator: "equals", value: .string("desktop"))))),
            ],
            features: [:]
        )
        let reader = InstanceEvaluationDataProvider(datafile: datafile, reportDiagnostic: { _ in })

        let noneOfDevices = GroupSegment.not([.or([.key("mobile"), .key("desktop")])])
        XCTAssertFalse(reader.allSegmentsAreMatched(noneOfDevices, context: ["device": .string("mobile")]))
        XCTAssertTrue(reader.allSegmentsAreMatched(noneOfDevices, context: ["device": .string("tv")]))
    }

    func testReportsConditionMatchAndParseDiagnostics() {
        let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: ["broken": Segment(key: "broken", conditions: .string("{"))],
            features: [:]
        )
        let reader = InstanceEvaluationDataProvider(
            datafile: datafile,
            reportDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }
        )

        XCTAssertFalse(reader.allConditionsAreMatched(
            .predicate(.init(attribute: "value", operator: "matches", value: .string("("))),
            context: ["value": .string("text")]
        ))
        XCTAssertFalse(reader.allConditionsAreMatched(
            .predicate(.init(attribute: "version", operator: "semverGreaterThan", value: .string("1.0.0"))),
            context: ["version": .string("invalid")]
        ))
        XCTAssertNotNil(reader.getSegment("broken"))

        XCTAssertEqual(
            diagnostics.value.map(\.code),
            ["condition_match_error", "condition_match_error", "conditions_parse_error"]
        )
        XCTAssertTrue(diagnostics.value.allSatisfy { !$0.details.isEmpty })
        XCTAssertTrue(diagnostics.value.allSatisfy { $0.originalError != nil })
    }

    func testWildcardSegmentConditionsDoNotReportParseErrors() {
        let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "wildcard",
            segments: ["all": Segment(key: "all", conditions: .string("*"))],
            features: [:]
        )
        let reader = InstanceEvaluationDataProvider(
            datafile: datafile,
            reportDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }
        )

        XCTAssertTrue(reader.segmentIsMatched(reader.getSegment("all")!, context: [:]))
        XCTAssertFalse(diagnostics.value.contains { $0.code == "conditions_parse_error" })
    }
}
