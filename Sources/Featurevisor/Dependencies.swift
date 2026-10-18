import Foundation

struct DatafileDependencyOwner: Hashable {
    let kind: Int
    let key: String
}

struct DatafileDependencyIndex {
    // Rows are dependency kinds; columns are dependent kinds: feature, variable, segment.
    var edges = Array(repeating: Array(repeating: [String: Set<String>](), count: 3), count: 3)
    var owners: [DatafileDependencyOwner: Set<DatafileDependencyOwner>] = [:]
    var extractedEntities = 0
    var decodedConditions = 0

    mutating func remove(_ owner: DatafileDependencyOwner) {
        for source in owners.removeValue(forKey: owner) ?? [] {
            edges[source.kind][owner.kind][source.key]?.remove(owner.key)
            if edges[source.kind][owner.kind][source.key]?.isEmpty == true {
                edges[source.kind][owner.kind].removeValue(forKey: source.key)
            }
        }
    }
}

func createDatafileDependencyIndex(
    _ datafile: DatafileContent,
    previous: DatafileDependencyIndex = DatafileDependencyIndex(),
    replacing: [Set<String>]? = nil
) -> DatafileDependencyIndex {
    var index = previous
    index.extractedEntities = 0
    var parsedConditions: [String: Condition] = [:]
    var decodedConditions = 0
    func parse(_ raw: String) -> Condition {
        if let cached = parsedConditions[raw] { return cached }
        decodedConditions += 1
        let result = (try? JSONDecoder().decode(Condition.self, from: Data(raw.utf8))) ?? .invalid
        // Bound temporary retention for datafiles with many distinct selectors.
        if parsedConditions.count < 256 { parsedConditions[raw] = result }
        return result
    }
    if let replacing {
        for kind in 0..<3 {
            for key in replacing[kind] { index.remove(DatafileDependencyOwner(kind: kind, key: key)) }
        }
    }
    func edge(_ source: Int, _ key: String, _ target: Int, _ dependent: String) {
        index.edges[source][target][key, default: []].insert(dependent)
        index.owners[DatafileDependencyOwner(kind: target, key: dependent), default: []]
            .insert(DatafileDependencyOwner(kind: source, key: key))
    }
    func visit(_ condition: Condition?, _ target: Int, _ dependent: String) {
        guard let condition else { return }
        switch condition {
        case .invalidToken(let key):
            if isStringifiedCondition(key) {
                visit(parse(key), target, dependent)
            } else { edge(2, key, target, dependent) }
        case .feature(let value): edge(0, value.feature, target, dependent)
        case .variable(let value): edge(value.feature == nil ? 1 : 0, value.feature ?? value.variable, target, dependent)
        case .and(let values), .or(let values), .not(let values), .list(let values):
            for value in values { visit(value, target, dependent) }
        default: break
        }
    }
    // Normalize copies without reporting or warming the reader caches.
    for (key, value) in datafile.segments where replacing == nil || replacing![2].contains(key) {
        index.extractedEntities += 1
        var normalizer = EntityNormalizer(entityType: "segment", entityKey: key, silentConditionParser: parse)
        if case .tree(let condition) = normalizer.segment(value).conditions { visit(condition, 2, key) }
    }
    for (key, raw) in datafile.features where replacing == nil || replacing![0].contains(key) {
        index.extractedEntities += 1
        var normalizer = EntityNormalizer(entityType: "feature", entityKey: key, silentConditionParser: parse)
        visit(normalizer.select(raw).conditions, 0, key)
        for force in raw.force ?? [] { visit(normalizer.select(force).conditions, 0, key) }
        for traffic in raw.traffic {
            visit(normalizer.select(traffic).conditions, 0, key)
            for entries in traffic.variableOverrides?.values ?? [:].values {
                for entry in entries { visit(normalizer.select(entry).conditions, 0, key) }
            }
        }
        for variation in raw.variations ?? [] {
            for entries in variation.variableOverrides?.values ?? [:].values {
                for entry in entries { visit(normalizer.select(entry).conditions, 0, key) }
            }
        }
    }
    for (key, raw) in datafile.variables ?? [:] where replacing == nil || replacing![1].contains(key) {
        index.extractedEntities += 1
        var normalizer = EntityNormalizer(entityType: "variable", entityKey: key, silentConditionParser: parse)
        visit(normalizer.select(raw).conditions, 1, key)
        if let program = raw.overrideProgram {
            for entry in program { visit(normalizer.select(entry).conditions, 1, key) }
        } else {
            for entry in raw.overrides ?? [] { visit(normalizer.select(entry).conditions, 1, key) }
        }
        switch raw.compose {
        case .alias(let source): edge(1, source, 1, key)
        case .members(let entries):
            for entry in entries {
                if let feature = entry.feature { edge(0, feature, 1, key) }
                else if let variable = entry.variable { edge(1, variable, 1, key) }
            }
        case nil: break
        }
    }
    index.decodedConditions = decodedConditions
    return index
}

func addDatafileDependencyChanges(
    features: inout Set<FeatureKey>,
    variables: inout Set<VariableKey>,
    changedSegments: Set<SegmentKey>,
    index: DatafileDependencyIndex
) {
    var affected = [features, variables, changedSegments]
    var queue = affected.map(Array.init)
    var cursors = [0, 0, 0]
    while true {
        var advanced = false
        for source in 0..<3 where cursors[source] < queue[source].count {
            advanced = true
            let key = queue[source][cursors[source]]
            cursors[source] += 1
            for target in 0..<3 {
                for dependent in index.edges[source][target][key] ?? [] where affected[target].insert(dependent).inserted {
                    queue[target].append(dependent)
                }
            }
        }
        if !advanced { break }
    }
    features = affected[0]
    variables = affected[1]
}
