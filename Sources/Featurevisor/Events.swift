import Foundation

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
    let previousSegmentKeys = Set(previousInstanceEvaluationDataProvider.getSegmentKeys())

    if previousFeatureKeys.isEmpty && previousVariableKeys.isEmpty && previousSegmentKeys.isEmpty {
        return [
            "revision": .string(newRevision),
            "previousRevision": .string(previousRevision),
            "revisionChanged": .bool(previousRevision != newRevision),
            "features": .array(newFeatureKeys.sorted().map { .string($0) }),
            "variables": .array(newVariableKeys.sorted().map { .string($0) }),
            "replaced": .bool(replace),
        ]
    }

    var changed = previousFeatureKeys.symmetricDifference(newFeatureKeys)
    for key in previousFeatureKeys.intersection(newFeatureKeys) {
        let previousHash = previousInstanceEvaluationDataProvider.getRawFeature(key)?.hash
        let newHash = newInstanceEvaluationDataProvider.getRawFeature(key)?.hash
        if previousHash?.isEmpty != false || newHash?.isEmpty != false || previousHash != newHash {
            changed.insert(key)
        }
    }

    let newSegmentKeys = Set(newInstanceEvaluationDataProvider.getSegmentKeys())
    var changedSegments = previousSegmentKeys.symmetricDifference(newSegmentKeys)
    for key in previousSegmentKeys.intersection(newSegmentKeys) {
        if !newInstanceEvaluationDataProvider.retainsSegment(key),
           previousInstanceEvaluationDataProvider.getRawSegment(key) != newInstanceEvaluationDataProvider.getRawSegment(key) { changedSegments.insert(key) }
    }
    var changedVariables = previousVariableKeys.symmetricDifference(newVariableKeys)
    for key in previousVariableKeys.intersection(newVariableKeys) {
        let previousHash = previousInstanceEvaluationDataProvider.getRawGlobalVariable(key)?.hash
        let newHash = newInstanceEvaluationDataProvider.getRawGlobalVariable(key)?.hash
        if previousHash?.isEmpty != false || newHash?.isEmpty != false || previousHash != newHash {
            changedVariables.insert(key)
        }
    }
    addDatafileDependencyChanges(
        features: &changed,
        variables: &changedVariables,
        changedSegments: changedSegments,
        index: previousInstanceEvaluationDataProvider.getDependencyIndex()
    )
    addDatafileDependencyChanges(
        features: &changed,
        variables: &changedVariables,
        changedSegments: changedSegments,
        index: newInstanceEvaluationDataProvider.deriveDependencyIndex(previous: previousInstanceEvaluationDataProvider)
    )

    return [
        "revision": .string(newRevision),
        "previousRevision": .string(previousRevision),
        "revisionChanged": .bool(previousRevision != newRevision),
        "features": .array(changed.sorted().map { .string($0) }),
        "variables": .array(changedVariables.sorted().map { .string($0) }),
        "replaced": .bool(replace),
    ]
}
