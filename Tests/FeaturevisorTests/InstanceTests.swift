import XCTest
@testable import Featurevisor

final class InstanceTests: XCTestCase {
    func testLifecycleAndEvaluations() {
        let sdk = createInstance(InstanceOptions(datafile: TestFixtures.basicDatafile()))

        XCTAssertEqual(sdk.getRevision(), "1")
        XCTAssertTrue(sdk.isEnabled("test", ["userId": .string("123")]))
        XCTAssertEqual(sdk.getVariation("test", ["userId": .string("123")]), "control")
        XCTAssertEqual(sdk.getVariableString("test", "color", ["userId": .string("123")]), "blue")
        XCTAssertEqual(sdk.getVariableInteger("test", "count", ["userId": .string("123")]), 2)

        let all = sdk.getAllEvaluations(["userId": .string("123")])
        XCTAssertEqual(all["test"]?.enabled, true)
    }

    func testSetContextAndStickyEvents() {
        let sdk = createInstance(InstanceOptions(datafile: TestFixtures.basicDatafile()))

        let contextEvent = ConcurrencyBox(false)
        let stickyEvent = ConcurrencyBox(false)
        let u1 = sdk.on(.contextSet) { payload in
            contextEvent.value = payload.params["replaced"] == "false"
        }
        let u2 = sdk.on(.stickySet) { payload in
            stickyEvent.value = payload.params["features"] == "test"
        }

        sdk.setContext(["country": .string("nl")])
        sdk.setSticky(["test": EvaluatedFeature(enabled: true)])

        u1(); u2()

        XCTAssertTrue(contextEvent.value)
        XCTAssertTrue(stickyEvent.value)
    }
}
