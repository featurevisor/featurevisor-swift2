import XCTest
@testable import Featurevisor

final class IndexTests: XCTestCase {
    func testCreateInstanceExists() {
        let instance = createInstance()
        XCTAssertNotNil(instance)
    }
}
