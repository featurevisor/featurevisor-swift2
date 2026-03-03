import XCTest
@testable import Featurevisor

final class FeaturevisorTests: XCTestCase {
    func testDatafileRoundTrip() throws {
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [:],
            features: [:]
        )

        let json = try datafile.toJSON()
        let parsed = try DatafileContent.fromJSON(json)
        XCTAssertEqual(parsed.revision, "1")
    }

    func testSimpleIsEnabled() {
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [:],
            features: [
                "test": Feature(
                    key: "test",
                    hash: nil,
                    deprecated: nil,
                    required: nil,
                    variablesSchema: nil,
                    disabledVariationValue: nil,
                    variations: nil,
                    bucketBy: .single("userId"),
                    traffic: [
                        Traffic(
                            key: "1",
                            segments: .all,
                            percentage: 100_000,
                            enabled: true,
                            variation: nil,
                            variables: nil,
                            variationWeights: nil,
                            variableOverrides: nil,
                            allocation: nil
                        )
                    ],
                    force: nil,
                    ranges: nil
                )
            ]
        )

        let sdk = createInstance(InstanceOptions(datafile: datafile))
        XCTAssertTrue(sdk.isEnabled("test", ["userId": .string("123")]))
    }

    func testVariableDefaultValue() {
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [:],
            features: [
                "test": Feature(
                    key: "test",
                    hash: nil,
                    deprecated: nil,
                    required: nil,
                    variablesSchema: [
                        "color": ResolvedVariableSchema(
                            deprecated: nil,
                            key: "color",
                            type: "string",
                            defaultValue: .string("red"),
                            description: nil,
                            useDefaultWhenDisabled: nil,
                            disabledValue: nil
                        )
                    ],
                    disabledVariationValue: nil,
                    variations: nil,
                    bucketBy: .single("userId"),
                    traffic: [
                        Traffic(
                            key: "1",
                            segments: .all,
                            percentage: 100_000,
                            enabled: true,
                            variation: nil,
                            variables: nil,
                            variationWeights: nil,
                            variableOverrides: nil,
                            allocation: nil
                        )
                    ],
                    force: nil,
                    ranges: nil
                )
            ]
        )

        let sdk = createInstance(InstanceOptions(datafile: datafile))
        XCTAssertEqual(sdk.getVariableString("test", "color", ["userId": .string("123")]), "red")
    }
}
