import Foundation

private func segmentKeys(_ value: GroupSegment?, into result: inout Set<String>) {
    guard let value else { return }
    switch value {
    case .all: break
    case .key(let key):
        if key != "*", !key.hasPrefix("{"), !key.hasPrefix("[") { result.insert(key) }
    case .list(let values), .and(let values), .or(let values), .not(let values):
        values.forEach { segmentKeys($0, into: &result) }
    }
}

private func requiredFeatureKeys(_ values: [RequiredFeature]?, into result: inout Set<String>) {
    values?.forEach {
        switch $0 {
        case .feature(let key): result.insert(key)
        case .options(let options): result.insert(options.feature)
        }
    }
}

private func overrideDependencies(_ groups: [VariableKey: [VariableOverride]]?, segments: inout Set<String>, features: inout Set<String>) {
    groups?.values.flatMap { $0 }.forEach {
        segmentKeys($0.segments, into: &segments)
        requiredFeatureKeys($0.requiredFeatures, into: &features)
    }
}

private func dependencies(_ feature: Feature) -> (segments: Set<String>, features: Set<String>) {
    var segments = Set<String>(), features = Set<String>()
    requiredFeatureKeys(feature.requiredFeatures, into: &features)
    if feature.requiredFeatures == nil {
        feature.required?.forEach {
            switch $0 {
            case .key(let key): features.insert(key)
            case .withVariation(let value): features.insert(value.key)
            }
        }
    }
    feature.traffic.forEach {
        segmentKeys($0.segments, into: &segments)
        overrideDependencies($0.variableOverrides, segments: &segments, features: &features)
    }
    feature.force?.forEach { segmentKeys($0.segments, into: &segments) }
    feature.variations?.forEach { overrideDependencies($0.variableOverrides, segments: &segments, features: &features) }
    return (segments, features)
}

private func dependencies(_ variable: GlobalVariable) -> (segments: Set<String>, features: Set<String>) {
    var segments = Set<String>(), features = Set<String>()
    requiredFeatureKeys(variable.requiredFeatures, into: &features)
    variable.overrides?.forEach {
        segmentKeys($0.segments, into: &segments)
        requiredFeatureKeys($0.requiredFeatures, into: &features)
    }
    return (segments, features)
}

func getParamsForStickyFeaturesSetEvent(
    previousStickyFeatures: StickyFeatures = [:],
    newStickyFeatures: StickyFeatures = [:],
    replace: Bool
) -> [String: AnyValue] {
    let keysBefore = Set(previousStickyFeatures.keys)
    let keysAfter = Set(newStickyFeatures.keys)
    let allKeys = keysBefore.union(keysAfter)

    return [
        "features": .array(allKeys.sorted().map { .string($0) }),
        "replaced": .bool(replace),
    ]
}

func getParamsForStickyVariablesSetEvent(
    previousStickyVariables: StickyVariables = [:],
    newStickyVariables: StickyVariables = [:],
    replace: Bool
) -> [String: AnyValue] {
    let keys = Set(previousStickyVariables.keys).union(newStickyVariables.keys)
    return [
        "variables": .array(keys.sorted().map { .string($0) }),
        "replaced": .bool(replace),
    ]
}

func getParamsForDatafileSetEvent(
    previousInstanceEvaluationDataProvider: InstanceEvaluationDataProvider,
    newInstanceEvaluationDataProvider: InstanceEvaluationDataProvider,
    replace: Bool
) -> [String: AnyValue] {
    let previousRevision = previousInstanceEvaluationDataProvider.getRevision()
    let previousFeatureKeys = Set(previousInstanceEvaluationDataProvider.getFeatureKeys())

    let newRevision = newInstanceEvaluationDataProvider.getRevision()
    let newFeatureKeys = Set(newInstanceEvaluationDataProvider.getFeatureKeys())
    let previousVariableKeys = Set(previousInstanceEvaluationDataProvider.getGlobalVariableKeys())
    let newVariableKeys = Set(newInstanceEvaluationDataProvider.getGlobalVariableKeys())

    var changed = previousFeatureKeys.symmetricDifference(newFeatureKeys)
    for key in previousFeatureKeys.intersection(newFeatureKeys) {
        let previousHash = previousInstanceEvaluationDataProvider.getFeature(key)?.hash
        let newHash = newInstanceEvaluationDataProvider.getFeature(key)?.hash
        if previousHash != newHash {
            changed.insert(key)
        }
    }

    let previousSegmentKeys = Set(previousInstanceEvaluationDataProvider.getSegmentKeys())
    let newSegmentKeys = Set(newInstanceEvaluationDataProvider.getSegmentKeys())
    var changedSegments = previousSegmentKeys.symmetricDifference(newSegmentKeys)
    for key in previousSegmentKeys.intersection(newSegmentKeys) {
        if previousInstanceEvaluationDataProvider.getSegment(key) != newInstanceEvaluationDataProvider.getSegment(key) { changedSegments.insert(key) }
    }
    let allFeatureKeys = previousFeatureKeys.union(newFeatureKeys)
    var didChange = true
    while didChange {
        didChange = false
        for key in allFeatureKeys where !changed.contains(key) {
            let candidates = [
                previousInstanceEvaluationDataProvider.getFeature(key),
                newInstanceEvaluationDataProvider.getFeature(key),
            ].compactMap { $0 }
            if candidates.contains(where: {
                let dependency = dependencies($0)
                return !dependency.segments.isDisjoint(with: changedSegments) || !dependency.features.isDisjoint(with: changed)
            }) {
                changed.insert(key)
                didChange = true
            }
        }
    }
    var changedVariables = previousVariableKeys.symmetricDifference(newVariableKeys)
    for key in previousVariableKeys.intersection(newVariableKeys) {
        if previousInstanceEvaluationDataProvider.getGlobalVariable(key) != newInstanceEvaluationDataProvider.getGlobalVariable(key) {
            changedVariables.insert(key)
        }
    }
    for key in previousVariableKeys.union(newVariableKeys) where !changedVariables.contains(key) {
        let candidates = [
            previousInstanceEvaluationDataProvider.getGlobalVariable(key),
            newInstanceEvaluationDataProvider.getGlobalVariable(key),
        ].compactMap { $0 }
        if candidates.contains(where: {
            let dependency = dependencies($0)
            return !dependency.segments.isDisjoint(with: changedSegments) || !dependency.features.isDisjoint(with: changed)
        }) {
            changedVariables.insert(key)
        }
    }

    return [
        "revision": .string(newRevision),
        "previousRevision": .string(previousRevision),
        "revisionChanged": .bool(previousRevision != newRevision),
        "features": .array(changed.sorted().map { .string($0) }),
        "variables": .array(changedVariables.sorted().map { .string($0) }),
        "replaced": .bool(replace),
    ]
}
