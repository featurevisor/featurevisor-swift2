import XCTest
@testable import Featurevisor

final class ConditionsTests: XCTestCase {
    func testEqualsAndDotPath() {
        let c = Condition.predicate(.init(attribute: "browser.type", operator: "equals", value: .string("chrome")))
        let matched = allConditionsMatched(c, context: ["browser": .object(["type": .string("chrome")])])
        XCTAssertTrue(matched)
    }

    func testInAndNotIn() {
        let inCondition = Condition.predicate(.init(attribute: "country", operator: "in", value: .array([.string("nl"), .string("de")])))
        XCTAssertTrue(allConditionsMatched(inCondition, context: ["country": .string("nl")]))

        let notInCondition = Condition.predicate(.init(attribute: "country", operator: "notIn", value: .array([.string("nl"), .string("de")])))
        XCTAssertTrue(allConditionsMatched(notInCondition, context: ["country": .string("us")]))
    }

    func testSemverComparisons() {
        let gte = Condition.predicate(.init(attribute: "version", operator: "semverGreaterThanOrEquals", value: .string("1.2.3")))
        XCTAssertTrue(allConditionsMatched(gte, context: ["version": .string("1.2.3")]))

        let lte = Condition.predicate(.init(attribute: "version", operator: "semverLessThanOrEquals", value: .string("2.0.0")))
        XCTAssertTrue(allConditionsMatched(lte, context: ["version": .string("1.9.0")]))
    }

    func testBeforeAfter() {
        let before = Condition.predicate(.init(attribute: "date", operator: "before", value: .string("2024-01-01T00:00:00Z")))
        XCTAssertTrue(allConditionsMatched(before, context: ["date": .string("2023-12-31T23:00:00Z")]))

        let after = Condition.predicate(.init(attribute: "date", operator: "after", value: .string("2024-01-01T00:00:00Z")))
        XCTAssertTrue(allConditionsMatched(after, context: ["date": .string("2024-01-02T00:00:00Z")]))
    }

    func testNotNegatesImplicitAnd() {
        let countryUS = Condition.predicate(.init(attribute: "country", operator: "equals", value: .string("us")))
        let mobile = Condition.predicate(.init(attribute: "device", operator: "equals", value: .string("mobile")))

        XCTAssertFalse(allConditionsMatched(.not([countryUS, mobile]), context: ["country": .string("us"), "device": .string("mobile")]))
        XCTAssertTrue(allConditionsMatched(.not([countryUS, mobile]), context: ["country": .string("us"), "device": .string("desktop")]))
        XCTAssertFalse(allConditionsMatched(.not([]), context: [:]))
    }

    func testNotWithNestedOrMeansNoneMatch() {
        let countryUS = Condition.predicate(.init(attribute: "country", operator: "equals", value: .string("us")))
        let countryNL = Condition.predicate(.init(attribute: "country", operator: "equals", value: .string("nl")))

        XCTAssertFalse(allConditionsMatched(.not([.or([countryUS, countryNL])]), context: ["country": .string("us")]))
        XCTAssertTrue(allConditionsMatched(.not([.or([countryUS, countryNL])]), context: ["country": .string("de")]))
    }
}
