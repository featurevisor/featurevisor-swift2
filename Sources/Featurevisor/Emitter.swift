import Foundation

public enum EventName: String, Sendable {
    case datafileSet = "datafile_set"
    case contextSet = "context_set"
    case stickyFeaturesSet = "sticky_features_set"
    case stickyVariablesSet = "sticky_variables_set"
    case error
}

public struct EventPayload: Sendable {
    public var params: [String: AnyValue]
    public init(_ params: [String: AnyValue] = [:]) { self.params = params }
}

public typealias EventCallback = @Sendable (_ payload: EventPayload) -> Void

final class Emitter: @unchecked Sendable {
    private struct Listener {
        let id: UUID
        let callback: EventCallback
    }

    private var listeners: [EventName: [Listener]] = [:]
    private let lock = FeaturevisorLock()
    private var closed = false

    public init() {}

    @discardableResult
    public func on(_ eventName: EventName, callback: @escaping EventCallback) -> () -> Void {
        let id = UUID()
        let added = lock.withLock { () -> Bool in
            guard !closed else { return false }
            listeners[eventName, default: []].append(Listener(id: id, callback: callback))
            return true
        }
        guard added else { return {} }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.listeners[eventName]?.removeAll(where: { $0.id == id })
            }
        }
    }

    public func trigger(_ eventName: EventName, payload: EventPayload = EventPayload()) {
        let callbacks = lock.withLock { closed ? [] : listeners[eventName]?.map { $0.callback } ?? [] }
        for callback in callbacks {
            callback(payload)
        }
    }

    public func clearAll() {
        lock.withLock {
            closed = true
            listeners.removeAll()
        }
    }
}
