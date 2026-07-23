import XCTest
@testable import Featurevisor

final class ConditionsTests: XCTestCase {
    func testEqualsAndDotPath() {
        let c = Condition.predicate(.init(attribute: "browser.type", operator: "equals", value: .string("chrome")))
        let matched = allConditionsAreMatched(c, context: ["browser": .object(["type": .string("chrome")])])
        XCTAssertTrue(matched)
    }

    func testInAndNotIn() {
        let inCondition = Condition.predicate(.init(attribute: "country", operator: "in", value: .array([.string("nl"), .string("de")])))
        XCTAssertTrue(allConditionsAreMatched(inCondition, context: ["country": .string("nl")]))

        let notInCondition = Condition.predicate(.init(attribute: "country", operator: "notIn", value: .array([.string("nl"), .string("de")])))
        XCTAssertTrue(allConditionsAreMatched(notInCondition, context: ["country": .string("us")]))
    }

    func testJavaScriptPrimitiveAndPresenceSemantics() {
        XCTAssertFalse(conditionIsMatched(
            .init(attribute: "value", operator: "equals", value: .int(1)),
            context: ["value": .string("1")]
        ))
        XCTAssertFalse(conditionIsMatched(
            .init(attribute: "value", operator: "equals", value: .int(1)),
            context: ["value": .bool(true)]
        ))
        XCTAssertTrue(conditionIsMatched(
            .init(attribute: "value", operator: "exists"),
            context: ["value": .null]
        ))
        XCTAssertFalse(conditionIsMatched(
            .init(attribute: "value", operator: "notExists"),
            context: ["value": .null]
        ))
        XCTAssertFalse(conditionIsMatched(
            .init(attribute: "value", operator: "greaterThan", value: .int(1)),
            context: ["value": .string("2")]
        ))
    }

    func testIncludesSupportsAllPrimitiveValuesAndInRejectsArrays() {
        let context: Context = ["values": .array([.int(1), .bool(true), .null])]
        XCTAssertTrue(conditionIsMatched(.init(attribute: "values", operator: "includes", value: .int(1)), context: context))
        XCTAssertTrue(conditionIsMatched(.init(attribute: "values", operator: "includes", value: .bool(true)), context: context))
        XCTAssertTrue(conditionIsMatched(.init(attribute: "values", operator: "includes", value: .null), context: context))
        XCTAssertFalse(conditionIsMatched(
            .init(attribute: "values", operator: "in", value: .array([.int(1)])),
            context: context
        ))
    }

    func testSemverComparisons() {
        let gte = Condition.predicate(.init(attribute: "version", operator: "semverGreaterThanOrEquals", value: .string("1.2.3")))
        XCTAssertTrue(allConditionsAreMatched(gte, context: ["version": .string("1.2.3")]))

        let lte = Condition.predicate(.init(attribute: "version", operator: "semverLessThanOrEquals", value: .string("2.0.0")))
        XCTAssertTrue(allConditionsAreMatched(lte, context: ["version": .string("1.9.0")]))

        let prerelease = Condition.predicate(.init(attribute: "version", operator: "semverLessThan", value: .string("1.2.3")))
        XCTAssertTrue(allConditionsAreMatched(prerelease, context: ["version": .string("1.2.3-beta.1")]))

        let build = Condition.predicate(.init(attribute: "version", operator: "semverEquals", value: .string("1.2.3+build.9")))
        XCTAssertTrue(allConditionsAreMatched(build, context: ["version": .string("1.2.3+build.5")]))

        XCTAssertEqual(try compareVersions("v1.2.3", "1.2.3"), .equal)
        XCTAssertEqual(try compareVersions("1.2.*", "1.2.9"), .equal)
        XCTAssertThrowsError(try compareVersions("1.2.3-", "1.2.3"))
        XCTAssertThrowsError(try compareVersions("1.2.3-alpha!", "1.2.3"))
        XCTAssertThrowsError(try compareVersions("1.2.3.4.5", "1.2.3"))
    }

    func testBeforeAfter() {
        let before = Condition.predicate(.init(attribute: "date", operator: "before", value: .string("2024-01-01T00:00:00Z")))
        XCTAssertTrue(allConditionsAreMatched(before, context: ["date": .string("2023-12-31T23:00:00Z")]))
        XCTAssertFalse(allConditionsAreMatched(before, context: ["date": .string("2023-12-31T23:00:00")]))
        XCTAssertFalse(allConditionsAreMatched(before, context: ["date": .string("2024-01-01T01:00:00+01:00")]))

        let after = Condition.predicate(.init(attribute: "date", operator: "after", value: .string("2024-01-01T00:00:00Z")))
        XCTAssertTrue(allConditionsAreMatched(after, context: ["date": .string("2024-01-02T00:00:00Z")]))

        let fractional = Condition.predicate(.init(
            attribute: "date",
            operator: "before",
            value: .string("2024-01-01T00:00:00.500Z")
        ))
        XCTAssertTrue(allConditionsAreMatched(
            fractional,
            context: ["date": .string("2024-01-01T00:00:00.250Z")]
        ))
        XCTAssertTrue(allConditionsAreMatched(
            fractional,
            context: ["date": .string("2024-01-01T01:00:00.250+01:00")]
        ))
    }

    func testNotNegatesImplicitAnd() {
        let countryUS = Condition.predicate(.init(attribute: "country", operator: "equals", value: .string("us")))
        let mobile = Condition.predicate(.init(attribute: "device", operator: "equals", value: .string("mobile")))

        XCTAssertFalse(allConditionsAreMatched(.not([countryUS, mobile]), context: ["country": .string("us"), "device": .string("mobile")]))
        XCTAssertTrue(allConditionsAreMatched(.not([countryUS, mobile]), context: ["country": .string("us"), "device": .string("desktop")]))
        XCTAssertFalse(allConditionsAreMatched(.not([]), context: [:]))
    }

    func testNotWithNestedOrMeansNoneMatch() {
        let countryUS = Condition.predicate(.init(attribute: "country", operator: "equals", value: .string("us")))
        let countryNL = Condition.predicate(.init(attribute: "country", operator: "equals", value: .string("nl")))

        XCTAssertFalse(allConditionsAreMatched(.not([.or([countryUS, countryNL])]), context: ["country": .string("us")]))
        XCTAssertTrue(allConditionsAreMatched(.not([.or([countryUS, countryNL])]), context: ["country": .string("de")]))
    }
}
