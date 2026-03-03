import Foundation

public enum LogLevel: Int, Codable, CaseIterable, Sendable {
    case debug = 10
    case info = 20
    case warn = 30
    case error = 40
    case fatal = 50
}

public typealias LogHandler = @Sendable (_ level: LogLevel, _ message: String, _ details: [String: String]) -> Void

public final class Logger: @unchecked Sendable {
    public static let defaultLevel: LogLevel = .info

    private var level: LogLevel
    private let handler: LogHandler?

    public init(level: LogLevel = Logger.defaultLevel, handler: LogHandler? = nil) {
        self.level = level
        self.handler = handler
    }

    public func setLevel(_ level: LogLevel) {
        self.level = level
    }

    private func shouldLog(_ incoming: LogLevel) -> Bool {
        incoming.rawValue >= level.rawValue
    }

    private func emit(_ incoming: LogLevel, _ message: String, _ details: [String: String]) {
        guard shouldLog(incoming) else { return }
        if let handler {
            handler(incoming, message, details)
            return
        }
        let serialized = details.isEmpty ? "" : " \(details)"
        FileHandle.standardError.write(Data("[\(incoming)] \(message)\(serialized)\n".utf8))
    }

    public func debug(_ message: String, details: [String: String] = [:]) { emit(.debug, message, details) }
    public func info(_ message: String, details: [String: String] = [:]) { emit(.info, message, details) }
    public func warn(_ message: String, details: [String: String] = [:]) { emit(.warn, message, details) }
    public func error(_ message: String, details: [String: String] = [:]) { emit(.error, message, details) }
    public func fatal(_ message: String, details: [String: String] = [:]) { emit(.fatal, message, details) }
}

public func createLogger(level: LogLevel = Logger.defaultLevel, handler: LogHandler? = nil) -> Logger {
    Logger(level: level, handler: handler)
}
