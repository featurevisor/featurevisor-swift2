import Foundation

public struct ConfigureBucketKeyOptions: Sendable {
    public var featureKey: FeatureKey
    public var context: Context
    public var bucketBy: BucketBy
    public var bucketKey: String

    public init(featureKey: FeatureKey, context: Context, bucketBy: BucketBy, bucketKey: String) {
        self.featureKey = featureKey
        self.context = context
        self.bucketBy = bucketBy
        self.bucketKey = bucketKey
    }
}

public struct ConfigureBucketValueOptions: Sendable {
    public var featureKey: FeatureKey
    public var bucketKey: String
    public var context: Context
    public var bucketValue: Int

    public init(featureKey: FeatureKey, bucketKey: String, context: Context, bucketValue: Int) {
        self.featureKey = featureKey
        self.bucketKey = bucketKey
        self.context = context
        self.bucketValue = bucketValue
    }
}

public struct FeaturevisorModuleApi: Sendable {
    public var getRevision: @Sendable () -> String
    public var reportDiagnostic: @Sendable (FeaturevisorModuleReportedDiagnostic) -> Void
    private var onDiagnosticHandler: FeaturevisorModuleOnDiagnostic

    public init(
        getRevision: @escaping @Sendable () -> String,
        onDiagnostic: @escaping FeaturevisorModuleOnDiagnostic,
        reportDiagnostic: @escaping @Sendable (FeaturevisorModuleReportedDiagnostic) -> Void
    ) {
        self.getRevision = getRevision
        self.reportDiagnostic = reportDiagnostic
        self.onDiagnosticHandler = onDiagnostic
    }

    @discardableResult
    public func onDiagnostic(
        _ handler: @escaping FeaturevisorDiagnosticHandler,
        options: FeaturevisorModuleDiagnosticOptions = FeaturevisorModuleDiagnosticOptions()
    ) -> FeaturevisorUnsubscribe {
        onDiagnosticHandler(handler, options)
    }
}

public struct FeaturevisorModule: Sendable {
    let id: UUID

    public var name: String?
    public var setup: (@Sendable (FeaturevisorModuleApi) -> Void)?
    public var before: (@Sendable (EvaluateOptions) -> EvaluateOptions)?
    public var bucketKey: (@Sendable (ConfigureBucketKeyOptions) -> String)?
    public var bucketValue: (@Sendable (ConfigureBucketValueOptions) -> Int)?
    public var after: (@Sendable (Evaluation, EvaluateOptions) -> Evaluation)?
    public var close: (@Sendable () throws -> Void)?

    public init(
        name: String? = nil,
        setup: (@Sendable (FeaturevisorModuleApi) -> Void)? = nil,
        before: (@Sendable (EvaluateOptions) -> EvaluateOptions)? = nil,
        bucketKey: (@Sendable (ConfigureBucketKeyOptions) -> String)? = nil,
        bucketValue: (@Sendable (ConfigureBucketValueOptions) -> Int)? = nil,
        after: (@Sendable (Evaluation, EvaluateOptions) -> Evaluation)? = nil,
        close: (@Sendable () throws -> Void)? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.setup = setup
        self.before = before
        self.bucketKey = bucketKey
        self.bucketValue = bucketValue
        self.after = after
        self.close = close
    }
}

final class ModulesManager: @unchecked Sendable {
    private var modules: [FeaturevisorModule] = []
    private let reportDiagnostic: @Sendable (FeaturevisorDiagnostic, FeaturevisorModule?) -> Void
    private let getModuleApi: @Sendable (FeaturevisorModule) -> FeaturevisorModuleApi
    private let clearModuleDiagnosticSubscriptions: @Sendable (FeaturevisorModule) -> Void

    public init(
        modules: [FeaturevisorModule],
        reportDiagnostic: @escaping @Sendable (FeaturevisorDiagnostic, FeaturevisorModule?) -> Void,
        getModuleApi: @escaping @Sendable (FeaturevisorModule) -> FeaturevisorModuleApi,
        clearModuleDiagnosticSubscriptions: @escaping @Sendable (FeaturevisorModule) -> Void
    ) {
        self.reportDiagnostic = reportDiagnostic
        self.getModuleApi = getModuleApi
        self.clearModuleDiagnosticSubscriptions = clearModuleDiagnosticSubscriptions

        for module in modules {
            _ = add(module)
        }
    }

    @discardableResult
    public func add(_ module: FeaturevisorModule) -> FeaturevisorUnsubscribe? {
        if let name = module.name, modules.contains(where: { $0.name == name }) {
            reportDiagnostic(
                FeaturevisorDiagnostic(
                    level: .error,
                    code: "duplicate_module",
                    message: "Duplicate module name",
                    moduleName: name
                ),
                nil
            )
            return nil
        }

        module.setup?(getModuleApi(module))
        modules.append(module)

        return { [weak self] in
            guard let self else { return }
            let existed = self.modules.contains(where: { $0.id == module.id })
            self.modules.removeAll(where: { $0.id == module.id })
            self.clearModuleDiagnosticSubscriptions(module)
            if existed {
                self.closeModule(module)
            }
        }
    }

    public func remove(_ name: String) {
        let removed = modules.filter { $0.name == name }
        modules.removeAll(where: { $0.name == name })
        for module in removed {
            clearModuleDiagnosticSubscriptions(module)
            closeModule(module)
        }
    }

    public func getAll() -> [FeaturevisorModule] {
        modules
    }

    public func closeAll() {
        let existing = modules
        modules = []

        for module in existing {
            clearModuleDiagnosticSubscriptions(module)
            closeModule(module)
        }
    }

    private func closeModule(_ module: FeaturevisorModule) {
        do {
            try module.close?()
        } catch {
            reportDiagnostic(
                FeaturevisorDiagnostic(
                    level: .error,
                    code: "module_close_error",
                    message: "Module close failed",
                    moduleName: module.name,
                    originalError: String(describing: error)
                ),
                nil
            )
        }
    }
}
