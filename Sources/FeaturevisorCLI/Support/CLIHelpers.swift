import Foundation
import FeaturevisorSDK

enum CLIHelpers {
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

    static func buildDatafileJSON(projectDirectoryPath: String, environment: String, schemaVersion: String, inflate: Int, tag: String? = nil) -> DatafileContent? {
        var args = ["build", "--environment=\(environment)", "--json"]
        if !schemaVersion.isEmpty { args.append("--schema-version=\(schemaVersion)") }
        if inflate > 0 { args.append("--inflate=\(inflate)") }
        if let tag { args.append("--tag=\(tag)") }

        let result = FeaturevisorProcess.run(projectDirectoryPath: projectDirectoryPath, args: args)
        guard result.code == 0 else {
            fputs(result.stderr + "\n", stderr)
            return nil
        }
        return try? DatafileContent.fromJSON(result.stdout)
    }
}
