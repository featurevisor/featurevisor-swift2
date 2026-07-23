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
    default: return nil
    }
}

typealias FeaturevisorRegexProvider = (_ pattern: String, _ flags: String?) throws -> NSRegularExpression

private func parseISO8601Date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }

    return ISO8601DateFormatter().date(from: value)
}

private func uncachedRegex(_ pattern: String, _ flags: String?) throws -> NSRegularExpression {
    try NSRegularExpression(pattern: pattern, options: try regexOptions(flags))
}

private func conditionIsMatchedThrowing(
    _ condition: ConditionPredicate,
    context: Context,
    getRegex: FeaturevisorRegexProvider
) throws -> Bool {
    let attr = resolvePath(context, condition.attribute)
    let op = condition.operator
    let expected = condition.value

    switch op {
    case "before", "after":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        guard hasExplicitTimezone(current), hasExplicitTimezone(target),
              let leftDate = parseISO8601Date(current),
              let rightDate = parseISO8601Date(target) else {
            return false
        }
        return op == "before" ? leftDate < rightDate : leftDate > rightDate
    case "equals":
        guard let attr, let expected else { return false }
        return anyValueEquals(attr, expected)
    case "notEquals":
        guard let attr else { return true }
        guard let expected else { return true }
        return !anyValueEquals(attr, expected)
    case "exists":
        return attr != nil
    case "notExists":
        return attr == nil
    case "includes":
        guard let attr, let expected else { return false }
        if case .array(let values) = attr { return values.contains(where: { anyValueEquals($0, expected) }) }
        return false
    case "notIncludes":
        guard let attr, let expected else { return false }
        if case .array(let values) = attr { return !values.contains(where: { anyValueEquals($0, expected) }) }
        return false
    case "in":
        guard let attr, let expected, case .array(let expectedValues) = expected else { return false }
        switch attr {
        case .string, .int, .double, .null: break
        default: return false
        }
        return expectedValues.contains(where: { anyValueEquals($0, attr) })
    case "notIn":
        guard let attr, let expected, case .array(let expectedValues) = expected else { return false }
        switch attr {
        case .string, .int, .double, .null: break
        default: return false
        }
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
        return try compareVersions(current, target) == .equal
    case "semverNotEquals":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        return try compareVersions(current, target) != .equal
    case "semverGreaterThan":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        return try compareVersions(current, target) == .greaterThan
    case "semverGreaterThanOrEquals":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        let result = try compareVersions(current, target)
        return result == .greaterThan || result == .equal
    case "semverLessThan":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        return try compareVersions(current, target) == .lessThan
    case "semverLessThanOrEquals":
        guard case .string(let current)? = attr, case .string(let target)? = expected else { return false }
        let result = try compareVersions(current, target)
        return result == .lessThan || result == .equal
    case "matches":
        guard case .string(let current)? = attr, case .string(let pattern)? = expected else { return false }
        let regex = try getRegex(pattern, condition.regexFlags)
        let range = NSRange(location: 0, length: current.utf16.count)
        return regex.firstMatch(in: current, options: [], range: range) != nil
    case "notMatches":
        guard case .string(let current)? = attr, case .string(let pattern)? = expected else { return false }
        let regex = try getRegex(pattern, condition.regexFlags)
        let range = NSRange(location: 0, length: current.utf16.count)
        return regex.firstMatch(in: current, options: [], range: range) == nil
    default:
        return false
    }
}

func conditionIsMatched(_ condition: ConditionPredicate, context: Context) -> Bool {
    (try? conditionIsMatchedThrowing(condition, context: context, getRegex: uncachedRegex)) ?? false
}

func regexOptions(_ flags: String?) throws -> NSRegularExpression.Options {
    guard let flags else { return [] }
    var options: NSRegularExpression.Options = []
    if flags.contains("i") { options.insert(.caseInsensitive) }
    if flags.contains("m") { options.insert(.anchorsMatchLines) }
    if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
    if flags.contains(where: { !"gimsuy".contains($0) }) {
        throw NSError(
            domain: "Featurevisor",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid regular expression flags: \(flags)"]
        )
    }
    return options
}

private func hasExplicitTimezone(_ value: String) -> Bool {
    value.range(
        of: #"T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+\-]\d{2}:\d{2})$"#,
        options: .regularExpression
    ) != nil
}

func _allConditionsAreMatched(
    _ condition: Condition,
    context: Context,
    reportDiagnostic: FeaturevisorDiagnosticHandler? = nil,
    getRegex: @escaping FeaturevisorRegexProvider = uncachedRegex
) -> Bool {
    switch condition {
    case .all:
        return true
    case .invalidToken:
        return false
    case .predicate(let predicate):
        do {
            return try conditionIsMatchedThrowing(predicate, context: context, getRegex: getRegex)
        } catch {
            reportDiagnostic?(FeaturevisorDiagnostic(
                level: .warn,
                code: "condition_match_error",
                message: error.localizedDescription,
                originalError: String(describing: error),
                details: [
                    "condition": .string(String(describing: predicate)),
                    "context": .object(context),
                ]
            ))
            return false
        }
    case .and(let list):
        return list.allSatisfy {
            _allConditionsAreMatched($0, context: context, reportDiagnostic: reportDiagnostic, getRegex: getRegex)
        }
    case .or(let list):
        return list.contains {
            _allConditionsAreMatched($0, context: context, reportDiagnostic: reportDiagnostic, getRegex: getRegex)
        }
    case .not(let list):
        return !list.allSatisfy {
            _allConditionsAreMatched($0, context: context, reportDiagnostic: reportDiagnostic, getRegex: getRegex)
        }
    case .list(let list):
        return list.allSatisfy {
            _allConditionsAreMatched($0, context: context, reportDiagnostic: reportDiagnostic, getRegex: getRegex)
        }
    }
}

public func allConditionsAreMatched(_ condition: Condition, context: Context) -> Bool {
    _allConditionsAreMatched(condition, context: context)
}
