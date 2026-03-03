import Foundation

public let MAX_BUCKETED_NUMBER = 100_000

public func getBucketKey(featureKey: FeatureKey, bucketBy: BucketBy, context: Context) -> String? {
    var parts: [String] = []

    switch bucketBy {
    case .single(let key):
        if let value = context[key] {
            parts.append(stringify(value))
        }
    case .and(let keys):
        for key in keys {
            if let value = context[key] {
                parts.append(stringify(value))
            }
        }
    case .or(let value):
        for key in value.or {
            if let raw = context[key] {
                parts.append(stringify(raw))
                break
            }
        }
    }

    parts.append(featureKey)
    return parts.joined(separator: ".")
}

public func getBucketedNumber(_ bucketKey: String) -> Int {
    let hash = murmurhash3(bucketKey)
    let ratio = Double(hash) / 4_294_967_296.0 // 2^32, matching TypeScript SDK
    return Int(floor(ratio * Double(MAX_BUCKETED_NUMBER)))
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
