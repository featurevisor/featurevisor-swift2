import Foundation

final class ConcurrencyBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: T

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }

    init(_ value: T) { self.storedValue = value }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&storedValue)
        lock.unlock()
    }
}
