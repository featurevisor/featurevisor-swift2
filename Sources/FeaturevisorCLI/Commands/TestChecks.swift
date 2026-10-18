import Foundation
import Featurevisor

protocol CheckVariableResolver {
    func checkGlobalVariable(_ variable: String) throws -> AnyValue?
    func checkFeatureVariable(_ feature: String, _ variable: String) throws -> AnyValue?
    func checkFeatureEnabled(_ feature: String) throws -> Bool
    func checkFeatureVariation(_ feature: String) throws -> String?
}

protocol CheckSegmentResolver {
    func checkSegment(_ segment: String) throws -> Bool
}

protocol CheckSegmentDefinitionValidator {
    func validateSegmentDefinition(_ segment: String) throws
}

final class CheckDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []

    func record(_ diagnostic: FeaturevisorDiagnostic) {
        guard diagnostic.level == .error || diagnostic.level == .fatal else { return }
        lock.lock()
        errors.append("\(diagnostic.code): \(diagnostic.message)\(diagnostic.originalError.map { ": \($0)" } ?? "")")
        lock.unlock()
    }

    func clear() { lock.lock(); errors.removeAll(); lock.unlock() }
    func take() -> String? { lock.lock(); defer { lock.unlock() }; return errors.isEmpty ? nil : errors.joined(separator: "; ") }

    func recordErrorEvent(_ payload: EventPayload) {
        guard case .object(let diagnostic)? = payload.params["diagnostic"] else { return }
        let message = diagnostic["message"]?.asString() ?? "SDK evaluation error"
        let code = diagnostic["code"]?.asString() ?? "evaluation_error"
        record(FeaturevisorDiagnostic(level: .error, code: code, message: message, originalError: diagnostic["originalError"]?.asString()))
    }
}

struct NativeCheckResolver: CheckVariableResolver, CheckSegmentResolver, CheckSegmentDefinitionValidator {
    private let global: (String) -> AnyValue?
    private let feature: (String, String) -> AnyValue?
    private let enabled: (String) -> Bool
    private let variation: (String) -> String?
    private let diagnostics: CheckDiagnosticCollector
    private let segmentDefinitions: [String: Any]
    private let context: Context
    private let segmentGates: [String: String]

    init(_ sdk: Featurevisor, diagnostics: CheckDiagnosticCollector, segmentDefinitions: [String: Any] = [:], context: Context = [:], segmentGates: [String: String] = [:]) {
        self.global = { sdk.getVariable($0) }
        self.feature = { sdk.getVariable($0, $1) }
        self.enabled = { sdk.isEnabled($0) }
        self.variation = { sdk.getVariation($0) }
        self.diagnostics = diagnostics
        self.segmentDefinitions = segmentDefinitions
        self.context = context
        self.segmentGates = segmentGates
    }

    init(_ child: FeaturevisorChildInstance, diagnostics: CheckDiagnosticCollector, segmentDefinitions: [String: Any] = [:], context: Context = [:], segmentGates: [String: String] = [:]) {
        self.global = { child.getVariable($0) }
        self.feature = { child.getVariable($0, $1) }
        self.enabled = { child.isEnabled($0) }
        self.variation = { child.getVariation($0) }
        self.diagnostics = diagnostics
        self.segmentDefinitions = segmentDefinitions
        self.context = context
        self.segmentGates = segmentGates
    }

    func checkGlobalVariable(_ variable: String) throws -> AnyValue? {
        diagnostics.clear()
        let value = global(variable)
        if let error = diagnostics.take() { throw checkError(error) }
        return value
    }

    func checkFeatureVariable(_ featureKey: String, _ variable: String) throws -> AnyValue? {
        diagnostics.clear()
        let value = feature(featureKey, variable)
        if let error = diagnostics.take() { throw checkError(error) }
        return value
    }

    func checkFeatureEnabled(_ featureKey: String) throws -> Bool {
        diagnostics.clear()
        let value = enabled(featureKey)
        if let error = diagnostics.take() { throw checkError(error) }
        return value
    }

    func checkFeatureVariation(_ featureKey: String) throws -> String? {
        diagnostics.clear()
        let value = variation(featureKey)
        if let error = diagnostics.take() { throw checkError(error) }
        return value
    }

    func validateSegmentDefinition(_ segment: String) throws {
        guard let definition = segmentDefinitions[segment] as? [String: Any] else {
            throw checkError("segment \"\(segment)\" definition is missing")
        }
        guard definition.keys.contains("conditions") else {
            throw checkError("segment \"\(segment)\" definition has no conditions")
        }
    }

    func checkSegment(_ segment: String) throws -> Bool {
        try validateSegmentDefinition(segment)
        guard let gate = segmentGates[segment] else { throw checkError("Segment SDK gate is unavailable") }
        return try checkFeatureEnabled(gate)
    }
}

private enum CheckResolved: Equatable {
    case missing
    case value(AnyValue)
}

private enum CheckPathPart {
    case property(String)
    case index(Int)
}

func evaluateAssertionChecks(
    _ assertion: [String: Any],
    ownerVariable: String?,
    resolver: any CheckVariableResolver,
    datafile: DatafileContent,
    prefix: String = ""
) -> [String] {
    evaluateAssertionChecksDetailed(assertion, ownerVariable: ownerVariable, resolver: resolver, datafile: datafile, prefix: prefix).failures
}

struct CheckAssertionOutcome {
    let failures: [String]
    let hadError: Bool
    let reportErrors: [[String: Any]]
}

