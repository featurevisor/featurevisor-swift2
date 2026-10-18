import Foundation

protocol Selectable {
    var conditions: Condition? { get set }
    var segments: GroupSegment? { get set }
    var requiredFeatures: [RequiredFeature]? { get set }
}
extension Force: Selectable {
    var requiredFeatures: [RequiredFeature]? { get { nil } set {} }
}
extension Traffic: Selectable {
    var requiredFeatures: [RequiredFeature]? { get { nil } set {} }
}
extension VariableOverride: Selectable {}
extension VariableOverrideProgramStep: Selectable {}
extension Feature: Selectable {
    var segments: GroupSegment? { get { nil } set {} }
}
extension GlobalVariable: Selectable {
    var segments: GroupSegment? { get { nil } set {} }
}

func isStringifiedCondition(_ raw: String) -> Bool {
    guard let first = raw.first(where: { !$0.isWhitespace }) else { return false }
    return first == "{" || first == "[" || first == "\""
}

func legacyCondition(_ value: Condition) -> Condition {
    switch value {
    case .and(let items): return items.isEmpty ? .all : .and(items.map(legacyCondition))
    case .list(let items): return items.isEmpty ? .all : .list(items.map(legacyCondition))
    case .or(let items): return .or(items.map(legacyCondition))
    case .not(let items): return .not(items.map(legacyCondition))
    default: return value
    }
}

func featureCondition(_ value: RequiredFeature) -> Condition {
    switch value {
    case .feature(let key): return .feature(FeatureCondition(feature: key))
    case .options(let value): return .feature(value)
    case .and(let items): return items.isEmpty ? .all : .and(items.map(featureCondition))
    case .or(let items): return .or(items.map(featureCondition))
    case .not(let items): return .not(items.map(featureCondition))
    }
}

func segmentCondition(_ value: GroupSegment) -> Condition {
    switch value {
    case .all: return .all
    case .key(let key): return .invalidToken(key)
    case .list(let items): return .list(items.map(segmentCondition))
    case .and(let items): return .and(items.map(segmentCondition))
    case .or(let items): return .or(items.map(segmentCondition))
    case .not(let items): return .not(items.map(segmentCondition))
    }
}

struct EntityNormalizer {
    let entityType: String
    let entityKey: String
    var errors: [FeaturevisorDiagnostic] = []
    // Dependency extraction is silent and may share parses within one index build.
    // Reader normalization keeps its own entity diagnostics and lazy publication.
    var silentConditionParser: ((String) -> Condition)? = nil

    mutating func parse(_ value: Condition) -> Condition {
        guard case .invalidToken(let raw) = value, isStringifiedCondition(raw) else { return value }
        if let silentConditionParser { return silentConditionParser(raw) }
        do { return try JSONDecoder().decode(Condition.self, from: Data(raw.utf8)) }
        catch {
            errors.append(FeaturevisorDiagnostic(
                level: .error, code: "conditions_parse_error", message: "Error parsing conditions",
                originalError: String(describing: error),
                details: ["conditions": .string(raw), "entityType": .string(entityType), "entityKey": .string(entityKey)]
            ))
            return .invalid
        }
    }

    mutating func select<T: Selectable>(_ value: T, legacy: Bool = false) -> T {
        var result = value
        var parts: [Condition] = []
        if let condition = value.conditions {
            let parsed = parse(condition)
            parts.append(legacy ? legacyCondition(parsed) : parsed)
        }
        if let segments = value.segments { parts.append(legacyCondition(parse(segmentCondition(segments)))) }
        if let required = value.requiredFeatures, !required.isEmpty {
            parts.append(.list(required.map(featureCondition)))
        }
        result.segments = nil
        result.requiredFeatures = nil
        if parts.contains(.invalid) { result.conditions = .invalid }
        else if parts.count == 1 { result.conditions = parts[0] }
        else if !parts.isEmpty {
            result.conditions = .list(parts.flatMap { part -> [Condition] in
                if case .list(let items) = part { return items.isEmpty ? [.and([])] : items }
                return [part]
            })
        }
        return result
    }

    mutating func overrides(_ values: [String: [VariableOverride]]?, legacy: Bool) -> [String: [VariableOverride]]? {
        values?.mapValues { entries in entries.map { select($0, legacy: legacy) } }
    }

    mutating func feature(_ feature: Feature, legacy: Bool = false) -> Feature {
        var result = select(feature)
        result.force = feature.force?.map { select($0, legacy: legacy) }
        result.traffic = feature.traffic.map {
            var value = select($0)
            value.variableOverrides = overrides(value.variableOverrides, legacy: legacy)
            return value
        }
        result.variations = feature.variations?.map {
            var value = $0
            value.variableOverrides = overrides(value.variableOverrides, legacy: legacy)
            return value
        }
        return result
    }

    mutating func segment(_ segment: Segment, legacy: Bool = false) -> Segment {
        let condition: Condition
        switch segment.conditions {
        case .tree(let value): condition = parse(value)
        case .string(let raw): condition = parse(raw == "*" ? .all : .invalidToken(raw))
        }
        var result = segment
        result.conditions = .tree(legacy ? legacyCondition(condition) : condition)
        return result
    }

    mutating func variable(_ variable: GlobalVariable, legacy: Bool = false) -> GlobalVariable {
        var result = select(variable)
        result.overrides = variable.overrides?.map { select($0, legacy: legacy) }
        result.overrideProgram = variable.overrideProgram?.map { select($0) }
        return result
    }
}

func normalizeLegacyDatafile(_ datafile: DatafileContent) -> (DatafileContent, [FeaturevisorDiagnostic]) {
    guard datafile.schemaVersion == "2" else { return (datafile, []) }
    var result = datafile
    var errors: [FeaturevisorDiagnostic] = []
    result.features = datafile.features.mapValues { $0 }
    for (key, value) in datafile.features {
        var normalizer = EntityNormalizer(entityType: "feature", entityKey: key)
        result.features[key] = normalizer.feature(value, legacy: true)
        errors += normalizer.errors
    }
    for (key, value) in datafile.segments {
        var normalizer = EntityNormalizer(entityType: "segment", entityKey: key)
        result.segments[key] = normalizer.segment(value, legacy: true)
        errors += normalizer.errors
    }
    for (key, value) in datafile.variables ?? [:] {
        var normalizer = EntityNormalizer(entityType: "variable", entityKey: key)
        result.variables?[key] = normalizer.variable(value, legacy: true)
        errors += normalizer.errors
    }
    return (result, errors)
}
