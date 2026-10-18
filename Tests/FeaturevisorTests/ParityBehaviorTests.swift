import XCTest
@testable import Featurevisor

final class ParityBehaviorTests: XCTestCase {
    func testRegexFlagsAreHonored() {
        let condition = Condition.predicate(
            ConditionPredicate(attribute: "browser", operator: "matches", value: .string("^firefox$"), regexFlags: "i")
        )
        XCTAssertTrue(allConditionsAreMatched(condition, context: ["browser": .string("FireFox")]))
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
                    variablesSchema: nil,
                    disabledVariationValue: nil,
                    variations: [Variation(description: nil, value: "treatment", weight: nil, variables: nil, variableOverrides: nil)],
                    bucketBy: .single("userId"),
                    traffic: [Traffic(key: "all", segments: .all, percentage: 100_000, enabled: true, variation: "treatment", variables: nil, variationWeights: nil, variableOverrides: nil, allocation: nil)],
                    force: nil
                ),
                "dependent": Feature(
                    key: "dependent",
                    hash: nil,
                    deprecated: nil,
                    requiredFeatures: [.options(FeatureCondition(feature: "required", enabled: nil, variation: "treatment"))],
                    variablesSchema: nil,
                    disabledVariationValue: nil,
                    variations: nil,
                    bucketBy: .single("userId"),
                    traffic: [Traffic(key: "all", segments: .all, percentage: 100_000, enabled: true, variation: nil, variables: nil, variationWeights: nil, variableOverrides: nil, allocation: nil)],
                    force: nil
                ),
            ]
        )

        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile))
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
                    force: nil
                ),
            ]
        )

        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile))
        XCTAssertEqual(sdk.getVariable("feature", "title", ["userId": .string("1"), "country": .string("de")]), .string("rule-override"))
        XCTAssertEqual(sdk.getVariable("feature", "title", ["userId": .string("1"), "country": .string("nl")]), .string("variation-override"))
        XCTAssertEqual(sdk.getVariable("feature", "title", ["userId": .string("1"), "country": .string("fr")]), .string("variation"))
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
                    variablesSchema: [
                        "a": ResolvedVariableSchema(deprecated: nil, key: "a", type: "string", defaultValue: .string("A-default"), description: nil, useDefaultWhenDisabled: true, disabledValue: nil),
                        "b": ResolvedVariableSchema(deprecated: nil, key: "b", type: "string", defaultValue: .string("B-default"), description: nil, useDefaultWhenDisabled: nil, disabledValue: .string("B-disabled")),
                    ],
                    disabledVariationValue: "off",
                    variations: [Variation(description: nil, value: "on", weight: nil, variables: nil, variableOverrides: nil)],
                    bucketBy: .single("userId"),
                    traffic: [Traffic(key: "all", segments: .all, percentage: 100_000, enabled: false, variation: "on", variables: nil, variationWeights: nil, variableOverrides: nil, allocation: nil)],
                    force: nil
                ),
            ]
        )

        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile))
        XCTAssertEqual(sdk.getVariation("disabled", ["userId": .string("1")]), "off")
        XCTAssertEqual(sdk.getVariable("disabled", "a", ["userId": .string("1")]), .string("A-default"))
        XCTAssertEqual(sdk.getVariable("disabled", "b", ["userId": .string("1")]), .string("B-disabled"))
    }
}
