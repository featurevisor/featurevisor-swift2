import Foundation

final class InstanceEvaluationDataProvider: @unchecked Sendable {
    private let schemaVersion: String
    private let revision: String
    private let segments: [SegmentKey: Segment]
    private let features: [FeatureKey: Feature]
    private let variables: [VariableKey: GlobalVariable]
    private let reportDiagnostic: FeaturevisorDiagnosticHandler
    private var parsedSegments: [SegmentKey: Segment] = [:]
    private var regexCache: [String: NSRegularExpression] = [:]
    private let lock = FeaturevisorLock()

    init(datafile: DatafileContent, reportDiagnostic: @escaping FeaturevisorDiagnosticHandler) {
        self.schemaVersion = datafile.schemaVersion
        self.revision = datafile.revision
        self.segments = datafile.segments
        self.features = datafile.features
        self.variables = datafile.variables ?? [:]
        self.reportDiagnostic = reportDiagnostic
    }

    func getRevision() -> String { revision }
    func getSchemaVersion() -> String { schemaVersion }
    func getFeatureKeys() -> [FeatureKey] { Array(features.keys) }
    func getFeature(_ key: FeatureKey) -> Feature? { features[key] }
    func getGlobalVariableKeys() -> [VariableKey] { Array(variables.keys) }
    func getGlobalVariable(_ key: VariableKey) -> GlobalVariable? { variables[key] }
    func getSegmentKeys() -> [SegmentKey] { Array(segments.keys) }
    func getSegment(_ key: SegmentKey) -> Segment? {
        if let cached = lock.withLock({ parsedSegments[key] }) { return cached }
        guard var segment = segments[key] else { return nil }
        if case .string(let stringified) = segment.conditions,
           stringified != "*",
           let data = stringified.data(using: .utf8) {
            do {
                let decoded = try JSONDecoder().decode(Condition.self, from: data)
                segment.conditions = .tree(decoded)
                lock.withLock { parsedSegments[key] = segment }
            } catch {
                reportDiagnostic(FeaturevisorDiagnostic(
                    level: .error,
                    code: "conditions_parse_error",
                    message: "Error parsing conditions",
                    originalError: String(describing: error),
                    details: ["conditions": .string(stringified)]
                ))
            }
        }
        return segment
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

    private func getRegex(_ pattern: String, _ flags: String?) throws -> NSRegularExpression {
        let key = "\(pattern)\u{0}\(flags ?? "")"
        if let cached = lock.withLock({ regexCache[key] }) {
            return cached
        }

        let compiled = try NSRegularExpression(pattern: pattern, options: try regexOptions(flags))
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

    func segmentIsMatched(_ segment: Segment, context: Context) -> Bool {
        switch segment.conditions {
        case .tree(let condition):
            return allConditionsAreMatched(condition, context: context)
        case .string(let raw):
            if raw == "*" { return true }
            if let data = raw.data(using: .utf8), let parsed = try? JSONDecoder().decode(Condition.self, from: data) {
                return allConditionsAreMatched(parsed, context: context)
            }
            return false
        }
    }

    func allSegmentsAreMatched(_ groupSegments: GroupSegment, context: Context) -> Bool {
        switch groupSegments {
        case .all:
            return true
        case .key(let key):
            if key.hasPrefix("{") || key.hasPrefix("[") {
                if let data = key.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(GroupSegment.self, from: data) {
                    return allSegmentsAreMatched(parsed, context: context)
                }
            }
            guard let segment = getSegment(key) else { return false }
            return segmentIsMatched(segment, context: context)
        case .list(let list), .and(let list):
            return list.allSatisfy { allSegmentsAreMatched($0, context: context) }
        case .or(let list):
            return list.contains { allSegmentsAreMatched($0, context: context) }
        case .not(let list):
            return !list.allSatisfy { allSegmentsAreMatched($0, context: context) }
        }
    }

    func getMatchedTraffic(_ traffic: [Traffic], context: Context) -> Traffic? {
        traffic.first(where: { allSegmentsAreMatched($0.segments, context: context) })
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

    func getMatchedForce(_ feature: Feature, context: Context) -> (force: Force?, index: Int?) {
        guard let forces = feature.force else { return (nil, nil) }

        for (index, force) in forces.enumerated() {
            if let segments = force.segments {
                if allSegmentsAreMatched(segments, context: context) { return (force, index) }
                continue
            }
            if let conditions = force.conditions {
                switch conditions {
                case .invalidToken(let raw) where raw.hasPrefix("{") || raw.hasPrefix("["):
                    if let data = raw.data(using: .utf8),
                       let parsed = try? JSONDecoder().decode(Condition.self, from: data),
                       allConditionsAreMatched(parsed, context: context) {
                        return (force, index)
                    }
                default:
                    if allConditionsAreMatched(conditions, context: context) { return (force, index) }
                }
                continue
            }
        }

        return (nil, nil)
    }
}
