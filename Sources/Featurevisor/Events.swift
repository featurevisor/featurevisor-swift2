import Foundation

func getParamsForStickySetEvent(
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

func getParamsForDatafileSetEvent(
    previousInstanceEvaluationDataProvider: InstanceEvaluationDataProvider,
    newInstanceEvaluationDataProvider: InstanceEvaluationDataProvider,
    replace: Bool
) -> [String: AnyValue] {
    let previousRevision = previousInstanceEvaluationDataProvider.getRevision()
    let previousFeatureKeys = Set(previousInstanceEvaluationDataProvider.getFeatureKeys())

    let newRevision = newInstanceEvaluationDataProvider.getRevision()
    let newFeatureKeys = Set(newInstanceEvaluationDataProvider.getFeatureKeys())

    let removed = previousFeatureKeys.subtracting(newFeatureKeys)
    let added = newFeatureKeys.subtracting(previousFeatureKeys)

    var changed: Set<FeatureKey> = []
    for key in previousFeatureKeys.intersection(newFeatureKeys) {
        let previousHash = previousInstanceEvaluationDataProvider.getFeature(key)?.hash
        let newHash = newInstanceEvaluationDataProvider.getFeature(key)?.hash
        if previousHash != newHash {
            changed.insert(key)
        }
    }

    let affected = removed.union(added).union(changed).sorted()

    return [
        "revision": .string(newRevision),
        "previousRevision": .string(previousRevision),
        "revisionChanged": .bool(previousRevision != newRevision),
        "features": .array(affected.map { .string($0) }),
        "replaced": .bool(replace),
    ]
}
