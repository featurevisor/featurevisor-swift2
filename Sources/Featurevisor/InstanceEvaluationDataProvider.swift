import Foundation

final class InstanceEvaluationDataProvider: @unchecked Sendable {
    private let schemaVersion: String
    private let revision: String
    private let segments: [SegmentKey: Segment]
    private let features: [FeatureKey: Feature]
    private let variables: [VariableKey: GlobalVariable]
    private let reportDiagnostic: FeaturevisorDiagnosticHandler
    private var dependencyIndex: DatafileDependencyIndex?
    private var retainedKeys: [Set<String>] = [[], [], []]
    private var retainedEdgeKeys: [Set<String>] = [[], [], []]
    private var parsedSegments: [SegmentKey: Segment] = [:]
    private var normalizedFeatures: [FeatureKey: Feature] = [:]
    private var normalizedVariables: [VariableKey: GlobalVariable] = [:]
    private var entityCacheEnabled = true
    private var regexCache: [String: NSRegularExpression] = [:]
    private let lock = FeaturevisorLock()

    init(datafile: DatafileContent, reportDiagnostic: @escaping FeaturevisorDiagnosticHandler, previous: InstanceEvaluationDataProvider? = nil, incoming: DatafileContent? = nil, replace: Bool = false) {
        self.schemaVersion = datafile.schemaVersion
        self.revision = datafile.revision
        self.segments = datafile.segments
        self.features = datafile.features
        self.variables = datafile.variables ?? [:]
        self.reportDiagnostic = reportDiagnostic
        if let previous, let incoming,
           !previous.features.isEmpty || !previous.variables.isEmpty || !previous.segments.isEmpty {
            if !replace {
                retainedKeys = [
                    Set(previous.features.keys).subtracting(incoming.features.keys).intersection(features.keys),
                    Set(previous.variables.keys).subtracting((incoming.variables ?? [:]).keys).intersection(variables.keys),
                    Set(previous.segments.keys).subtracting(incoming.segments.keys).intersection(segments.keys),
                ]
                previous.lock.withLock {
                    self.parsedSegments = previous.parsedSegments.filter { retainedKeys[2].contains($0.key) }
                    self.normalizedFeatures = previous.normalizedFeatures.filter { retainedKeys[0].contains($0.key) }
                    self.normalizedVariables = previous.normalizedVariables.filter { retainedKeys[1].contains($0.key) }
                }
            }
            // Equal incoming definitions may retain edges, but never normalization or diagnostics.
            retainedEdgeKeys = retainedKeys
            for (key, value) in incoming.features where previous.features[key] == value {
                retainedEdgeKeys[0].insert(key)
            }
            for (key, value) in incoming.variables ?? [:] where previous.variables[key] == value {
                retainedEdgeKeys[1].insert(key)
            }
            for (key, value) in incoming.segments where previous.segments[key] == value {
                retainedEdgeKeys[2].insert(key)
            }
        }
    }

    func getRevision() -> String { revision }
    func getSchemaVersion() -> String { schemaVersion }
    func getFeatureKeys() -> [FeatureKey] { Array(features.keys) }
    func getRawFeature(_ key: FeatureKey) -> Feature? { features[key] }
    func getRawGlobalVariable(_ key: VariableKey) -> GlobalVariable? { variables[key] }
    func getRawSegment(_ key: SegmentKey) -> Segment? { segments[key] }
    func retainsSegment(_ key: SegmentKey) -> Bool { retainedKeys[2].contains(key) }

