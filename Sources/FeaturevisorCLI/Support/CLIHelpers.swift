import Foundation
import Featurevisor

enum CLIHelpers {
    static let noEnvironmentKey = "__no_environment__"

    static func loggerLevel(_ options: CLIOptions) -> LogLevel {
        if options.verbose { return .debug }
        if options.quiet { return .error }
        return .warn
    }

    static func parseContext(_ raw: String) -> Context {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        guard let dict = object as? [String: Any] else { return [:] }
        return dict.mapValues(anyToAnyValue)
    }

    static func parseContext(_ raw: [String: Any]?) -> Context {
        guard let raw else { return [:] }
        return raw.mapValues(anyToAnyValue)
    }

    static func anyToAnyValue(_ value: Any) -> AnyValue {
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let number as NSNumber:
            let type = String(cString: number.objCType)
            if type == "c" { return .bool(number.boolValue) }
            if type.contains("f") || type.contains("d") { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let array as [Any]:
            return .array(array.map(anyToAnyValue))
        case let object as [String: Any]:
            return .object(object.mapValues(anyToAnyValue))
        default:
            return .null
        }
    }

    static func parseDatafile(_ json: String) -> DatafileContent? {
        try? DatafileContent.fromJSON(json)
    }

    static func runJSON(projectDirectoryPath: String, args: [String]) -> Any? {
        let result = FeaturevisorProcess.run(projectDirectoryPath: projectDirectoryPath, args: args)
        guard result.code == 0 else {
            if !result.stderr.isEmpty { fputs(result.stderr + "\n", stderr) }
            return nil
        }
        guard let data = result.stdout.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func buildDatafileJSON(projectDirectoryPath: String, environment: String?, schemaVersion: String, inflate: Int, tag: String? = nil) -> DatafileContent? {
        var args = ["build"]
        if let environment, !environment.isEmpty {
            args.append("--environment=\(environment)")
        }
        if !schemaVersion.isEmpty { args.append("--schema-version=\(schemaVersion)") }
        if inflate > 0 { args.append("--inflate=\(inflate)") }
        if let tag { args.append("--tag=\(tag)") }
        args.append("--json")

        let result = FeaturevisorProcess.run(projectDirectoryPath: projectDirectoryPath, args: args)
        guard result.code == 0 else {
            fputs(result.stderr + "\n", stderr)
            return nil
        }
        return try? DatafileContent.fromJSON(result.stdout)
    }

    static func mapStringAny(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static func boolValue(_ value: Any?) -> Bool? {
        value as? Bool
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    static func anyToCondition(_ value: Any) -> Condition {
        if let string = value as? String {
            if string == "*" { return .all }
            if let data = string.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                return anyToCondition(json)
            }
            return .invalidToken(string)
        }

        if let array = value as? [Any] {
            return .list(array.map(anyToCondition))
        }

        if let object = value as? [String: Any] {
            if let and = object["and"] as? [Any] {
                return .and(and.map(anyToCondition))
            }
            if let or = object["or"] as? [Any] {
                return .or(or.map(anyToCondition))
            }
            if let not = object["not"] as? [Any] {
                return .not(not.map(anyToCondition))
            }
            if let attribute = object["attribute"] as? String,
               let op = object["operator"] as? String {
                let value = object["value"].map(anyToAnyValue)
                let flags = object["regexFlags"] as? String
                return .predicate(ConditionPredicate(attribute: attribute, operator: op, value: value, regexFlags: flags))
            }
        }

        return .invalidToken("invalid")
    }

    static func anyToSticky(_ value: Any?) -> StickyFeatures? {
        guard let object = value as? [String: Any] else { return nil }
        var result: StickyFeatures = [:]

        for (featureKey, raw) in object {
            guard let featureMap = raw as? [String: Any],
                  let enabled = featureMap["enabled"] as? Bool else {
                continue
            }
            let variation = featureMap["variation"] as? String
            let variables = (featureMap["variables"] as? [String: Any])?.mapValues(anyToAnyValue)
            result[featureKey] = EvaluatedFeature(enabled: enabled, variation: variation, variables: variables)
        }

        return result
    }

    static func compareExpected(_ actual: AnyValue?, expected: Any?) -> Bool {
        guard let expected else { return actual == nil || actual == .null }
        let expectedValue = anyToAnyValue(expected)
        guard let actual else { return expectedValue == .null }
        return actual == expectedValue
    }

    static func compareExpected(_ actual: AnyValue?, expected: Any?, schemaType: String?) -> Bool {
        if schemaType == "json",
           let expectedString = expected as? String,
           let data = expectedString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            return compareExpected(actual, expected: parsed)
        }

        guard let actual else {
            return compareAnyExpected(nil, expected: expected)
        }

        return compareAnyExpected(actual.rawValue, expected: expected)
    }

    static func compareAnyExpected(_ actual: Any?, expected: Any?) -> Bool {
        switch (actual, expected) {
        case (nil, nil):
            return true
        case (nil, let rhs?):
            return rhs is NSNull
        case (let lhs?, nil):
            if let lhs = lhs as? NSNull { return lhs is NSNull }
            return false
        case (let lhs as NSNull, let rhs as NSNull):
            return lhs is NSNull && rhs is NSNull
        case (let lhs as NSNumber, let rhs as NSNumber):
            if isBool(lhs) || isBool(rhs) {
                return lhs.boolValue == rhs.boolValue
            }
            return lhs.doubleValue == rhs.doubleValue
        case (let lhs as String, let rhs as String):
            return lhs == rhs
        case (let lhs as [Any], let rhs as [Any]):
            guard lhs.count == rhs.count else { return false }
            for index in lhs.indices where !compareAnyExpected(lhs[index], expected: rhs[index]) {
                return false
            }
            return true
        case (let lhs as [String: Any], let rhs as [String: Any]):
            guard lhs.count == rhs.count else { return false }
            for (key, value) in lhs {
                guard rhs.keys.contains(key), compareAnyExpected(value, expected: rhs[key]) else {
                    return false
                }
            }
            return true
        default:
            return String(describing: actual) == String(describing: expected)
        }
    }

    static func evaluationFieldValue(_ evaluation: Evaluation, key: String) -> Any? {
        switch key {
        case "type": return evaluation.type.rawValue
        case "featureKey": return evaluation.featureKey
        case "reason": return evaluation.reason.rawValue
        case "bucketKey": return evaluation.bucketKey
        case "bucketValue": return evaluation.bucketValue
        case "ruleKey": return evaluation.ruleKey
        case "enabled": return evaluation.enabled
        case "forceIndex": return evaluation.forceIndex
        case "variationValue": return evaluation.variationValue
        case "variableKey": return evaluation.variableKey
        case "variableOverrideIndex": return evaluation.variableOverrideIndex
        case "variableValue": return evaluation.variableValue?.rawValue
        default:
            return nil
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        String(cString: number.objCType) == "c"
    }
}
