import Foundation

public final class DatafileReader: @unchecked Sendable {
    private var schemaVersion: String
    private var revision: String
    private var segments: [SegmentKey: Segment]
    private var features: [FeatureKey: Feature]
    private var regexCache: [String: NSRegularExpression] = [:]
    private let logger: Logger

    public init(datafile: DatafileContent, logger: Logger) {
        self.schemaVersion = datafile.schemaVersion
        self.revision = datafile.revision
        self.segments = datafile.segments
        self.features = datafile.features
        self.logger = logger
    }

    public func getRevision() -> String { revision }
    public func getSchemaVersion() -> String { schemaVersion }
    public func getFeatureKeys() -> [FeatureKey] { Array(features.keys) }
    public func getFeature(_ key: FeatureKey) -> Feature? { features[key] }
    public func getSegment(_ key: SegmentKey) -> Segment? {
        guard var segment = segments[key] else { return nil }
        if case .string(let stringified) = segment.conditions,
           let data = stringified.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Condition.self, from: data) {
            segment.conditions = .tree(decoded)
            segments[key] = segment
        }
        return segment
    }

    public func getVariableKeys(_ featureKey: FeatureKey) -> [String] {
        guard let feature = getFeature(featureKey), let schema = feature.variablesSchema else { return [] }
        return Array(schema.keys)
    }

    public func hasVariations(_ featureKey: FeatureKey) -> Bool {
        guard let feature = getFeature(featureKey), let variations = feature.variations else { return false }
        return !variations.isEmpty
    }

    public func allConditionsAreMatched(_ conditions: Condition, context: Context) -> Bool {
        allConditionsMatched(conditions, context: context)
    }

    public func segmentIsMatched(_ segment: Segment, context: Context) -> Bool {
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

    public func allSegmentsAreMatched(_ groupSegments: GroupSegment, context: Context) -> Bool {
        switch groupSegments {
        case .all:
            return true
        case .key(let key):
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

    public func getMatchedTraffic(_ traffic: [Traffic], context: Context) -> Traffic? {
        traffic.first(where: { allSegmentsAreMatched($0.segments, context: context) })
    }

    public func getMatchedAllocation(_ traffic: Traffic, bucketValue: Int) -> Allocation? {
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

    public func getMatchedForce(_ feature: Feature, context: Context) -> (force: Force?, index: Int?) {
        guard let forces = feature.force else { return (nil, nil) }

        for (index, force) in forces.enumerated() {
            if let segments = force.segments {
                if allSegmentsAreMatched(segments, context: context) { return (force, index) }
                continue
            }
            if let conditions = force.conditions {
                if allConditionsAreMatched(conditions, context: context) { return (force, index) }
                continue
            }
        }

        return (nil, nil)
    }
}