    func getFeature(_ key: FeatureKey) -> Feature? {
        var errors: [FeaturevisorDiagnostic] = []
        let result = lock.withLock { () -> Feature? in
            if let cached = normalizedFeatures[key] { return cached }
            guard let value = features[key] else { return nil }
            var normalizer = EntityNormalizer(entityType: "feature", entityKey: key)
            let result = normalizer.feature(value)
            if entityCacheEnabled { normalizedFeatures[key] = result }
            errors = normalizer.errors
            return result
        }
        errors.forEach(reportDiagnostic)
        return result
    }
    func getGlobalVariableKeys() -> [VariableKey] { Array(variables.keys) }
    func getGlobalVariable(_ key: VariableKey) -> GlobalVariable? {
        var errors: [FeaturevisorDiagnostic] = []
        let result = lock.withLock { () -> GlobalVariable? in
            if let cached = normalizedVariables[key] { return cached }
            guard let value = variables[key] else { return nil }
            var normalizer = EntityNormalizer(entityType: "variable", entityKey: key)
            let result = normalizer.variable(value)
            if entityCacheEnabled { normalizedVariables[key] = result }
            errors = normalizer.errors
            return result
        }
        errors.forEach(reportDiagnostic)
        return result
    }
    func getSegmentKeys() -> [SegmentKey] { Array(segments.keys) }
    func getDependencyIndex() -> DatafileDependencyIndex {
        lock.withLock {
            if let dependencyIndex { return dependencyIndex }
            let index = createDatafileDependencyIndex(DatafileContent(
                schemaVersion: schemaVersion, revision: revision,
                segments: segments, features: features, variables: variables
            ))
            if entityCacheEnabled { dependencyIndex = index }
            return index
        }
    }
    func getCachedDependencyIndexCount() -> Int {
        lock.withLock { dependencyIndex == nil ? 0 : 1 }
    }
    func deriveDependencyIndex(previous: InstanceEvaluationDataProvider) -> DatafileDependencyIndex {
        let old = previous.getDependencyIndex()
        return lock.withLock {
            if let dependencyIndex { return dependencyIndex }
            // With no retained definitions every owner must be extracted anyway.
            // Rebuild instead of copying, removing and reinserting the old graph.
            if retainedEdgeKeys.allSatisfy({ $0.isEmpty }) {
                let index = createDatafileDependencyIndex(DatafileContent(
                    schemaVersion: schemaVersion, revision: revision,
                    segments: segments, features: features, variables: variables
                ))
                if entityCacheEnabled { dependencyIndex = index }
                return index
            }
            let replacing = [
                Set(previous.features.keys).union(features.keys).subtracting(retainedEdgeKeys[0]),
                Set(previous.variables.keys).union(variables.keys).subtracting(retainedEdgeKeys[1]),
                Set(previous.segments.keys).union(segments.keys).subtracting(retainedEdgeKeys[2]),
            ]
            let index = createDatafileDependencyIndex(DatafileContent(
                schemaVersion: schemaVersion, revision: revision,
                segments: segments, features: features, variables: variables
            ), previous: old, replacing: replacing)
            if entityCacheEnabled { dependencyIndex = index }
            return index
        }
    }
    func getSegment(_ key: SegmentKey) -> Segment? {
        var errors: [FeaturevisorDiagnostic] = []
        let result = lock.withLock { () -> Segment? in
            if let cached = parsedSegments[key] { return cached }
            guard let value = segments[key] else { return nil }
            var normalizer = EntityNormalizer(entityType: "segment", entityKey: key)
            let result = normalizer.segment(value)
            if entityCacheEnabled { parsedSegments[key] = result }
            errors = normalizer.errors
            return result
        }
        errors.forEach(reportDiagnostic)
        return result
    }

    func getVariableKeys(_ featureKey: FeatureKey) -> [String] {
        guard let feature = getFeature(featureKey), let schema = feature.variablesSchema else { return [] }
        return Array(schema.keys)
    }

    func hasVariations(_ featureKey: FeatureKey) -> Bool {
        guard let feature = getFeature(featureKey), let variations = feature.variations else { return false }
        return !variations.isEmpty
    }

    func allConditionsAreMatched(_ conditions: Condition, context: Context) -> Bool {
        _allConditionsAreMatched(
            conditions,
            context: context,
            reportDiagnostic: reportDiagnostic,
            getRegex: getRegex
        )
    }

    func valueIsMatched(
        _ value: AnyValue?,
        operator op: String,
        expected: AnyValue?,
        regexFlags: String?
    ) throws -> Bool {
        try valueIsMatchedThrowing(
            value,
            operator: op,
            expected: expected,
            regexFlags: regexFlags,
            getRegex: getRegex
        )
    }

    private func getRegex(_ pattern: String, _ flags: String?) throws -> NSRegularExpression {
        let key = "\(pattern)\u{0}\(flags ?? "")"
        if let cached = lock.withLock({ regexCache[key] }) {
            return cached
        }

        let compiled = try NSRegularExpression(pattern: normalizePortableRegex(pattern), options: try regexOptions(flags))
        return lock.withLock {
            if let cached = regexCache[key] {
                return cached
            }
            regexCache[key] = compiled
            return compiled
        }
    }

    func getCachedRegexCount() -> Int {
        lock.withLock { regexCache.count }
    }

    func getCachedEntityCount() -> Int {
        lock.withLock { normalizedFeatures.count + normalizedVariables.count + parsedSegments.count }
    }

    func closeEntityCache() {
        lock.withLock {
            normalizedFeatures.removeAll()
            normalizedVariables.removeAll()
            parsedSegments.removeAll()
            regexCache.removeAll()
            dependencyIndex = nil
            entityCacheEnabled = false
        }
    }

    func getMatchedAllocation(_ traffic: Traffic, bucketValue: Int) -> Allocation? {
        guard let allocations = traffic.allocation else { return nil }
        for item in allocations {
            guard item.range.count == 2 else { continue }
            let start = item.range[0]
            let end = item.range[1]
            if start <= bucketValue && end >= bucketValue {
                return item
            }
        }
        return nil
    }

}
