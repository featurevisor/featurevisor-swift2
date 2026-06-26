import Foundation

public enum EventName: String, Sendable {
    case datafileSet = "datafile_set"
    case contextSet = "context_set"
    case stickySet = "sticky_set"
    case error
}

public struct EventPayload: Sendable {
    public var params: [String: AnyValue]
    public init(_ params: [String: AnyValue] = [:]) { self.params = params }
}

public typealias EventCallback = @Sendable (_ payload: EventPayload) -> Void

public final class Emitter: @unchecked Sendable {
    private struct Listener {
        let id: UUID
        let callback: EventCallback
    }

    private var listeners: [EventName: [Listener]] = [:]

    public init() {}

    @discardableResult
    public func on(_ eventName: EventName, callback: @escaping EventCallback) -> () -> Void {
        let id = UUID()
        listeners[eventName, default: []].append(Listener(id: id, callback: callback))
        return { [weak self] in
            self?.listeners[eventName]?.removeAll(where: { $0.id == id })
        }
    }

    public func trigger(_ eventName: EventName, payload: EventPayload = EventPayload()) {
        let callbacks = listeners[eventName]?.map { $0.callback } ?? []
        for callback in callbacks {
            callback(payload)
        }
    }

    public func clearAll() {
        listeners.removeAll()
    }
}
