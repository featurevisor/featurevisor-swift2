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
}
