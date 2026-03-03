import Foundation

struct TestCommand {
    func run(_ options: CLIOptions) -> Int32 {
        var args = ["test"]
        if !options.keyPattern.isEmpty { args.append("--keyPattern=\(options.keyPattern)") }
        if !options.assertionPattern.isEmpty { args.append("--assertionPattern=\(options.assertionPattern)") }
        if options.onlyFailures { args.append("--onlyFailures") }
        if options.showDatafile { args.append("--showDatafile") }
        if options.withScopes { args.append("--with-scopes") }
        if options.withTags { args.append("--with-tags") }
        if options.verbose { args.append("--verbose") }
        if options.quiet { args.append("--quiet") }
        if options.inflate > 0 { args.append("--inflate=\(options.inflate)") }
        if !options.schemaVersion.isEmpty { args.append("--schema-version=\(options.schemaVersion)") }

        let result = FeaturevisorProcess.run(projectDirectoryPath: options.projectDirectoryPath, args: args)
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { fputs(result.stderr + "\n", stderr) }
        return result.code
    }
}
