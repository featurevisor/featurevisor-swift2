import Foundation

public enum LogLevel: Int, Codable, CaseIterable, Sendable {
    case debug = 10
    case info = 20
    case warn = 30
    case error = 40
    case fatal = 50
}

typealias LogHandler = @Sendable (_ level: LogLevel, _ message: String, _ details: [String: String]) -> Void

final class Logger: @unchecked Sendable {
    static let defaultLevel: LogLevel = .info

    private var level: LogLevel
    private var handler: LogHandler?
    private let lock = FeaturevisorLock()

    init(level: LogLevel = Logger.defaultLevel, handler: LogHandler? = nil) {
        self.level = level
        self.handler = handler
    }

    func setLevel(_ level: LogLevel) {
        lock.withLock { self.level = level }
    }

    func setHandler(_ handler: LogHandler?) {
        lock.withLock { self.handler = handler }
    }

    static func writeToConsole(_ level: LogLevel, _ message: String, _ details: [String: String]) {
        let serialized = details.isEmpty ? "" : " \(details)"
        FileHandle.standardError.write(Data("[Featurevisor] \(message)\(serialized)\n".utf8))
    }

    private func emit(_ incoming: LogLevel, _ message: String, _ details: [String: String]) {
        let snapshot = lock.withLock { (incoming.rawValue >= self.level.rawValue, self.handler) }
        guard snapshot.0 else { return }
        if let handler = snapshot.1 {
            handler(incoming, message, details)
            return
        }
        Logger.writeToConsole(incoming, message, details)
    }

    func debug(_ message: String, details: [String: String] = [:]) { emit(.debug, message, details) }
    func info(_ message: String, details: [String: String] = [:]) { emit(.info, message, details) }
    func warn(_ message: String, details: [String: String] = [:]) { emit(.warn, message, details) }
    func error(_ message: String, details: [String: String] = [:]) { emit(.error, message, details) }
    func fatal(_ message: String, details: [String: String] = [:]) { emit(.fatal, message, details) }
}

func createLogger(level: LogLevel = Logger.defaultLevel, handler: LogHandler? = nil) -> Logger {
    Logger(level: level, handler: handler)
}
