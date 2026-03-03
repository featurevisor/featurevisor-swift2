import XCTest
@testable import Featurevisor

final class ParityBehaviorTests: XCTestCase {
    func testRegexFlagsAreHonored() {
        let condition = Condition.predicate(
            ConditionPredicate(attribute: "browser", operator: "matches", value: .string("^firefox$"), regexFlags: "i")
        )
        XCTAssertTrue(allConditionsMatched(condition, context: ["browser": .string("FireFox")]))
    }

    func testRequiredFeatureWithVariation() {
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [:],
            features: [
                "required": Feature(
                    key: "required",
                    hash: nil,
                    deprecated: nil,
                    required: nil,
                    variablesSchema: nil,
                    disabledVariationValue: nil,
                    variations: [Variation(description: nil, value: "treatment", weight: nil, variables: nil, variableOverrides: nil)],
                    bucketBy: .single("userId"),
                    traffic: [Traffic(key: "all", segments: .all, percentage: 100_000, enabled: true, variation: "treatment", variables: nil, variationWeights: nil, variableOverrides: nil, allocation: nil)],
                    force: nil,
                    ranges: nil
                ),
                "dependent": Feature(
                    key: "dependent",
                    hash: nil,
                    deprecated: nil,
                    required: [.withVariation(RequiredWithVariation(key: "required", variation: "treatment"))],
                    variablesSchema: nil,
                    disabledVariationValue: nil,
                    variations: nil,
                    bucketBy: .single("userId"),
                    traffic: [Traffic(key: "all", segments: .all, percentage: 100_000, enabled: true, variation: nil, variables: nil, variationWeights: nil, variableOverrides: nil, allocation: nil)],
                    force: nil,
                    ranges: nil
                ),
            ]
        )

        let sdk = createInstance(InstanceOptions(datafile: datafile))
        XCTAssertTrue(sdk.isEnabled("dependent", ["userId": .string("1")]))
    }

    func testVariableOverridePrecedenceRuleThenVariationThenDefault() {
        let schema = ResolvedVariableSchema(
            deprecated: nil,
            key: "title",
            type: "string",
            defaultValue: .string("default"),
            description: nil,
            useDefaultWhenDisabled: nil,
            disabledValue: nil
        )

        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [:],
            features: [
                "feature": Feature(
                    key: "feature",
                    hash: nil,
                    deprecated: nil,
                    required: nil,
                    variablesSchema: ["title": schema],
                    disabledVariationValue: nil,
                    variations: [
                        Variation(
                            description: nil,
                            value: "treatment",
                            weight: nil,
                            variables: ["title": .string("variation")],
                            variableOverrides: ["title": [VariableOverride(value: .string("variation-override"), conditions: .predicate(ConditionPredicate(attribute: "country", operator: "equals", value: .string("nl"))), segments: nil)]]
                        ),
                    ],
                    bucketBy: .single("userId"),
                    traffic: [
                        Traffic(
                            key: "all",
                            segments: .all,
                            percentage: 100_000,
                            enabled: true,
                            variation: "treatment",
                            variables: nil,
                            variationWeights: nil,
                            variableOverrides: ["title": [VariableOverride(value: .string("rule-override"), conditions: .predicate(ConditionPredicate(attribute: "country", operator: "equals", value: .string("de"))), segments: nil)]],
                            allocation: nil
                        ),
                    ],
                    force: nil,
                    ranges: nil
                ),
            ]
        )

        let sdk = createInstance(InstanceOptions(datafile: datafile))
        XCTAssertEqual(sdk.getVariable("feature", "title", ["userId": .string("1"), "country": .string("de")]), .string("rule-override"))
        XCTAssertEqual(sdk.getVariable("feature", "title", ["userId": .string("1"), "country": .string("nl")]), .string("variation-override"))
        XCTAssertEqual(sdk.getVariable("feature", "title", ["userId": .string("1"), "country": .string("fr")]), .string("variation"))
    }

    func testOutOfRangeReasonForMutuallyExclusiveRanges() {
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [:],
            features: [
                "exp": Feature(
                    key: "exp",
                    hash: nil,
                    deprecated: nil,
                    required: nil,
                    variablesSchema: nil,
                    disabledVariationValue: nil,
                    variations: nil,
                    bucketBy: .single("userId"),
                    traffic: [Traffic(key: "all", segments: .all, percentage: 100_000, enabled: true, variation: nil, variables: nil, variationWeights: nil, variableOverrides: nil, allocation: nil)],
                    force: nil,
                    ranges: [[0, 10_000]]
                ),
            ]
        )

        let hook = Hook(name: "force-bucket", bucketValue: { _ in 50_000 })
        let sdk = createInstance(InstanceOptions(datafile: datafile, hooks: [hook]))

        let evaluation = sdk.evaluateFlag("exp", context: ["userId": .string("1")])
        XCTAssertEqual(evaluation.reason, .outOfRange)
        XCTAssertEqual(evaluation.enabled, false)
    }

    func testVariableDisabledAndUseDefaultWhenDisabled() {
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [:],
            features: [
                "disabled": Feature(
                    key: "disabled",
                    hash: nil,
                    deprecated: nil,
                    required: nil,
                    variablesSchema: [
                        "a": ResolvedVariableSchema(deprecated: nil, key: "a", type: "string", defaultValue: .string("A-default"), description: nil, useDefaultWhenDisabled: true, disabledValue: nil),
                        "b": ResolvedVariableSchema(deprecated: nil, key: "b", type: "string", defaultValue: .string("B-default"), description: nil, useDefaultWhenDisabled: nil, disabledValue: .string("B-disabled")),
                    ],
                    disabledVariationValue: "off",
                    variations: [Variation(description: nil, value: "on", weight: nil, variables: nil, variableOverrides: nil)],
                    bucketBy: .single("userId"),
                    traffic: [Traffic(key: "all", segments: .all, percentage: 100_000, enabled: false, variation: "on", variables: nil, variationWeights: nil, variableOverrides: nil, allocation: nil)],
                    force: nil,
                    ranges: nil
                ),
            ]
        )

        let sdk = createInstance(InstanceOptions(datafile: datafile))
        XCTAssertEqual(sdk.getVariation("disabled", ["userId": .string("1")]), "off")
        XCTAssertEqual(sdk.getVariable("disabled", "a", ["userId": .string("1")]), .string("A-default"))
        XCTAssertEqual(sdk.getVariable("disabled", "b", ["userId": .string("1")]), .string("B-disabled"))
    }
}

