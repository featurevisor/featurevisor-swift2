import XCTest
@testable import Featurevisor

final class HelpersTests: XCTestCase {
    func testGetValueByType() {
        XCTAssertEqual(getValueByType(.string("10"), fieldType: "integer"), .int(10))
        XCTAssertEqual(getValueByType(.string("10.2"), fieldType: "double"), .double(10.2))
        XCTAssertEqual(getValueByType(.bool(true), fieldType: "boolean"), .bool(true))
        XCTAssertEqual(getValueByType(.string("a"), fieldType: "string"), .string("a"))
    }
}
