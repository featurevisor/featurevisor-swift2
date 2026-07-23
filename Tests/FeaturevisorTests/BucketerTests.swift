import XCTest
@testable import Featurevisor

final class BucketerTests: XCTestCase {
    func testBucketedNumberRange() {
        let value = getBucketedNumber("123.test")
        XCTAssertGreaterThanOrEqual(value, 0)
        XCTAssertLessThanOrEqual(value, MAX_BUCKETED_NUMBER)
    }

    func testBucketKeyPlainAndOr() {
        let plain = getBucketKey(featureKey: "f", bucketBy: .single("userId"), context: ["userId": .string("123")])
        XCTAssertEqual(plain, "123.f")

        let and = getBucketKey(featureKey: "f", bucketBy: .and(["userId", "orgId"]), context: ["userId": .string("123"), "orgId": .string("456")])
        XCTAssertEqual(and, "123.456.f")

        let or = getBucketKey(featureKey: "f", bucketBy: .or(BucketByOr(or: ["userId", "deviceId"])), context: ["deviceId": .string("abc")])
        XCTAssertEqual(or, "abc.f")
    }

    func testNestedPathsAndJavaScriptStringification() {
        let context: Context = [
            "user": .object(["id": .string("123")]),
            "empty": .null,
            "enabled": .bool(false),
            "values": .array([.int(1), .bool(true), .null]),
            "object": .object(["id": .int(1)]),
        ]
        XCTAssertEqual(
            getBucketKey(
                featureKey: "f",
                bucketBy: .and(["user.id", "empty", "enabled", "values", "object"]),
                context: context
            ),
            "123..false.1,true,.[object Object].f"
        )
    }

    func testWholeDoubleAndNegativeZeroStringification() {
        XCTAssertEqual(
            getBucketKey(
                featureKey: "f",
                bucketBy: .and(["whole", "negativeZero", "small", "large"]),
                context: [
                    "whole": .double(1.0),
                    "negativeZero": .double(-0.0),
                    "small": .double(1e-6),
                    "large": .double(1e21),
                ]
            ),
            "1.0.0.000001.1e+21.f"
        )
    }
}
