import Foundation

public enum LogLevel: Int, Codable, CaseIterable, Sendable {
    case debug = 10
    case info = 20
    case warn = 30
    case error = 40
    case fatal = 50
}

public struct FeaturevisorDiagnostic: Sendable {
    public var level: LogLevel
    public var code: String
    public var message: String
    public var module: String?
    public var moduleName: String?
    public var originalError: String?
    public var details: [String: AnyValue]

    public init(
        level: LogLevel,
        code: String,
        message: String,
        module: String? = nil,
        moduleName: String? = nil,
        originalError: String? = nil,
        details: [String: AnyValue] = [:]
    ) {
        self.level = level
        self.code = code
        self.message = message
        self.module = module
        self.moduleName = moduleName
        self.originalError = originalError
        self.details = details
    }
}

public typealias FeaturevisorModuleReportedDiagnostic = FeaturevisorDiagnostic
public typealias FeaturevisorDiagnosticHandler = @Sendable (_ diagnostic: FeaturevisorDiagnostic) -> Void
public typealias FeaturevisorUnsubscribe = () -> Void
public typealias FeaturevisorModuleOnDiagnostic = @Sendable (_ handler: @escaping FeaturevisorDiagnosticHandler, _ options: FeaturevisorModuleDiagnosticOptions) -> FeaturevisorUnsubscribe

public struct FeaturevisorModuleDiagnosticOptions: Sendable {
    public var logLevel: LogLevel

    public init(logLevel: LogLevel = .info) {
        self.logLevel = logLevel
    }
}

func shouldLogDiagnostic(currentLevel: LogLevel, diagnosticLevel: LogLevel) -> Bool {
    diagnosticLevel.rawValue >= currentLevel.rawValue
}

final class EvaluationDiagnosticAudience: @unchecked Sendable {
    private let lock = FeaturevisorLock()
    private var logLevel: LogLevel
    private var subscriptions: [UUID: LogLevel] = [:]

    init(logLevel: LogLevel) {
        self.logLevel = logLevel
    }

    func setLogLevel(_ level: LogLevel) {
        lock.withLock { logLevel = level }
    }

    func addSubscription(id: UUID, logLevel: LogLevel) {
        lock.withLock { subscriptions[id] = logLevel }
    }

    func removeSubscription(id: UUID) {
        lock.withLock { subscriptions[id] = nil }
    }

    func removeAllSubscriptions() {
        lock.withLock { subscriptions.removeAll(keepingCapacity: false) }
    }

    func shouldReport(_ level: LogLevel) -> Bool {
        lock.withLock {
            level == .error ||
                shouldLogDiagnostic(currentLevel: logLevel, diagnosticLevel: level) ||
                subscriptions.values.contains {
                    shouldLogDiagnostic(currentLevel: $0, diagnosticLevel: level)
                }
        }
    }
}

func writeDiagnosticToConsole(_ diagnostic: FeaturevisorDiagnostic) {
    let serialized = diagnostic.details.isEmpty ? "" : " \(diagnostic.details)"
    FileHandle.standardError.write(Data("[Featurevisor] \(diagnostic.message)\(serialized)\n".utf8))
}
