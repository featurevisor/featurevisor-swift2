import XCTest
@testable import Featurevisor

final class HelpersTests: XCTestCase {
    func testGetValueByType() {
        XCTAssertNil(getValueByType(.string("10"), fieldType: "integer"))
        XCTAssertNil(getValueByType(.string("10.2"), fieldType: "double"))
        XCTAssertNil(getValueByType(.double(10.2), fieldType: "integer"))
        XCTAssertNil(getValueByType(.string("true"), fieldType: "boolean"))
        XCTAssertEqual(getValueByType(.bool(true), fieldType: "boolean"), .bool(true))
        XCTAssertEqual(getValueByType(.string("a"), fieldType: "string"), .string("a"))
    }
}