func preflightExpandedAssertionChecks(
    _ assertion: [String: Any],
    ownerVariable: String?,
    datafile: DatafileContent,
    segmentDefinitions: [String: Any]
) throws {
    try preflightAssertionChecks(assertion, ownerVariable: ownerVariable, datafile: datafile, segmentDefinitions: segmentDefinitions, path: "checks")
    for (index, child) in (assertion["children"] as? [[String: Any]] ?? []).enumerated() {
        try preflightAssertionChecks(child, ownerVariable: ownerVariable, datafile: datafile, segmentDefinitions: segmentDefinitions, path: "children[\(index)].checks")
    }
}

func preflightAssertionChecks(
    _ assertion: [String: Any],
    ownerVariable: String?,
    datafile: DatafileContent,
    segmentDefinitions: [String: Any],
    path: String
) throws {
    guard assertion.keys.contains("checks") else { return }
    guard let checks = assertion["checks"] as? [Any], !checks.isEmpty else {
        throw checkError("\(path): expected a nonempty array")
    }
    try validateCheckList(checks, ownerVariable: ownerVariable, path: path)

    func validateReference(_ reference: [String: Any], path: String) throws {
        let variable = reference["variable"] as? String ?? ownerVariable
        if let featureKey = reference["feature"] as? String {
            guard let feature = datafile.features[featureKey] else {
                throw checkError("\(path): feature \"\(featureKey)\" is missing from the selected datafile")
            }
            guard let variable, feature.variablesSchema?[variable] != nil else {
                throw checkError("\(path): variable \"\(variable ?? "")\" is missing from feature \"\(featureKey)\" in the selected datafile")
            }
        } else if let variable, datafile.variables?[variable] == nil {
            throw checkError("\(path): global variable \"\(variable)\" is missing from the selected datafile")
        }
    }

    func visit(_ raw: Any, path: String) throws {
        guard let check = raw as? [String: Any] else { return }
        for group in ["and", "or", "not"] {
            if let children = check[group] as? [Any] {
                for (index, child) in children.enumerated() {
                    try visit(child, path: "\(path).\(group)[\(index)]")
                }
                return
            }
        }
        if let segment = check["segment"] as? String {
            try preflightSegmentReferences(segment, datafile: datafile, definitions: segmentDefinitions)
            return
        }
        if check.keys.contains("enabled") || check.keys.contains("variation") {
            if let feature = check["feature"] as? String, datafile.features[feature] == nil {
                throw checkError("\(path): feature \"\(feature)\" is missing from the selected datafile")
            }
            return
        }
        try validateReference(check, path: path)
        if let compareTo = check["compareTo"] as? [String: Any] {
            try validateReference(compareTo, path: "\(path).compareTo")
        }
    }

    for (index, check) in checks.enumerated() {
        try visit(check, path: "\(path)[\(index)]")
    }
}

func evaluateAssertionChecksDetailed(
    _ assertion: [String: Any],
    ownerVariable: String?,
    resolver: any CheckVariableResolver,
    datafile: DatafileContent,
    prefix: String = "",
    basePath: [Any] = [],
    childIndex: Int? = nil
) -> CheckAssertionOutcome {
    guard assertion.keys.contains("checks") else { return CheckAssertionOutcome(failures: [], hadError: false, reportErrors: []) }
    guard let checks = assertion["checks"] as? [Any], !checks.isEmpty else {
        let message = "\(prefix)checks: expected a nonempty array"
        return CheckAssertionOutcome(failures: [message], hadError: true, reportErrors: [[
            "message": message, "type": "check", "path": basePath + ["checks"],
            "expected": "valid checks", "actual": assertion["checks"] ?? NSNull(),
        ]])
    }
    do {
        try validateCheckList(checks, ownerVariable: ownerVariable, path: "\(prefix)checks")
        try validateSegmentReferences(checks, resolver: resolver, path: "\(prefix)checks")
    }
    catch { return CheckAssertionOutcome(failures: [error.localizedDescription], hadError: true, reportErrors: [[
        "message": error.localizedDescription, "type": "check", "expected": "valid checks", "actual": checks,
    ]]) }
    var failures: [String] = []
    var reportErrors: [[String: Any]] = []
    var hadError = false
    for (index, rawCheck) in checks.enumerated() {
        let path = "\(prefix)checks[\(index)]"
        let check = rawCheck as? [String: Any] ?? [:]
        var evaluated: [[String: Any]] = []
        var details: [String: Any] = ["checkIndex": index, "evaluated": evaluated]
        if let childIndex { details["childIndex"] = childIndex }
        if let key = check["key"] as? String { details["checkKey"] = key }
        if let description = check["description"] as? String { details["checkDescription"] = description }
        do {
            let result = try evaluateCheck(rawCheck, ownerVariable: ownerVariable, resolver: resolver, datafile: datafile, path: path, tracePath: [index], evaluated: &evaluated)
            details["evaluated"] = evaluated
            if !result.matched {
                failures.append(result.failure)
                reportErrors.append([
                    "message": result.failure, "type": "check", "path": basePath + ["checks", index],
                    "expected": true, "actual": false, "details": details,
                ])
            }
        } catch {
            failures.append(error.localizedDescription)
            hadError = true
            details["evaluated"] = evaluated
            reportErrors.append([
                "message": error.localizedDescription, "type": "check", "path": basePath + ["checks", index],
                "expected": "successful comparison", "actual": error.localizedDescription, "details": details,
            ])
        }
    }
    return CheckAssertionOutcome(failures: failures, hadError: hadError, reportErrors: reportErrors)
}

