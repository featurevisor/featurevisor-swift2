import XCTest
@testable import Featurevisor

final class ChildTests: XCTestCase {
    func testChildContextAndSticky() {
        let sdk = createInstance(InstanceOptions(datafile: TestFixtures.basicDatafile(), context: ["app": .string("ios")]))
        let child = sdk.spawn(["userId": .string("123")])

        XCTAssertEqual(child.getContext()["app"], .string("ios"))
        XCTAssertEqual(child.getContext()["userId"], .string("123"))

        child.setSticky(["another": EvaluatedFeature(enabled: true)])
        XCTAssertTrue(child.isEnabled("another"))
    }

    func testChildDelegatesParentEventsForDatafileSet() {
        let sdk = createInstance(InstanceOptions(datafile: TestFixtures.basicDatafile()))
        let child = sdk.spawn()

        let called = ConcurrencyBox(false)
        let unsub = child.on(.datafileSet) { _ in called.value = true }
        sdk.setDatafile(TestFixtures.basicDatafile())
        unsub()

        XCTAssertTrue(called.value)
    }
}
