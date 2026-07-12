import XCTest
@testable import Featurevisor

final class IndexTests: XCTestCase {
    func testCreateFeaturevisorExists() {
        let instance = createFeaturevisor()
        XCTAssertNotNil(instance)
    }
}