private func validateCheckList(_ checks: [Any], ownerVariable: String?, path: String) throws {
    var keys = Set<String>()
    for (index, raw) in checks.enumerated() {
        guard let check = raw as? [String: Any] else { throw checkError("\(path)[\(index)]: check must be an object") }
        if check.keys.contains("key") {
            guard let key = check["key"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw checkError("\(path)[\(index)].key: expected a nonempty string")
            }
            guard keys.insert(key).inserted else { throw checkError("\(path)[\(index)].key: duplicate sibling key \"\(key)\"") }
        }
        if check.keys.contains("description"), !(check["description"] is String) {
            throw checkError("\(path)[\(index)].description: expected a string")
        }
        try validateCheckShape(check, ownerVariable: ownerVariable, path: "\(path)[\(index)]")
    }
}

private func validateCheckShape(_ raw: Any, ownerVariable: String?, path: String) throws {
    guard let check = raw as? [String: Any] else { throw checkError("\(path): check must be an object") }
    let groups = ["and", "or", "not"].filter { check.keys.contains($0) }
    if !groups.isEmpty {
        let metadataCount = (check.keys.contains("key") ? 1 : 0) + (check.keys.contains("description") ? 1 : 0)
        guard groups.count == 1, check.count == 1 + metadataCount else { throw checkError("\(path): group must contain exactly one of and, or, or not") }
        let group = groups[0]
        guard let children = check[group] as? [Any], !children.isEmpty else { throw checkError("\(path).\(group): expected a nonempty array") }
        try validateCheckList(children, ownerVariable: ownerVariable, path: "\(path).\(group)")
        return
    }
    if check.keys.contains("segment") || check.keys.contains("matches") {
        try validateSegmentCheckShape(check, path: path)
        return
    }
    if check.keys.contains("enabled") || check.keys.contains("variation") {
        try validateFeatureCheckShape(check, path: path)
        return
    }
    if check.keys.contains("feature"), !check.keys.contains("variable"), !check.keys.contains("operator") {
        throw checkError("\(path): feature check requires enabled or variation")
    }
    let allowed = Set(["variable", "feature", "path", "operator", "value", "compareTo", "regexFlags", "key", "description"])
    if let unknown = check.keys.first(where: { !allowed.contains($0) }) { throw checkError("\(path): unknown property \"\(unknown)\"") }
    guard let operation = check["operator"] as? String, knownCheckOperator(operation) else { throw checkError("\(path): unknown operator \"\(check["operator"] ?? NSNull())\"") }
    try validateReferenceShape(check, nested: false, ownerVariable: ownerVariable)
    let hasValue = check.keys.contains("value"), hasCompare = check.keys.contains("compareTo")
    let valueLess = ["exists", "notExists", "isNull", "notNull", "empty", "notEmpty"].contains(operation)
    if valueLess, hasValue || hasCompare { throw checkError("\(path): \(operation) accepts neither value nor compareTo") }
    if !valueLess, hasValue == hasCompare { throw checkError("\(path): exactly one of value or compareTo is required") }
    if hasCompare {
        guard let reference = check["compareTo"] as? [String: Any] else { throw checkError("\(path).compareTo: reference must be an object") }
        do { try validateReferenceShape(reference, nested: true, ownerVariable: ownerVariable) } catch { throw checkError("\(path).compareTo: \(error.localizedDescription)") }
    } else if hasValue {
        do { try validateCheckLiteral(operation, value: check["value"] ?? NSNull(), regexFlags: check["regexFlags"] as? String) }
        catch { throw checkError("\(path): \(error.localizedDescription)") }
    }
    if check.keys.contains("regexFlags") {
        guard operation == "matches" || operation == "notMatches" else { throw checkError("\(path): regexFlags are only allowed with regex operators") }
        guard let flags = check["regexFlags"] as? String else { throw checkError("\(path): regexFlags must be a string") }
        var seen = Set<Character>()
        for flag in flags { guard "gims".contains(flag), !seen.contains(flag) else { throw checkError("\(path): invalid or duplicate regex flag \"\(flag)\"") }; seen.insert(flag) }
    }
}

private func validateSegmentCheckShape(_ check: [String: Any], path: String) throws {
    let allowed = Set(["segment", "matches", "key", "description"])
    if let unknown = check.keys.first(where: { !allowed.contains($0) }) {
        throw checkError("\(path): segment check has unexpected property \"\(unknown)\"")
    }
    guard let segment = check["segment"] as? String, !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw checkError("\(path): segment must be a nonempty string")
    }
    guard let matches = check["matches"] as? NSNumber, String(cString: matches.objCType) == "c" else {
        throw checkError("\(path): segment \"\(segment)\" matches must be a boolean")
    }
}

private func validateSegmentReferences(_ checks: [Any], resolver: any CheckVariableResolver, path: String) throws {
    func visit(_ raw: Any, path: String) throws {
        guard let check = raw as? [String: Any] else { return }
        for group in ["and", "or", "not"] {
            if let children = check[group] as? [Any] {
                for (index, child) in children.enumerated() {
                    try visit(child, path: "\(path).\(group)[\(index)]")
                }
                return
            }
        }
        guard let segment = check["segment"] as? String else { return }
        guard let segmentValidator = resolver as? any CheckSegmentDefinitionValidator else {
            throw checkError("\(path): segment \"\(segment)\" definition is missing")
        }
        do { try segmentValidator.validateSegmentDefinition(segment) }
        catch { throw checkError("\(path): \(error.localizedDescription)") }
    }
    for (index, check) in checks.enumerated() {
        try visit(check, path: "\(path)[\(index)]")
    }
}

