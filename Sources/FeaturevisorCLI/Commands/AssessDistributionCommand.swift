import Foundation
import FeaturevisorSDK

struct AssessDistributionCommand {
    private func generateUuid() -> String {
        UUID().uuidString.lowercased()
    }

    private func formatPercentage(_ count: Int, _ total: Int) -> String {
        guard total > 0 else { return "0.00%" }
        return String(format: "%.2f%%", Double(count) * 100.0 / Double(total))
    }

    private func printCounts(_ counts: [String: Int], total: Int) {
        for key in counts.keys.sorted(by: { counts[$0, default: 0] > counts[$1, default: 0] }) {
            let count = counts[key, default: 0]
            print("  - \(key): \(count) \(formatPercentage(count, total))")
        }
    }

    func run(_ options: CLIOptions) -> Int32 {
        // Prefer delegated execution for compatibility with full Featurevisor project semantics.
        let delegatedCode = delegateIfPossible(options)
        if delegatedCode >= 0 {
            return delegatedCode
        }

        guard !options.environment.isEmpty else {
            print("Environment is required")
            return 1
        }
        guard !options.feature.isEmpty else {
            print("Feature is required")
            return 1
        }

        guard let datafile = CLIHelpers.buildDatafileJSON(
            projectDirectoryPath: options.projectDirectoryPath,
            environment: options.environment,
            schemaVersion: options.schemaVersion,
            inflate: options.inflate
        ) else {
            return 1
        }

        let sdk = createInstance(InstanceOptions(datafile: datafile, logLevel: CLIHelpers.loggerLevel(options)))
        let baseContext = CLIHelpers.parseContext(options.context)

        var flagCounts: [String: Int] = ["enabled": 0, "disabled": 0]
        var variationCounts: [String: Int] = [:]

        print("\nAssessing distribution for feature: \(options.feature)...")
        print("Against context: \(options.context.isEmpty ? "{}" : options.context)")
        print("Running \(options.n) times...")

        for _ in 0..<options.n {
            var current = baseContext
            for key in options.populateUuid {
                current[key] = .string(generateUuid())
            }

            let enabled = sdk.isEnabled(options.feature, current)
            flagCounts[enabled ? "enabled" : "disabled", default: 0] += 1

            if let variation = sdk.getVariation(options.feature, current) {
                variationCounts[variation, default: 0] += 1
            }
        }

        print("\n\nFlag evaluations:")
        printCounts(flagCounts, total: options.n)

        if !variationCounts.isEmpty {
            print("\n\nVariation evaluations:")
            printCounts(variationCounts, total: options.n)
        }

        return 0
    }

    private func delegateIfPossible(_ options: CLIOptions) -> Int32 {
        var args = ["assess-distribution"]
        if !options.environment.isEmpty { args.append("--environment=\(options.environment)") }
        if !options.feature.isEmpty { args.append("--feature=\(options.feature)") }
        if !options.context.isEmpty { args.append("--context=\(options.context)") }
        if options.n > 0 { args.append("--n=\(options.n)") }
        if !options.schemaVersion.isEmpty { args.append("--schema-version=\(options.schemaVersion)") }
        if options.inflate > 0 { args.append("--inflate=\(options.inflate)") }
        if options.verbose { args.append("--verbose") }
        if options.quiet { args.append("--quiet") }
        for key in options.populateUuid { args.append("--populateUuid=\(key)") }

        let result = FeaturevisorProcess.run(projectDirectoryPath: options.projectDirectoryPath, args: args)
        if result.code == 0 {
            if !result.stdout.isEmpty { print(result.stdout) }
            if !result.stderr.isEmpty { fputs(result.stderr + "\n", stderr) }
            return 0
        }

        return -1
    }
}
