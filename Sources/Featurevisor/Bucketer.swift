import Foundation

public let MAX_BUCKETED_NUMBER = 100_000

public func getBucketKey(featureKey: FeatureKey, bucketBy: BucketBy, context: Context) -> String? {
    switch bucketBy {
    case .single(let key):
        guard let value = context[key] else { return nil }
        return "\(stringify(value)).\(featureKey)"
    case .and(let keys):
        let values = keys.compactMap { context[$0].map(stringify) }
        guard values.count == keys.count else { return nil }
        return values.joined(separator: ".") + ".\(featureKey)"
    case .or(let value):
        for key in value.or {
            if let raw = context[key] {
                return "\(stringify(raw)).\(featureKey)"
            }
        }
        return nil
    }
}

public func getBucketedNumber(_ bucketKey: String) -> Int {
    let hash = murmurhash3(bucketKey)
    let ratio = Double(hash) / Double(UInt32.max)
    return Int(ratio * Double(MAX_BUCKETED_NUMBER))
}

public func stringify(_ value: AnyValue) -> String {
    switch value {
    case .string(let v): return v
    case .int(let v): return String(v)
    case .double(let v): return String(v)
    case .bool(let v): return v ? "true" : "false"
    case .null: return "null"
    case .array, .object:
        if let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }
}