private func validateFeatureCheckShape(_ check: [String: Any], path: String) throws {
    let allowed = Set(["feature", "enabled", "variation", "key", "description"])
    if let unknown = check.keys.first(where: { !allowed.contains($0) }) {
        throw checkError("\(path): feature check has unexpected property \"\(unknown)\"")
    }
    guard let feature = check["feature"] as? String, !feature.isEmpty else {
        throw checkError("\(path): feature must be a nonempty string")
    }
    guard check.keys.contains("enabled") || check.keys.contains("variation") else {
        throw checkError("\(path): feature check requires enabled or variation")
    }
    if check.keys.contains("enabled") {
        guard let enabled = check["enabled"] as? NSNumber, String(cString: enabled.objCType) == "c" else {
            throw checkError("\(path): enabled must be a boolean")
        }
    }
    if check.keys.contains("variation"), !(check["variation"] is String), !(check["variation"] is NSNull) {
        throw checkError("\(path): variation must be a string or null")
    }
}

private func validateReferenceShape(_ reference: [String: Any], nested: Bool, ownerVariable: String?) throws {
    let allowed = nested ? Set(["variable", "feature", "path"]) : Set(["variable", "feature", "path", "operator", "value", "compareTo", "regexFlags", "key", "description"])
    if let unknown = reference.keys.first(where: { !allowed.contains($0) }) { throw checkError("unknown reference property \"\(unknown)\"") }
    if reference.keys.contains("feature") {
        guard let feature = reference["feature"] as? String, !feature.isEmpty else { throw checkError("feature must be a nonempty string") }
        guard let variable = reference["variable"] as? String, !variable.isEmpty else { throw checkError("variable is required for a feature reference") }
    }
    if reference.keys.contains("variable") { guard let variable = reference["variable"] as? String, !variable.isEmpty else { throw checkError("variable must be a nonempty string") } }
    if !reference.keys.contains("variable"), ownerVariable == nil || reference.keys.contains("feature") {
        throw checkError("an explicit variable is required in a scenario or feature reference")
    }
    if reference.keys.contains("path") { _ = try parseCheckPath(reference["path"]) }
}

private func validateCheckLiteral(_ operation: String, value: Any, regexFlags: String?) throws {
    let converted = checkAnyValue(value)
    switch operation {
    case "greaterThan", "greaterThanOrEquals", "lessThan", "lessThanOrEquals":
        guard let number = number(converted), number.isFinite else { throw checkError("numeric comparison requires a finite number") }
    case "contains", "notContains", "startsWith", "endsWith", "semverEquals", "semverNotEquals", "semverGreaterThan", "semverGreaterThanOrEquals", "semverLessThan", "semverLessThanOrEquals":
        guard case .string = converted else { throw checkError("string comparison requires a string") }
    case "matches", "notMatches":
        guard case .string(let pattern) = converted else { throw checkError("string comparison requires a string") }
        _ = try portableRegex(pattern, flags: regexFlags ?? "")
    case "before", "after":
        guard case .string(let timestamp) = converted, portableDate(timestamp) != nil else { throw checkError("date comparison requires a timestamp with a timezone") }
    case "in", "notIn", "includesAny", "notIncludesAny":
        guard case .array(let values) = converted, values.allSatisfy(isPrimitive) else { throw checkError("membership comparison requires an array of primitive values") }
    default:
        guard isPrimitive(converted) else { throw checkError("comparison requires a primitive value") }
    }
}

