import Foundation

public func getParamsForStickySetEvent(
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

public func getParamsForDatafileSetEvent(
    previousDatafileReader: DatafileReader,
    newDatafileReader: DatafileReader
) -> [String: AnyValue] {
    let previousRevision = previousDatafileReader.getRevision()
    let previousFeatureKeys = Set(previousDatafileReader.getFeatureKeys())

    let newRevision = newDatafileReader.getRevision()
    let newFeatureKeys = Set(newDatafileReader.getFeatureKeys())

    let removed = previousFeatureKeys.subtracting(newFeatureKeys)
    let added = newFeatureKeys.subtracting(previousFeatureKeys)

    var changed: Set<FeatureKey> = []
    for key in previousFeatureKeys.intersection(newFeatureKeys) {
        let previousHash = previousDatafileReader.getFeature(key)?.hash
        let newHash = newDatafileReader.getFeature(key)?.hash
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
    ]
}
