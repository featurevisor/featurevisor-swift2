import Foundation
@testable import Featurevisor

enum TestFixtures {
    static func basicDatafile() -> DatafileContent {
        DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [
                "nl": Segment(key: "nl", conditions: .tree(.predicate(ConditionPredicate(attribute: "country", operator: "equals", value: .string("nl"))))),
                "de": Segment(key: "de", conditions: .tree(.predicate(ConditionPredicate(attribute: "country", operator: "equals", value: .string("de"))))),
            ],
            features: [
                "test": Feature(
                    key: "test",
                    hash: "h1",
                    deprecated: nil,
                    required: nil,
                    variablesSchema: [
                        "color": ResolvedVariableSchema(deprecated: nil, key: "color", type: "string", defaultValue: .string("red"), description: nil, useDefaultWhenDisabled: nil, disabledValue: nil),
                        "count": ResolvedVariableSchema(deprecated: nil, key: "count", type: "integer", defaultValue: .int(1), description: nil, useDefaultWhenDisabled: nil, disabledValue: nil),
                    ],
                    disabledVariationValue: nil,
                    variations: [Variation(description: nil, value: "control", weight: nil, variables: ["color": .string("blue")], variableOverrides: nil)],
                    bucketBy: .single("userId"),
                    traffic: [
                        Traffic(key: "1", segments: .all, percentage: 100_000, enabled: true, variation: "control", variables: ["count": .int(2)], variationWeights: nil, variableOverrides: nil, allocation: nil),
                    ],
                    force: [
                        Force(conditions: .predicate(ConditionPredicate(attribute: "userId", operator: "equals", value: .string("forced"))), segments: nil, enabled: true, variation: "control", variables: ["color": .string("green")]),
                    ],
                    ranges: nil
                ),
            ]
        )
    }
}
