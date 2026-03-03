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
}