private func portableRegex(_ pattern: String, flags: String) throws -> NSRegularExpression {
    if pattern.contains("(?")
        || pattern.range(of: #"\\(?:[1-9]|k<|k'|g<|g')"#, options: .regularExpression) != nil
        || pattern.range(of: #"(?:[?*+]|\{\d+(?:,\d*)?\})\+"#, options: .regularExpression) != nil {
        throw checkError("unsupported portable regular expression")
    }
    var options: NSRegularExpression.Options = []
    for flag in flags {
        if flag == "i" { options.insert(.caseInsensitive) }
        else if flag == "m" { options.insert(.anchorsMatchLines) }
        else if flag == "s" { options.insert(.dotMatchesLineSeparators) }
        else if flag != "g" { throw checkError("unsupported regex flag \"\(flag)\"") }
    }
    do { return try NSRegularExpression(pattern: pattern, options: options) }
    catch { throw checkError("invalid regular expression: \(error.localizedDescription)") }
}

private func knownCheckOperator(_ operation: String) -> Bool {
    ["equals", "notEquals", "before", "after", "in", "notIn", "contains", "notContains", "startsWith", "endsWith", "greaterThan", "greaterThanOrEquals", "lessThan", "lessThanOrEquals", "semverEquals", "semverNotEquals", "semverGreaterThan", "semverGreaterThanOrEquals", "semverLessThan", "semverLessThanOrEquals", "matches", "notMatches", "exists", "notExists", "includes", "notIncludes", "includesAny", "notIncludesAny", "isNull", "notNull", "empty", "notEmpty"].contains(operation)
}

private func evaluateCheck(
    _ raw: Any,
    ownerVariable: String?,
    resolver: any CheckVariableResolver,
    datafile: DatafileContent,
    path: String,
    tracePath: [Any],
    evaluated: inout [[String: Any]]
) throws -> (matched: Bool, failure: String) {
    guard let check = raw as? [String: Any] else { throw checkError("\(path): check must be an object") }
    let displayPath = namedCheckPath(path, check: check)
    let groups = ["and", "or", "not"].filter { check.keys.contains($0) }
    if !groups.isEmpty {
        let metadataCount = (check.keys.contains("key") ? 1 : 0) + (check.keys.contains("description") ? 1 : 0)
        guard groups.count == 1, check.count == 1 + metadataCount else {
            throw checkError("\(path): group must contain exactly one of and, or, or not")
        }
        let operation = groups[0]
        guard let children = check[operation] as? [Any], !children.isEmpty else {
            throw checkError("\(path).\(operation): expected a nonempty array")
        }
        switch operation {
        case "and":
            for (index, child) in children.enumerated() {
                let result = try evaluateCheck(child, ownerVariable: ownerVariable, resolver: resolver, datafile: datafile, path: "\(path).and[\(index)]", tracePath: tracePath + ["and", index], evaluated: &evaluated)
                if !result.matched {
                    return displayPath == path ? result : (false, "\(displayPath): \(result.failure)")
                }
            }
            return (true, "")
        case "or":
            var failures: [String] = []
            for (index, child) in children.enumerated() {
                let result = try evaluateCheck(child, ownerVariable: ownerVariable, resolver: resolver, datafile: datafile, path: "\(path).or[\(index)]", tracePath: tracePath + ["or", index], evaluated: &evaluated)
                if result.matched { return (true, "") }
                failures.append(result.failure)
            }
            return (false, "\(displayPath): no OR branch matched (\(failures.joined(separator: "; ")))")
        default:
            for (index, child) in children.enumerated() {
                let result = try evaluateCheck(child, ownerVariable: ownerVariable, resolver: resolver, datafile: datafile, path: "\(path).not[\(index)]", tracePath: tracePath + ["not", index], evaluated: &evaluated)
                if !result.matched { return (true, "") }
            }
            return (false, "\(displayPath): NOT group matched")
        }
    }

    if check.keys.contains("segment") || check.keys.contains("matches") {
        return try evaluateSegmentCheck(check, resolver: resolver, path: displayPath, tracePath: tracePath, evaluated: &evaluated)
    }

    if check.keys.contains("enabled") || check.keys.contains("variation") {
        return try evaluateFeatureCheck(check, resolver: resolver, datafile: datafile, path: displayPath, tracePath: tracePath, evaluated: &evaluated)
    }
    if check.keys.contains("feature"), !check.keys.contains("variable") {
        throw checkError("\(path): feature check requires enabled or variation")
    }

    guard let operation = check["operator"] as? String, !operation.isEmpty else {
        throw checkError("\(path): leaf is missing operator")
    }
    let leftLabel = referenceLabel(check, ownerVariable: ownerVariable)
    let left: CheckResolved
    do { left = try resolveReference(check, ownerVariable: ownerVariable, resolver: resolver, datafile: datafile) }
    catch { throw checkError("\(displayPath) left \(leftLabel): \(error.localizedDescription)") }

    let hasValue = check.keys.contains("value")
    let hasCompareTo = check.keys.contains("compareTo")
    let valueLess = ["exists", "notExists", "isNull", "notNull", "empty", "notEmpty"].contains(operation)
    if valueLess, hasValue || hasCompareTo {
        throw checkError("\(path): \(operation) accepts neither value nor compareTo")
    }
    if !valueLess, hasValue == hasCompareTo {
        throw checkError("\(path): exactly one of value or compareTo is required")
    }

    let right: CheckResolved
    let rightLabel: String
    if hasCompareTo {
        guard let reference = check["compareTo"] as? [String: Any] else {
            throw checkError("\(path).compareTo: reference must be an object")
        }
        rightLabel = referenceLabel(reference, ownerVariable: ownerVariable)
        do { right = try resolveReference(reference, ownerVariable: ownerVariable, resolver: resolver, datafile: datafile) }
        catch { throw checkError("\(displayPath) right \(rightLabel): \(error.localizedDescription)") }
    } else {
        rightLabel = "literal"
        right = .value(checkAnyValue(check["value"] ?? NSNull()))
    }

    var trace: [String: Any] = [
        "path": tracePath,
        "reference": normalizedCheckReference(check, ownerVariable: ownerVariable),
        "operator": operation,
        "expected": hasValue || hasCompareTo ? reportCheckValue(right) : ["$type": "undefined"],
        "actual": reportCheckValue(left),
    ]
    if let key = check["key"] as? String { trace["key"] = key }
    if let description = check["description"] as? String { trace["description"] = description }
    if hasCompareTo, let reference = check["compareTo"] as? [String: Any] {
        trace["compareTo"] = normalizedCheckReference(reference, ownerVariable: ownerVariable)
    }
    if left == .missing { trace["actualMissing"] = true }
    if right == .missing { trace["expectedMissing"] = true }
    evaluated.append(trace)

    let matched: Bool
    do { matched = try matchCheckValues(left, operation: operation, right: right, regexFlags: check["regexFlags"] as? String) }
    catch {
        throw checkError("\(displayPath): \(leftLabel) against \(rightLabel) failed: \(error.localizedDescription) (left=\(displayValue(left)), right=\(displayValue(right)))")
    }
    if matched { return (true, "") }
    return (false, "\(displayPath): \(leftLabel) \(operation) \(rightLabel) did not match (left=\(displayValue(left)), right=\(displayValue(right)))")
}

private func evaluateSegmentCheck(
    _ check: [String: Any],
    resolver: any CheckVariableResolver,
    path: String,
    tracePath: [Any],
    evaluated: inout [[String: Any]]
) throws -> (matched: Bool, failure: String) {
    let segment = check["segment"] as! String
    let expected = (check["matches"] as! NSNumber).boolValue
    guard let segmentResolver = resolver as? any CheckSegmentResolver else {
        throw checkError("\(path): segment \"\(segment)\" definition is missing")
    }
    let actual: Bool
    do { actual = try segmentResolver.checkSegment(segment) }
    catch { throw checkError("\(path): \(error.localizedDescription)") }
    var trace: [String: Any] = [
        "path": tracePath,
        "reference": ["segment": segment],
        "property": "matches",
        "operator": "equals",
        "expected": expected,
        "actual": actual,
    ]
    if let key = check["key"] as? String { trace["key"] = key }
    if let description = check["description"] as? String { trace["description"] = description }
    evaluated.append(trace)
    if actual == expected { return (true, "") }
    return (false, "\(path): segment \"\(segment)\" expected matches=\(expected), actual matches=\(actual)")
}

private func normalizedCheckReference(_ reference: [String: Any], ownerVariable: String?) -> [String: Any] {
    var result: [String: Any] = [:]
    if let feature = reference["feature"] { result["feature"] = feature }
    if let variable = reference["variable"] { result["variable"] = variable }
    else if let ownerVariable { result["variable"] = ownerVariable }
    if let path = reference["path"] { result["path"] = path }
    return result
}

private func reportCheckValue(_ value: CheckResolved) -> Any {
    if value == .missing { return ["$type": "undefined"] }
    if case .value(let value) = value { return value.rawValue }
    return NSNull()
}

private func namedCheckPath(_ path: String, check: [String: Any]) -> String {
    var metadata: [String] = []
    if let key = check["key"] as? String { metadata.append("key=\"\(key)\"") }
    if let description = check["description"] as? String { metadata.append("description=\"\(description)\"") }
    return metadata.isEmpty ? path : "\(path) [\(metadata.joined(separator: ", "))]"
}

private func evaluateFeatureCheck(
    _ check: [String: Any],
    resolver: any CheckVariableResolver,
    datafile: DatafileContent,
    path: String,
    tracePath: [Any],
    evaluated: inout [[String: Any]]
) throws -> (matched: Bool, failure: String) {
    guard let feature = check["feature"] as? String, !feature.isEmpty else {
        throw checkError("\(path): feature must be a nonempty string")
    }
    guard datafile.features[feature] != nil else {
        throw checkError("\(path): feature \"\(feature)\" is absent from the selected datafile")
    }
    var matched = true
    var details: [String] = []
    if check.keys.contains("enabled") {
        guard let expected = check["enabled"] as? Bool else {
            throw checkError("\(path): enabled must be a boolean")
        }
        let actual: Bool
        do { actual = try resolver.checkFeatureEnabled(feature) }
        catch { throw checkError("\(path): feature \"\(feature)\" enabled getter failed: \(error.localizedDescription)") }
        var trace: [String: Any] = ["path": tracePath, "reference": ["feature": feature], "property": "enabled", "operator": "equals", "expected": expected, "actual": actual]
        appendCheckMetadata(&trace, check: check)
        evaluated.append(trace)
        details.append("expected enabled=\(expected), actual enabled=\(actual)")
        if actual != expected { matched = false }
    }
    if check.keys.contains("variation") {
        let expected = check["variation"] as? String
        let actual: String?
        do { actual = try resolver.checkFeatureVariation(feature) }
        catch { throw checkError("\(path): feature \"\(feature)\" variation getter failed: \(error.localizedDescription)") }
        var trace: [String: Any] = ["path": tracePath, "reference": ["feature": feature], "property": "variation", "operator": "equals", "expected": expected ?? NSNull(), "actual": actual ?? NSNull()]
        appendCheckMetadata(&trace, check: check)
        evaluated.append(trace)
        details.append("expected variation=\(displayVariation(expected)), actual variation=\(displayVariation(actual))")
        if actual != expected { matched = false }
    }
    if matched { return (true, "") }
    return (false, "\(path): feature \"\(feature)\" \(details.joined(separator: "; "))")
}

private func appendCheckMetadata(_ trace: inout [String: Any], check: [String: Any]) {
    if let key = check["key"] as? String { trace["key"] = key }
    if let description = check["description"] as? String { trace["description"] = description }
}

private func displayVariation(_ value: String?) -> String {
    guard let value else { return "null" }
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\(value)\""
}

private func resolveReference(
    _ reference: [String: Any],
    ownerVariable: String?,
    resolver: any CheckVariableResolver,
    datafile: DatafileContent
) throws -> CheckResolved {
    let feature = reference["feature"] as? String
    let explicitVariable = reference["variable"] as? String
    guard let variable = explicitVariable ?? ownerVariable, !variable.isEmpty else { throw checkError("variable is required") }
    if feature != nil, explicitVariable == nil { throw checkError("variable is required for a feature reference") }
    let initial: AnyValue
    if let featureKey = feature {
        guard let feature = datafile.features[featureKey] else { throw checkError("feature \"\(featureKey)\" is absent from the selected datafile") }
        guard feature.variablesSchema?[variable] != nil else { throw checkError("feature variable \"\(featureKey).\(variable)\" is absent from the selected datafile") }
        guard let value = try resolver.checkFeatureVariable(featureKey, variable) else { throw checkError("getter returned no value") }
        initial = value
    } else {
        guard datafile.variables?[variable] != nil else { throw checkError("global variable \"\(variable)\" is absent from the selected datafile") }
        guard let value = try resolver.checkGlobalVariable(variable) else { throw checkError("getter returned no value") }
        initial = value
    }
    var resolved = CheckResolved.value(initial)
    for part in try parseCheckPath(reference["path"]) {
        switch (resolved, part) {
        case let (.value(.object(object)), .property(key)):
            resolved = object[key].map(CheckResolved.value) ?? .missing
        case let (.value(.array(array)), .property(key)):
            if key == "length" { resolved = .value(.int(array.count)) }
            else if let index = canonicalCheckIndex(key), index < array.count { resolved = .value(array[index]) }
            else { resolved = .missing }
        case let (.value(.array(array)), .index(index)) where index < array.count:
            resolved = .value(array[index])
        default:
            resolved = .missing
        }
        if resolved == .missing { break }
    }
    return resolved
}

private func parseCheckPath(_ raw: Any?) throws -> [CheckPathPart] {
    guard let raw else { return [] }
    let unsafe: (String) -> Bool = { ["__proto__", "prototype", "constructor"].contains($0) }
    if let path = raw as? String {
        guard !path.isEmpty else { throw checkError("path must not be empty") }
        return try path.split(separator: ".", omittingEmptySubsequences: false).map { component in
            let value = String(component)
            guard !value.isEmpty, !value.contains("*"), !unsafe(value) else { throw checkError("path contains invalid component \"\(value)\"") }
            if canonicalCheckIndexSyntax(value) {
                guard let index = Int(value), index <= 9_007_199_254_740_991 else { throw checkError("path index must be a safe integer") }
                return .index(index)
            }
            return .property(value)
        }
    }
    guard let components = raw as? [Any] else { throw checkError("path must be a string or array") }
    return try components.map { component in
        if let property = component as? String {
            guard !property.contains("*"), !unsafe(property) else { throw checkError("path contains invalid component \"\(property)\"") }
            return .property(property)
        }
        if let index = component as? Int, index >= 0, index <= 9_007_199_254_740_991 { return .index(index) }
        if let number = component as? NSNumber, String(cString: number.objCType) != "c", number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991, number.doubleValue.rounded() == number.doubleValue {
            return .index(number.intValue)
        }
        throw checkError("path contains unsupported component \(component)")
    }
}

private func canonicalCheckIndex(_ value: String) -> Int? {
    guard canonicalCheckIndexSyntax(value), let index = Int(value), index <= 9_007_199_254_740_991 else { return nil }
    return index
}

private func canonicalCheckIndexSyntax(_ value: String) -> Bool {
    value == "0" || (!value.isEmpty && value.first != "0" && value.allSatisfy { $0 >= "0" && $0 <= "9" })
}

private func matchCheckValues(_ left: CheckResolved, operation: String, right: CheckResolved, regexFlags: String?) throws -> Bool {
    if operation == "exists" { return left != .missing }
    if operation == "notExists" { return left == .missing }
    if operation == "isNull" { return left == .value(.null) }
    if operation == "notNull" { return left != .missing && left != .value(.null) }
    if operation == "empty" || operation == "notEmpty" {
        guard case .value(let value) = left else { return false }
        let isEmpty: Bool
        switch value {
        case .string(let value): isEmpty = value.isEmpty
        case .array(let value): isEmpty = value.isEmpty
        case .object(let value): isEmpty = value.isEmpty
        case .null: return false
        default: throw checkError("\(operation) requires a string, array, or object operand")
        }
        return operation == "empty" ? isEmpty : !isEmpty
    }
    guard case .value(let leftValue) = left, case .value(let rightValue) = right else { return false }
    switch operation {
    case "equals":
        guard isPrimitive(leftValue), isPrimitive(rightValue) else { throw checkError("equals requires scalar operands") }
        return scalarEqual(leftValue, rightValue)
    case "notEquals":
        guard isPrimitive(leftValue), isPrimitive(rightValue) else { throw checkError("notEquals requires scalar operands") }
        return !scalarEqual(leftValue, rightValue)
    case "in", "notIn":
        guard isStringNumberOrNull(leftValue) else { throw checkError("\(operation) requires a string, number, or null left operand") }
        guard case .array(let values) = rightValue else { throw checkError("\(operation) requires an array right operand") }
        let found = values.contains { scalarEqual(leftValue, $0) }
        return operation == "in" ? found : !found
    case "includes", "notIncludes":
        guard case .array(let values) = leftValue else { throw checkError("\(operation) requires an array left operand") }
        guard isPrimitive(rightValue) else { throw checkError("\(operation) requires a primitive right operand") }
        let found = values.contains { scalarEqual($0, rightValue) }
        return operation == "includes" ? found : !found
    case "includesAny", "notIncludesAny":
        guard case .array(let values) = leftValue else { throw checkError("\(operation) requires an array left operand") }
        guard case .array(let candidates) = rightValue, candidates.allSatisfy(isPrimitive) else { throw checkError("\(operation) requires an array of primitive values") }
        let found = candidates.contains { candidate in values.contains { scalarEqual($0, candidate) } }
        return operation == "includesAny" ? found : !found
    case "greaterThan", "greaterThanOrEquals", "lessThan", "lessThanOrEquals":
        guard let lhs = number(leftValue), let rhs = number(rightValue) else { throw checkError("\(operation) requires numeric operands") }
        if operation == "greaterThan" { return lhs > rhs }
        if operation == "greaterThanOrEquals" { return lhs >= rhs }
        if operation == "lessThan" { return lhs < rhs }
        return lhs <= rhs
    case "before", "after":
        guard case .string(let lhs) = leftValue, case .string(let rhs) = rightValue, let leftDate = portableDate(lhs), let rightDate = portableDate(rhs) else { throw checkError("\(operation) requires valid RFC 3339 string dates") }
        return operation == "before" ? leftDate < rightDate : leftDate > rightDate
    case "contains", "notContains", "startsWith", "endsWith", "matches", "notMatches", "semverEquals", "semverNotEquals", "semverGreaterThan", "semverGreaterThanOrEquals", "semverLessThan", "semverLessThanOrEquals":
        guard case .string(let lhs) = leftValue, case .string(let rhs) = rightValue else { throw checkError("\(operation) requires string operands") }
        if operation == "contains" { return lhs.contains(rhs) }
        if operation == "notContains" { return !lhs.contains(rhs) }
        if operation == "startsWith" { return lhs.hasPrefix(rhs) }
        if operation == "endsWith" { return lhs.hasSuffix(rhs) }
        if operation == "matches" || operation == "notMatches" {
            let regex = try portableRegex(rhs, flags: regexFlags ?? "")
            let matched = regex.firstMatch(in: lhs, range: NSRange(lhs.startIndex..., in: lhs)) != nil
            return operation == "matches" ? matched : !matched
        }
        let comparison = try compareCheckSemver(lhs, rhs)
        if operation == "semverEquals" { return comparison == 0 }
        if operation == "semverNotEquals" { return comparison != 0 }
        if operation == "semverGreaterThan" { return comparison > 0 }
        if operation == "semverGreaterThanOrEquals" { return comparison >= 0 }
        if operation == "semverLessThan" { return comparison < 0 }
        return comparison <= 0
    default:
        throw checkError("unknown operator \"\(operation)\"")
    }
}

private func number(_ value: AnyValue) -> Double? { if case .int(let value) = value { return Double(value) }; if case .double(let value) = value { return value }; return nil }
private func checkAnyValue(_ value: Any) -> AnyValue {
    if let value = value as? String { return .string(value) }
    if let value = value as? NSNumber {
        let type = String(cString: value.objCType)
        if type == "c" { return .bool(value.boolValue) }
        if type.contains("f") || type.contains("d") { return .double(value.doubleValue) }
        return .int(value.intValue)
    }
    if let value = value as? [Any] { return .array(value.map(checkAnyValue)) }
    if let value = value as? [String: Any] { return .object(value.mapValues(checkAnyValue)) }
    return .null
}
private func isPrimitive(_ value: AnyValue) -> Bool { switch value { case .string, .int, .double, .bool, .null: return true; default: return false } }
private func isStringNumberOrNull(_ value: AnyValue) -> Bool { switch value { case .string, .int, .double, .null: return true; default: return false } }
private func scalarEqual(_ lhs: AnyValue, _ rhs: AnyValue) -> Bool { if let lhs = number(lhs), let rhs = number(rhs) { return lhs == rhs }; return isPrimitive(lhs) && isPrimitive(rhs) && lhs == rhs }
private func displayValue(_ value: CheckResolved) -> String { if value == .missing { return "<missing>" }; if case .value(let value) = value, let data = try? JSONEncoder().encode(value) { return String(decoding: data, as: UTF8.self) }; return "<invalid>" }
private func referenceLabel(_ reference: [String: Any], ownerVariable: String?) -> String { let variable = reference["variable"] as? String ?? ownerVariable ?? "<missing variable>"; var result = (reference["feature"] as? String).map { "\($0).\(variable)" } ?? variable; if let path = reference["path"] { result += "[\(path)]" }; return result }
private func checkError(_ message: String) -> NSError { NSError(domain: "FeaturevisorCLICheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

private func portableDate(_ value: String) -> Date? {
    let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(Z|([+-])([0-9]{2}):([0-9]{2}))$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
    func integer(_ index: Int) -> Int? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Swift.Range(range, in: value) else { return nil }
        return Int(value[swiftRange])
    }
    guard let year = integer(1), (1...9999).contains(year),
          let month = integer(2), (1...12).contains(month),
          let day = integer(3), let hour = integer(4), hour <= 23,
          let minute = integer(5), minute <= 59,
          let second = integer(6), second <= 59 else { return nil }
    let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard day >= 1, day <= days[month - 1] else { return nil }
    var offsetSeconds = 0
    if value[Swift.Range(match.range(at: 8), in: value)!] != "Z" {
        guard let offsetHour = integer(10), let offsetMinute = integer(11),
              offsetHour <= 14, offsetMinute <= 59,
              offsetHour != 14 || offsetMinute == 0 else { return nil }
        let sign = value[Swift.Range(match.range(at: 9), in: value)!] == "+" ? 1 : -1
        offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
    }
    guard let timezone = TimeZone(secondsFromGMT: offsetSeconds) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = timezone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    if let fractionRange = Swift.Range(match.range(at: 7), in: value) {
        let digits = String(value[fractionRange])
        let milliseconds = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        components.nanosecond = Int(milliseconds)! * 1_000_000
    }
    guard let date = calendar.date(from: components) else { return nil }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let utcComponents = utc.dateComponents([.era, .year], from: date)
    guard utcComponents.era == 1, let utcYear = utcComponents.year, (1...9999).contains(utcYear) else { return nil }
    return date
}

private func compareCheckSemver(_ lhs: String, _ rhs: String) throws -> Int {
    switch try compareVersions(lhs, rhs) {
    case .lessThan: return -1
    case .equal: return 0
    case .greaterThan: return 1
    }
}
