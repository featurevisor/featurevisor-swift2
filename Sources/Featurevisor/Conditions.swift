import Foundation

private func anyValueEquals(_ lhs: AnyValue, _ rhs: AnyValue) -> Bool {
    switch (lhs, rhs) {
    case (.string(let l), .string(let r)): return l == r
    case (.int(let l), .int(let r)): return l == r
    case (.double(let l), .double(let r)): return l == r
    case (.int(let l), .double(let r)): return Double(l) == r
    case (.double(let l), .int(let r)): return l == Double(r)
    case (.bool(let l), .bool(let r)): return l == r
    case (.null, .null): return true
    case (.array(let l), .array(let r)): return l == r
    case (.object(let l), .object(let r)): return l == r
    default: return false
    }
}

private func resolvePath(_ context: Context, _ path: String) -> AnyValue? {
    let parts = path.split(separator: ".").map(String.init)
    guard let first = parts.first else { return nil }
    var cursor = context[first]

    for part in parts.dropFirst() {
        guard let current = cursor, case .object(let object) = current else { return nil }
        cursor = object[part]
    }

    return cursor
}

private func toDouble(_ value: AnyValue?) -> Double? {
    guard let value else { return nil }
    switch value {
    case .int(let int): return Double(int)
    case .double(let double): return double
    case .string(let string): return Double(string)
    default: return nil
    }
}

public func conditionIsMatched(_ condition: ConditionPredicate, context: Context) -> Bool {
    let attr = resolvePath(context, condition.attribute)
    let op = condition.operator
    let expected = condition.value

    switch op {
    case "before", "after":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        guard let leftDate = ISO8601DateFormatter().date(from: current) ?? DateFormatter.featurevisorFallback.date(from: current),
              let rightDate = ISO8601DateFormatter().date(from: target) ?? DateFormatter.featurevisorFallback.date(from: target) else {
            return false
        }
        return op == "before" ? leftDate < rightDate : leftDate > rightDate
    case "equals":
        guard let attr, let expected else { return false }
        return anyValueEquals(attr, expected)
    case "notEquals":
        guard let attr, let expected else { return false }
        return !anyValueEquals(attr, expected)
    case "exists":
        return attr != nil
    case "notExists":
        return attr == nil
    case "includes":
        guard let attr, let expected else { return false }
        if case .array(let values) = attr { return values.contains(where: { anyValueEquals($0, expected) }) }
        if case .string(let value) = attr, case .string(let substring) = expected { return value.contains(substring) }
        return false
    case "notIncludes":
        guard let attr, let expected else { return false }
        if case .array(let values) = attr { return !values.contains(where: { anyValueEquals($0, expected) }) }
        if case .string(let value) = attr, case .string(let substring) = expected { return !value.contains(substring) }
        return false
    case "in":
        guard let attr, let expected, case .array(let expectedValues) = expected else { return false }
        return expectedValues.contains(where: { anyValueEquals($0, attr) })
    case "notIn":
        guard let attr, let expected, case .array(let expectedValues) = expected else { return false }
        return !expectedValues.contains(where: { anyValueEquals($0, attr) })
    case "startsWith":
        guard case .string(let string)? = attr, case .string(let prefix)? = expected else { return false }
        return string.hasPrefix(prefix)
    case "endsWith":
        guard case .string(let string)? = attr, case .string(let suffix)? = expected else { return false }
        return string.hasSuffix(suffix)
    case "contains":
        guard case .string(let string)? = attr, case .string(let needle)? = expected else { return false }
        return string.contains(needle)
    case "notContains":
        guard case .string(let string)? = attr, case .string(let needle)? = expected else { return false }
        return !string.contains(needle)
    case "greaterThan":
        guard let l = toDouble(attr), let r = toDouble(expected) else { return false }
        return l > r
    case "greaterThanOrEquals":
        guard let l = toDouble(attr), let r = toDouble(expected) else { return false }
        return l >= r
    case "lessThan":
        guard let l = toDouble(attr), let r = toDouble(expected) else { return false }
        return l < r
    case "lessThanOrEquals":
        guard let l = toDouble(attr), let r = toDouble(expected) else { return false }
        return l <= r
    case "semverEquals":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        return compareVersions(current, target) == .equal
    case "semverNotEquals":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        return compareVersions(current, target) != .equal
    case "semverGreaterThan":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        return compareVersions(current, target) == .greaterThan
    case "semverGreaterThanOrEquals":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        let result = compareVersions(current, target)
        return result == .greaterThan || result == .equal
    case "semverLessThan":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        return compareVersions(current, target) == .lessThan
    case "semverLessThanOrEquals":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        let result = compareVersions(current, target)
        return result == .lessThan || result == .equal
    case "matches":
        guard case .string(let current)? = attr, case .string(let pattern)? = expected else { return false }
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(location: 0, length: current.utf16.count)
            return regex.firstMatch(in: current, options: [], range: range) != nil
        } catch {
            return false
        }
    case "notMatches":
        guard case .string(let current)? = attr, case .string(let pattern)? = expected else { return false }
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(location: 0, length: current.utf16.count)
            return regex.firstMatch(in: current, options: [], range: range) == nil
        } catch {
            return false
        }
    default:
        return false
    }
}

private extension DateFormatter {
    static let featurevisorFallback: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

public func allConditionsMatched(_ condition: Condition, context: Context) -> Bool {
    switch condition {
    case .all:
        return true
    case .invalidToken:
        return false
    case .predicate(let predicate):
        return conditionIsMatched(predicate, context: context)
    case .and(let list):
        return list.allSatisfy { allConditionsMatched($0, context: context) }
    case .or(let list):
        return list.contains { allConditionsMatched($0, context: context) }
    case .not(let list):
        return !list.allSatisfy { allConditionsMatched($0, context: context) }
    case .list(let list):
        return list.allSatisfy { allConditionsMatched($0, context: context) }
    }
}
