import Foundation

final class ConcurrencyBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
