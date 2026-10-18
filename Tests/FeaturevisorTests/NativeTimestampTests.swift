import Foundation
import XCTest
@testable import Featurevisor

final class NativeTimestampTests: XCTestCase {
    private func valueIsMatched(_ actual: AnyValue, operator op: String, expected: AnyValue) -> Bool {
        allConditionsAreMatched(
            .predicate(.init(attribute: "date", operator: op, value: expected)),
            context: ["date": actual]
        )
    }

    func testStringOnlyTimestampBoundaries() {
        for boundary in ["2026-01-01T00:00:00.000Z", "1969-12-31T23:59:59.999Z"] {
            let fractional = boundary.replacingOccurrences(of: "Z", with: "999999Z")
            for op in ["before", "after"] {
                XCTAssertFalse(valueIsMatched(.string(fractional), operator: op, expected: .string(boundary)))
                let preceding = boundary == "2026-01-01T00:00:00.000Z" ? "2025-12-31T23:59:59.999Z" : "1969-12-31T23:59:59.998Z"
                let following = boundary == "2026-01-01T00:00:00.000Z" ? "2026-01-01T00:00:00.001Z" : "1970-01-01T00:00:00.000Z"
                XCTAssertEqual(valueIsMatched(.string(fractional), operator: op, expected: .string(preceding)), op == "after")
                XCTAssertEqual(valueIsMatched(.string(fractional), operator: op, expected: .string(following)), op == "before")
            }
        }
        XCTAssertTrue(valueIsMatched(.string("0001-01-01T00:00:00Z"), operator: "before", expected: .string("2026-01-01T00:00:00Z")))
        XCTAssertTrue(valueIsMatched(.string("9999-12-31T23:59:59.999Z"), operator: "after", expected: .string("2026-01-01T00:00:00Z")))
        for offset in ["+14:00", "-14:00"] {
            XCTAssertTrue(valueIsMatched(.string("2026-01-01T00:00:00\(offset)"), operator: "before", expected: .string("2026-01-02T00:00:00Z")))
        }
        for actual: AnyValue in [
            .string("2026-01-01"), .string("2026-01-01T00:00:00"),
            .string("0000-12-31T23:00:00-01:00"), .string("10000-01-01T00:00:00Z"),
            .string("0001-01-01T00:00:00+01:00"), .string("9999-12-31T23:59:59-01:00"),
            .string("2026-01-01T00:00:00+14:01"), .string("2026-01-01T00:00:00-15:00"),
            .string("2026-02-30T00:00:00Z"), .int(1767225600000), .null,
        ] {
            for op in ["before", "after"] {
                XCTAssertFalse(valueIsMatched(actual, operator: op, expected: .string("2026-01-01T00:00:00Z")), "\(actual)")
                XCTAssertFalse(valueIsMatched(.string("2026-01-01T00:00:00Z"), operator: op, expected: actual), "\(actual)")
            }
        }
    }
}
