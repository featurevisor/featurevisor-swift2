import Foundation
import Featurevisor

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
}
