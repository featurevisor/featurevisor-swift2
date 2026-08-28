import XCTest
@testable import Featurevisor

final class EmitterTests: XCTestCase {
    func testSubscribeUnsubscribe() {
        let emitter = Emitter()
        let count = ConcurrencyBox(0)

        let unsub = emitter.on(.contextSet) { _ in count.value += 1 }
        emitter.trigger(.contextSet)
        unsub()
        emitter.trigger(.contextSet)

        XCTAssertEqual(count.value, 1)
    }

    func testTriggerUsesListenerSnapshot() {
        let emitter = Emitter()
        let calls = ConcurrencyBox<[String]>([])
        let unsubscribeSecond = ConcurrencyBox<(() -> Void)?>(nil)

        _ = emitter.on(.stickyFeaturesSet) { _ in
            calls.value.append("first")
            unsubscribeSecond.value?()
        }
        unsubscribeSecond.value = emitter.on(.stickyFeaturesSet) { _ in
            calls.value.append("second")
        }

        emitter.trigger(.stickyFeaturesSet)
        emitter.trigger(.stickyFeaturesSet)

        XCTAssertEqual(calls.value, ["first", "second", "first"])
    }
}
