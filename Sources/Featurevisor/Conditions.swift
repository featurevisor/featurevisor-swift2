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
        guard let current = cursor else { return nil }
        if case .object(let object) = current {
            cursor = object[part]
        } else if case .array(let array) = current {
            if part == "length" { cursor = .int(array.count) }
            else if let index = Int(part), String(index) == part, array.indices.contains(index) { cursor = array[index] }
            else { return nil }
        } else {
            return nil
        }
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

func normalizePortableRegex(_ pattern: String) -> String {
    let inside: [Character: String] = [
        "d": "0-9", "D": #"\x{0}-\x{2F}\x{3A}-\x{10FFFF}"#,
        "w": "A-Za-z0-9_", "W": #"\x{0}-\x{2F}\x{3A}-\x{40}\x{5B}-\x{5E}\x{60}\x{7B}-\x{10FFFF}"#,
    ]
    let outside: [Character: String] = [
        "d": "[0-9]", "D": "[^0-9]", "w": "(?-i:[A-Za-z0-9_])", "W": "(?-i:[^A-Za-z0-9_])",
    ]
    var result = ""
    var inClass = false
    var iterator = pattern.makeIterator()
    while let character = iterator.next() {
        if character == "\\" {
            guard let code = iterator.next() else {
                result.append(character)
                break
            }
            if let replacement = (inClass ? inside : outside)[code] {
                result.append(contentsOf: replacement)
            } else {
                result.append("\\")
                result.append(code)
            }
            continue
        }
        if character == "[" && !inClass {
            inClass = true
        } else if character == "]" && inClass {
            inClass = false
        }
        result.append(character)
    }
    return result
}

private func parseISO8601Date(_ value: String) -> Date? {
    let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(Z|([+-])([0-9]{2}):([0-9]{2}))$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          match.range.length == value.utf16.count else { return nil }
    func part(_ index: Int) -> Int? {
        guard let range = Swift.Range<String.Index>(match.range(at: index), in: value) else { return nil }
        return Int(value[range])
    }
    let offsetHour = part(10) ?? 0
    let offsetMinute = part(11) ?? 0
    guard offsetHour <= 14, offsetMinute <= 59,
          !(offsetHour == 14 && offsetMinute != 0),
          let year = part(1), year >= 1, let month = part(2), let day = part(3),
          let hour = part(4), hour <= 23, let minute = part(5), minute <= 59,
          let second = part(6), second <= 59 else { return nil }
    let offset = (offsetHour * 60 + offsetMinute) * 60 * (value.suffix(6).first == "-" ? -1 : 1)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: offset)!
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var normalized = value
    if let range = Swift.Range(match.range(at: 7), in: value) {
        normalized.replaceSubrange(range, with: value[range].prefix(3))
    }
    guard let date = (part(7) == nil ? ISO8601DateFormatter() : fractional).date(from: normalized) else { return nil }
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    guard components.year == year, components.month == month, components.day == day,
          components.hour == hour, components.minute == minute, components.second == second else { return nil }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let utcParts = utc.dateComponents([.era, .year], from: date)
    guard utcParts.era == 1, let utcYear = utcParts.year, (1...9999).contains(utcYear) else { return nil }
    return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
}

private func uncachedRegex(_ pattern: String, _ flags: String?) throws -> NSRegularExpression {
    try NSRegularExpression(pattern: normalizePortableRegex(pattern), options: try regexOptions(flags))
}

func valueIsMatchedThrowing(
    _ attr: AnyValue?,
    operator op: String,
    expected: AnyValue?,
    regexFlags: String? = nil,
    getRegex: FeaturevisorRegexProvider
) throws -> Bool {
    switch op {
    case "isNull":
        return attr == .null
    case "notNull":
        return attr != nil && attr != .null
    case "empty", "notEmpty":
        let isEmpty: Bool
        switch attr {
        case .string(let value)?: isEmpty = value.isEmpty
        case .array(let value)?: isEmpty = value.isEmpty
        case .object(let value)?: isEmpty = value.isEmpty
        default: return false
        }
        return op == "empty" ? isEmpty : !isEmpty
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
    case "includesAny", "notIncludesAny":
        guard case .array(let values)? = attr, case .array(let candidates)? = expected else { return false }
        for candidate in candidates {
            switch candidate {
            case .string, .int, .double, .bool, .null: break
            default: return false
            }
        }
        let found = candidates.contains { candidate in values.contains { anyValueEquals($0, candidate) } }
        return op == "includesAny" ? found : !found
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
        let regex = try getRegex(pattern, regexFlags)
        let range = NSRange(location: 0, length: current.utf16.count)
        return regex.firstMatch(in: current, options: [], range: range) != nil
    case "notMatches":
        guard case .string(let current)? = attr, case .string(let pattern)? = expected else { return false }
        let regex = try getRegex(pattern, regexFlags)
        let range = NSRange(location: 0, length: current.utf16.count)
        return regex.firstMatch(in: current, options: [], range: range) == nil
    default:
        return false
    }
}

private func conditionIsMatchedThrowing(
    _ condition: ConditionPredicate,
    context: Context,
    getRegex: FeaturevisorRegexProvider
) throws -> Bool {
    try valueIsMatchedThrowing(
        resolvePath(context, condition.attribute),
        operator: condition.operator,
        expected: condition.value,
        regexFlags: condition.regexFlags,
        getRegex: getRegex
    )
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
    case .null, .invalid, .feature, .variable, .invalidToken:
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
        return !list.isEmpty && list.allSatisfy {
            _allConditionsAreMatched($0, context: context, reportDiagnostic: reportDiagnostic, getRegex: getRegex)
        }
    case .or(let list):
        return list.contains {
            _allConditionsAreMatched($0, context: context, reportDiagnostic: reportDiagnostic, getRegex: getRegex)
        }
    case .not(let list):
        return !list.isEmpty && !list.allSatisfy {
            _allConditionsAreMatched($0, context: context, reportDiagnostic: reportDiagnostic, getRegex: getRegex)
        }
    case .list(let list):
        return !list.isEmpty && list.allSatisfy {
            _allConditionsAreMatched($0, context: context, reportDiagnostic: reportDiagnostic, getRegex: getRegex)
        }
    }
}

public func allConditionsAreMatched(_ condition: Condition, context: Context) -> Bool {
    _allConditionsAreMatched(condition, context: context)
}
