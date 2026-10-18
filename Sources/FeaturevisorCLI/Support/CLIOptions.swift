import Foundation

struct CLIOptions {
    var error: String?
    var help: Bool = false
    var command: String = ""
    var assertionPattern: String = ""
    var caseID: String = ""
    var context: String = ""
    var coverage: Bool = false
    var environment: String = ""
    var entityType: String = ""
    var feature: String = ""
    var keyPattern: String = ""
    var n: Int = 1000
    var onlyFailures: Bool = false
    var quiet: Bool = false
    var variable: String = ""
    var variation: Bool = false
    var verbose: Bool = false
    var inflate: Int?
    var json: Bool = false
    var pretty: Bool = false
    var withScopes: Bool = false
    var withTags: Bool = false
    var showDatafile: Bool = false
    var schemaVersion: String = ""
    var set: String = ""
    var setProvided: Bool = false
    var projectDirectoryPath: String = FileManager.default.currentDirectoryPath
    var populateUuid: [String] = []
    var targets: [String] = []
    var uncovered: Bool = false
    var silentTestOutput: Bool = false
    var coverageSink: TestCoverageCollector?
}

enum CLIParser {
    static func parse(_ args: [String]) -> CLIOptions {
        let invocationDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var opts = CLIOptions()

        if let first = args.first, !first.hasPrefix("-") {
            opts.command = first
        }

        let aliases = [
            "assertion-pattern": "assertionPattern", "key-pattern": "keyPattern",
            "only-failures": "onlyFailures", "entity-type": "entityType",
            "show-datafile": "showDatafile", "populate-uuid": "populateUuid",
            "project-directory-path": "projectDirectoryPath", "root-directory-path": "projectDirectoryPath",
            "rootDirectoryPath": "projectDirectoryPath", "schema-version": "schemaVersion",
        ]
        let strings: [String: WritableKeyPath<CLIOptions, String>] = [
            "assertionPattern": \.assertionPattern, "keyPattern": \.keyPattern, "case": \.caseID,
            "context": \.context, "environment": \.environment, "entityType": \.entityType,
            "feature": \.feature, "variable": \.variable, "schemaVersion": \.schemaVersion,
            "set": \.set, "projectDirectoryPath": \.projectDirectoryPath,
        ]
        let booleans: [String: WritableKeyPath<CLIOptions, Bool>] = [
            "onlyFailures": \.onlyFailures, "coverage": \.coverage, "json": \.json,
            "pretty": \.pretty, "quiet": \.quiet, "variation": \.variation, "verbose": \.verbose,
            "with-scopes": \.withScopes, "with-tags": \.withTags, "showDatafile": \.showDatafile,
            "uncovered": \.uncovered, "help": \.help, "h": \.help,
        ]
        var index = opts.command.isEmpty ? 0 : 1
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--" {
                if index == args.count { break }
                opts.error = "Unexpected arguments after --"
                return opts
            }
            guard arg.hasPrefix("--") || arg == "-h" || arg == "-n" || arg.hasPrefix("-n=") else {
                opts.error = "Unexpected argument: \(arg)"
                return opts
            }
            let parts = arg.dropFirst(arg.hasPrefix("--") ? 2 : 1).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawName = String(parts[0])
            let name = aliases[rawName] ?? rawName
            let inline = parts.count == 2 ? String(parts[1]) : nil
            if let key = booleans[name] {
                if let inline {
                    guard inline == "true" || inline == "false" else {
                        opts.error = "--\(rawName) must be true or false"
                        return opts
                    }
                    opts[keyPath: key] = inline == "true"
                } else {
                    opts[keyPath: key] = true
                }
                continue
            }
            guard strings[name] != nil || ["n", "inflate", "target", "populateUuid"].contains(name) else {
                opts.error = "Unknown option: --\(rawName)"
                return opts
            }
            if name == "set" { opts.setProvided = true }
            let value: String
            if let inline {
                value = inline
            } else {
                guard index < args.count,
                      !args[index].hasPrefix("-") || name == "n" || name == "inflate" else {
                    opts.error = "--\(rawName) requires a value"
                    return opts
                }
                value = args[index]
                index += 1
            }
            if let key = strings[name] {
                if value.isEmpty && !["set", "schemaVersion", "keyPattern", "assertionPattern"].contains(name) {
                    opts.error = "--\(rawName) must not be empty"
                    return opts
                }
                opts[keyPath: key] = value
            } else if name == "n" || name == "inflate" {
                let number = Int(value) ?? 0
                if name == "n" { opts.n = number } else { opts.inflate = number }
                guard number > 0 else {
                    opts.error = "--\(rawName) must be a positive integer"
                    return opts
                }
            } else {
                guard !value.isEmpty else {
                    opts.error = "--\(rawName) must not be empty"
                    return opts
                }
                if name == "populateUuid" { opts.populateUuid.append(value) }
                else if !opts.targets.contains(value) { opts.targets.append(value) }
            }
        }

        if !opts.entityType.isEmpty && !["feature", "segment", "variable", "scenario"].contains(opts.entityType) {
            opts.error = "--entity-type must be feature, segment, variable or scenario"
        }
        if !opts.context.isEmpty {
            let parsed = try? JSONSerialization.jsonObject(with: Data(opts.context.utf8))
            if !(parsed is [String: Any]) { opts.error = "--context must be a JSON object" }
        }

        opts.projectDirectoryPath = URL(
            fileURLWithPath: opts.projectDirectoryPath,
            isDirectory: true,
            relativeTo: invocationDirectory
        ).absoluteURL.standardizedFileURL.path

        return opts
    }
}
