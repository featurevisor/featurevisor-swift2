import Foundation

let MAX_BUCKETED_NUMBER = 100_000

func getBucketKey(featureKey: FeatureKey, bucketBy: BucketBy, context: Context) -> String? {
    var parts: [String] = []

    switch bucketBy {
    case .single(let key):
        if let value = bucketValue(context, path: key) {
            parts.append(stringify(value))
        }
    case .and(let keys):
        for key in keys {
            if let value = bucketValue(context, path: key) {
                parts.append(stringify(value))
            }
        }
    case .or(let value):
        for key in value.or {
            if let raw = bucketValue(context, path: key) {
                parts.append(stringify(raw))
                break
            }
        }
    }

    parts.append(featureKey)
    return parts.joined(separator: ".")
}

private func bucketValue(_ context: Context, path: String) -> AnyValue? {
    let parts = path.split(separator: ".").map(String.init)
    guard let first = parts.first, var value = context[first] else { return nil }
    for part in parts.dropFirst() {
        guard case .object(let object) = value, let nested = object[part] else { return nil }
        value = nested
    }
    return value
}

func getBucketedNumber(_ bucketKey: String) -> Int {
    let hash = murmurhash3(bucketKey)
    let ratio = Double(hash) / 4_294_967_296.0 // 2^32, matching TypeScript SDK
    return Int(floor(ratio * Double(MAX_BUCKETED_NUMBER)))
}

func stringify(_ value: AnyValue) -> String {
    switch value {
    case .string(let v): return v
    case .int(let v): return String(v)
    case .double(let v): return stringifyDouble(v)
    case .bool(let v): return v ? "true" : "false"
    case .null: return ""
    case .array(let values): return values.map(stringify).joined(separator: ",")
    case .object: return "[object Object]"
    }
}

private func stringifyDouble(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value == .infinity { return "Infinity" }
    if value == -.infinity { return "-Infinity" }
    if value == 0 { return "0" }

    let absolute = abs(value)
    let raw = String(value).lowercased()
    if absolute >= 1e-6 && absolute < 1e21 {
        if let decimal = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) {
            return NSDecimalNumber(decimal: decimal).stringValue
        }
        return raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw
    }

    let parts = raw.split(separator: "e", maxSplits: 1).map(String.init)
    guard parts.count == 2, let exponent = Int(parts[1]) else { return raw }
    let coefficient = parts[0].hasSuffix(".0") ? String(parts[0].dropLast(2)) : parts[0]
    return "\(coefficient)e\(exponent >= 0 ? "+" : "")\(exponent)"
}
