import Foundation

public enum EventName: String, Sendable {
    case datafileSet = "datafile_set"
    case contextSet = "context_set"
    case stickySet = "sticky_set"
}

public struct EventPayload: Sendable {
    public var params: [String: String]
    public init(_ params: [String: String] = [:]) { self.params = params }
}

public typealias EventCallback = @Sendable (_ payload: EventPayload) -> Void

public final class Emitter: @unchecked Sendable {
    private var listeners: [EventName: [UUID: EventCallback]] = [:]

    public init() {}

    @discardableResult
    public func on(_ eventName: EventName, callback: @escaping EventCallback) -> () -> Void {
        let id = UUID()
        listeners[eventName, default: [:]][id] = callback
        return { [weak self] in
            self?.listeners[eventName]?[id] = nil
        }
    }

    public func trigger(_ eventName: EventName, payload: EventPayload = EventPayload()) {
        if let callbacks = listeners[eventName]?.values {
            for callback in callbacks {
                callback(payload)
            }
        }
    }

    public func clearAll() {
        listeners.removeAll()
    }
}
