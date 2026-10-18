import XCTest
@testable import Featurevisor

private struct PortableConditionFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let condition: Condition
        let context: Context
        let expected: Bool
    }
    let conditionCases: [Case]
}

final class InstanceEvaluationDataProviderTests: XCTestCase {
    private func match(_ condition: Condition, datafile: DatafileContent, context: Context) -> Bool {
        var datafile = datafile
        let raw: [String: Any] = [
            "bucketBy": "userId",
            "conditions": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(condition), options: [.fragmentsAllowed]),
            "traffic": [["key": "all", "conditions": "*", "percentage": 100000]],
        ]
        datafile.features["__subject"] = try! JSONDecoder().decode(Feature.self, from: JSONSerialization.data(withJSONObject: raw))
        let f = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .fatal))
        defer { f.close() }
        return f.isEnabled("__subject", context)
    }

    private func stringifiedReader() -> InstanceEvaluationDataProvider {
        var datafile = TestFixtures.basicDatafile()
        datafile.schemaVersion = "4"
        datafile.features["test"]?.conditions = .invalidToken("[{\"attribute\":\"country\",\"operator\":\"equals\",\"value\":\"nl\"}]")
        datafile.segments["nl"]?.conditions = .string("[{\"attribute\":\"country\",\"operator\":\"equals\",\"value\":\"nl\"}]")
        return InstanceEvaluationDataProvider(datafile: datafile, reportDiagnostic: { _ in })
    }

    func testLateTrafficScanKeepsFirstMatchAndMetadataOwnership() throws {
        var traffic = (0..<128).map { index in
            Traffic(
                key: "rule-\(index)", segments: .key("missing"), percentage: 100000,
                enabled: nil, variation: nil, variables: ["source": .string("original")],
                variationWeights: nil, variableOverrides: nil, allocation: nil
            )
        }
        traffic[126].segments = .all
        traffic[127].segments = .all

        var datafile = TestFixtures.basicDatafile()
        datafile.features["test"]?.force = nil
        datafile.features["test"]?.traffic = traffic
        let f = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .fatal))
        defer { f.close() }
        var matched = try XCTUnwrap(f.evaluateFlag("test").traffic)
        XCTAssertEqual(matched.key, "rule-126")
        matched.key = "caller-change"
        matched.variables?["source"] = .string("caller-change")
        XCTAssertEqual(traffic[126].key, "rule-126")
        XCTAssertEqual(traffic[126].variables?["source"], .string("original"))
    }

    func testLateGlobalOverrideKeepsFirstMatchAndIndex() {
        var overrides = (0..<128).map { index in
            VariableOverride(
                key: "override-\(index)", keyPath: nil, value: .string("value-\(index)"),
                conditions: .predicate(.init(attribute: "role", operator: "equals", value: .string("missing-\(index)"))),
                segments: nil, requiredFeatures: nil
            )
        }
        let matching = Condition.predicate(.init(attribute: "role", operator: "equals", value: .string("member")))
        overrides[126].conditions = matching
        overrides[127].conditions = matching
        let datafile = DatafileContent(
            schemaVersion: "2", revision: "late", segments: [:], features: [:],
            variables: ["message": GlobalVariable(type: "string", defaultValue: .string("default"), overrides: overrides)]
        )
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile))

        let evaluation = sdk.evaluateVariable("message", context: ["role": .string("member")])
        XCTAssertEqual(evaluation.reason, .variableOverrideRule)
        XCTAssertEqual(evaluation.variableOverrideIndex, 126)
        XCTAssertEqual(evaluation.variableOverrideKey, "override-126")
        XCTAssertEqual(evaluation.variableValue, .string("value-126"))
    }

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

    func testCachesStringifiedExpressionsPerProviderGeneration() throws {
        let reader = stringifiedReader()
        for _ in 0..<2 {
            XCTAssertEqual(reader.getFeature("test")?.conditions, .list([.predicate(.init(attribute: "country", operator: "equals", value: .string("nl")))]))
            XCTAssertNotNil(reader.getSegment("nl"))
        }
        XCTAssertEqual(reader.getCachedEntityCount(), 2)
        XCTAssertEqual(stringifiedReader().getCachedEntityCount(), 0)
    }

    func testStringifiedExpressionCacheSupportsConcurrentEvaluations() {
        let reader = stringifiedReader()
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            XCTAssertNotNil(reader.getFeature("test"))
            XCTAssertNotNil(reader.getSegment("nl"))
        }
        XCTAssertEqual(reader.getCachedEntityCount(), 2)
    }

    func testCloseReleasesAndDisablesExpressionCache() {
        let reader = stringifiedReader()
        _ = reader.getFeature("test")
        _ = reader.getSegment("nl")
        reader.closeEntityCache()
        XCTAssertEqual(reader.getCachedEntityCount(), 0)
        _ = reader.getFeature("test")
        _ = reader.getSegment("nl")
        XCTAssertEqual(reader.getCachedEntityCount(), 0)
    }

    func testSharedV3ConformanceFixture() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "conformance/sdk-v3.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(fixture["version"] as? Int, 15)

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

        let conditionCases = try JSONDecoder().decode(PortableConditionFixture.self, from: data).conditionCases
        XCTAssertEqual(conditionCases.count, 189)
        var executedAnyCases = 0
        for testCase in conditionCases {
            if testCase.name.lowercased().contains("includesany") { executedAnyCases += 1 }
            XCTAssertEqual(
                reader.allConditionsAreMatched(testCase.condition, context: testCase.context),
                testCase.expected,
                testCase.name
            )
        }

        XCTAssertEqual(executedAnyCases, 73)

        let defaults = fixture["defaults"] as! [String: Any]
        let aggregateCase = defaults["aggregateCase"] as! [String: Any]
        let datafileData = try JSONSerialization.data(withJSONObject: aggregateCase["datafile"]!)
        let datafile = try JSONDecoder().decode(DatafileContent.self, from: datafileData)
        let featurevisor = createFeaturevisor(FeaturevisorOptions(datafile: datafile))
        let evaluated = featurevisor.getFeatureEvaluations(
            [:],
            [],
            OverrideOptions(
                defaultVariationValue: (aggregateCase["defaultVariationValue"] as! String)
            )
        )["experiment"]
        let expectedDefault = aggregateCase["expected"] as! [String: Any]
        XCTAssertEqual(evaluated?.enabled, expectedDefault["enabled"] as? Bool)
        XCTAssertEqual(evaluated?.variation, expectedDefault["variation"] as? String)

        let globals = fixture["globalVariables"] as! [String: Any]
        let globalsData = try JSONSerialization.data(withJSONObject: globals["datafile"]!)
        let globalDatafile = try JSONDecoder().decode(DatafileContent.self, from: globalsData)
        for testCase in globals["cases"] as! [[String: Any]] {
            let stickyData = try JSONSerialization.data(withJSONObject: testCase["stickyVariables"] ?? [:])
            let sticky = try JSONDecoder().decode(StickyVariables.self, from: stickyData)
            let sdk = createFeaturevisor(FeaturevisorOptions(datafile: globalDatafile, stickyVariables: sticky))
            let contextData = try JSONSerialization.data(withJSONObject: testCase["context"] ?? [:])
            let context = try JSONDecoder().decode(Context.self, from: contextData)
            let defaultValue = try testCase["defaultVariableValue"].map {
                try JSONDecoder().decode([AnyValue].self, from: JSONSerialization.data(withJSONObject: [$0]))[0]
            }
            let evaluation = sdk.evaluateVariable(testCase["key"] as! String, context: context, options: OverrideOptions(defaultVariableValue: defaultValue))
            let actual = evaluation.variableValue ?? defaultValue
            let expectedValue = try testCase["expectedValue"].map {
                try JSONDecoder().decode([AnyValue].self, from: JSONSerialization.data(withJSONObject: [$0]))[0]
            }
            XCTAssertEqual(actual, expectedValue, testCase["name"] as! String)
            XCTAssertEqual(evaluation.reason.rawValue, testCase["expectedReason"] as? String, testCase["name"] as! String)
            XCTAssertEqual(evaluation.variableOverrideIndex, testCase["expectedOverrideIndex"] as? Int)
            XCTAssertEqual(evaluation.variableOverrideKey, testCase["expectedOverrideKey"] as? String)
            XCTAssertEqual(evaluation.variableOverridePath, testCase["expectedOverridePath"] as? [String])
        }

        let required = fixture["requiredFeatures"] as! [String: Any]
        let requiredData = try JSONSerialization.data(withJSONObject: required["datafile"]!)
        let requiredDatafile = try JSONDecoder().decode(DatafileContent.self, from: requiredData)
        let requiredSDK = createFeaturevisor(FeaturevisorOptions(datafile: requiredDatafile))
        for testCase in required["cases"] as! [[String: Any]] {
            XCTAssertEqual(requiredSDK.isEnabled(testCase["feature"] as! String), testCase["expectedEnabled"] as? Bool, testCase["name"] as! String)
        }
        let featureVariable = required["featureVariableCase"] as! [String: Any]
        let featureEvaluation = requiredSDK.evaluateVariable(featureVariable["feature"] as! String, featureVariable["variable"] as! String)
        XCTAssertEqual(featureEvaluation.variableValue?.asString(), featureVariable["expectedValue"] as? String)
        XCTAssertEqual(featureEvaluation.variableOverrideKey, featureVariable["expectedOverrideKey"] as? String)

        let dependencyCase = globals["dependencyUpdateCase"] as! [String: Any]
        let initial = try JSONDecoder().decode(
            DatafileContent.self,
            from: JSONSerialization.data(withJSONObject: dependencyCase["initial"]!)
        )
        let expectedFeatures = dependencyCase["expectedChangedFeatures"] as! [String]
        let expectedVariables = dependencyCase["expectedChangedVariables"] as! [String]
        for mode in dependencyCase["modes"] as! [[String: Any]] {
            let sdk = createFeaturevisor(FeaturevisorOptions(datafile: initial))
            let event = ConcurrencyBox<EventPayload?>(nil)
            let unsubscribe = sdk.on(.datafileSet) { event.value = $0 }
            let updated = try JSONDecoder().decode(
                DatafileContent.self,
                from: JSONSerialization.data(withJSONObject: dependencyCase["updated"]!)
            )
            sdk.setDatafile(updated, replace: mode["replace"] as! Bool)
            XCTAssertEqual(event.value?.params["features"]?.asArray()?.compactMap { $0.asString() }.sorted(), expectedFeatures)
            XCTAssertEqual(event.value?.params["variables"]?.asArray()?.compactMap { $0.asString() }.sorted(), expectedVariables)
            unsubscribe()
        }

        let removalSDK = createFeaturevisor(FeaturevisorOptions(datafile: initial))
        let removalEvent = ConcurrencyBox<EventPayload?>(nil)
        let unsubscribe = removalSDK.on(.datafileSet) { removalEvent.value = $0 }
        let withoutSegment = try JSONDecoder().decode(
            DatafileContent.self,
            from: JSONSerialization.data(withJSONObject: dependencyCase["withoutSegment"]!)
        )
        removalSDK.setDatafile(withoutSegment, replace: true)
        XCTAssertEqual(
            removalEvent.value?.params["features"]?.asArray()?.compactMap { $0.asString() }.sorted(),
            dependencyCase["expectedRemovedSegmentFeatures"] as? [String]
        )
        XCTAssertEqual(
            removalEvent.value?.params["variables"]?.asArray()?.compactMap { $0.asString() }.sorted(),
            dependencyCase["expectedRemovedSegmentVariables"] as? [String]
        )
        unsubscribe()
    }

    func testGetters() {
        let reader = InstanceEvaluationDataProvider(datafile: TestFixtures.basicDatafile(), reportDiagnostic: { _ in })

        XCTAssertEqual(reader.getRevision(), "1")
        XCTAssertEqual(reader.getSchemaVersion(), "2")
        XCTAssertNotNil(reader.getFeature("test"))
        XCTAssertNotNil(reader.getSegment("nl"))
    }

    func testMatchedTrafficAndForce() {
        let f = createFeaturevisor(FeaturevisorOptions(datafile: TestFixtures.basicDatafile(), logLevel: .fatal))
        defer { f.close() }
        XCTAssertEqual(f.evaluateFlag("test", context: ["userId": .string("123")]).traffic?.key, "1")
        let forced = f.evaluateVariation("test", context: ["userId": .string("forced")])
        XCTAssertEqual(forced.force?.variation, "control")
        XCTAssertEqual(forced.forceIndex, 0)
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
        let notAll = Condition.not([.invalidToken("mobile"), .invalidToken("nl")])
        XCTAssertFalse(match(notAll, datafile: datafile, context: ["device": .string("mobile"), "country": .string("nl")]))
        XCTAssertTrue(match(notAll, datafile: datafile, context: ["device": .string("desktop"), "country": .string("nl")]))
        XCTAssertFalse(match(.not([]), datafile: datafile, context: [:]))
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
        let noneOfDevices = Condition.not([.or([.invalidToken("mobile"), .invalidToken("desktop")])])
        XCTAssertFalse(match(noneOfDevices, datafile: datafile, context: ["device": .string("mobile")]))
        XCTAssertTrue(match(noneOfDevices, datafile: datafile, context: ["device": .string("tv")]))
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

        XCTAssertNotNil(reader.getSegment("all"))
        XCTAssertTrue(match(.invalidToken("all"), datafile: datafile, context: [:]))
        XCTAssertFalse(diagnostics.value.contains { $0.code == "conditions_parse_error" })
    }
}
