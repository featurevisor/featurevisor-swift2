import Foundation

struct CLIOptions {
    var command: String = ""
    var assertionPattern: String = ""
    var context: String = ""
    var environment: String = ""
    var feature: String = ""
    var keyPattern: String = ""
    var n: Int = 1000
    var onlyFailures: Bool = false
    var quiet: Bool = false
    var variable: String = ""
    var variation: Bool = false
    var verbose: Bool = false
    var inflate: Int = 0
    var withScopes: Bool = false
    var withTags: Bool = false
    var showDatafile: Bool = false
    var schemaVersion: String = ""
    var projectDirectoryPath: String = FileManager.default.currentDirectoryPath
    var populateUuid: [String] = []
}

enum CLIParser {
    static func parse(_ args: [String]) -> CLIOptions {
        var opts = CLIOptions()

        if let first = args.first, !first.hasPrefix("--") {
            opts.command = first
        }

        for arg in args.dropFirst(opts.command.isEmpty ? 0 : 1) {
            if arg == "--onlyFailures" { opts.onlyFailures = true; continue }
            if arg == "--quiet" { opts.quiet = true; continue }
            if arg == "--variation" { opts.variation = true; continue }
            if arg == "--verbose" { opts.verbose = true; continue }
            if arg == "--with-scopes" { opts.withScopes = true; continue }
            if arg == "--with-tags" { opts.withTags = true; continue }
            if arg == "--showDatafile" { opts.showDatafile = true; continue }

            func read(_ prefix: String) -> String? {
                arg.hasPrefix(prefix) ? String(arg.dropFirst(prefix.count)) : nil
            }

            if let value = read("--assertionPattern=") { opts.assertionPattern = value }
            else if let value = read("--context=") { opts.context = value }
            else if let value = read("--environment=") { opts.environment = value }
            else if let value = read("--feature=") { opts.feature = value }
            else if let value = read("--keyPattern=") { opts.keyPattern = value }
            else if let value = read("--n=") { opts.n = Int(value) ?? 1000 }
            else if let value = read("--variable=") { opts.variable = value }
            else if let value = read("--inflate=") { opts.inflate = Int(value) ?? 0 }
            else if let value = read("--schema-version=") { opts.schemaVersion = value }
            else if let value = read("--schemaVersion=") { opts.schemaVersion = value }
            else if let value = read("--projectDirectoryPath=") { opts.projectDirectoryPath = value }
            else if let value = read("--populateUuid=") { opts.populateUuid.append(value) }
        }

        return opts
    }
}
