import Foundation
import FeaturevisorSDK

struct BenchmarkOutput {
    let value: AnyValue?
    let duration: TimeInterval
}

struct BenchmarkCommand {
    private func prettyDuration(_ seconds: TimeInterval) -> String {
        let msTotal = Int(seconds * 1000)
        if msTotal == 0 { return "0ms" }

        let h = msTotal / 3_600_000
        let m = (msTotal % 3_600_000) / 60_000
        let s = (msTotal % 60_000) / 1_000
        let ms = msTotal % 1_000

        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 { parts.append("\(s)s") }
        if ms > 0 { parts.append("\(ms)ms") }
        return parts.joined(separator: " ")
    }

    private func benchmark(_ n: Int, _ block: () -> AnyValue?) -> BenchmarkOutput {
        let start = Date()
        var value: AnyValue?
        for _ in 0..<n { value = block() }
        return BenchmarkOutput(value: value, duration: Date().timeIntervalSince(start))
    }

    func run(_ options: CLIOptions) -> Int32 {
        // Fallback to native Featurevisor CLI benchmark for full parity when
        // datafile contains advanced serialized structures not yet decoded by SDK models.
        let delegatedCode = delegateIfNeeded(options)
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

        let context = CLIHelpers.parseContext(options.context)
        guard let datafile = CLIHelpers.buildDatafileJSON(
            projectDirectoryPath: options.projectDirectoryPath,
            environment: options.environment,
            schemaVersion: options.schemaVersion,
            inflate: options.inflate
        ) else {
            return 1
        }

        let sdk = createInstance(InstanceOptions(datafile: datafile, logLevel: CLIHelpers.loggerLevel(options)))

        print("\nRunning benchmark for feature \"\(options.feature)\"...")
        print("Against context: \(options.context.isEmpty ? "{}" : options.context)")

        let output: BenchmarkOutput
        if options.variation {
            print("Evaluating variation \(options.n) times...")
            output = benchmark(options.n) {
                sdk.getVariation(options.feature, context).map { .string($0) }
            }
        } else if !options.variable.isEmpty {
            print("Evaluating variable \"\(options.variable)\" \(options.n) times...")
            output = benchmark(options.n) {
                sdk.getVariable(options.feature, options.variable, context)
            }
        } else {
            print("Evaluating flag \(options.n) times...")
            output = benchmark(options.n) {
                .bool(sdk.isEnabled(options.feature, context))
            }
        }

        let valueString: String
        if let outputValue = output.value,
           let data = try? JSONEncoder().encode(outputValue),
           let text = String(data: data, encoding: .utf8) {
            valueString = text
        } else {
            valueString = "null"
        }

        print("\nEvaluated value : \(valueString)")
        print("Total duration  : \(prettyDuration(output.duration))")
        print("Average duration: \(prettyDuration(output.duration / Double(options.n)))")

        return 0
    }

    private func delegateIfNeeded(_ options: CLIOptions) -> Int32 {
        var args = ["benchmark"]
        if !options.environment.isEmpty { args.append("--environment=\(options.environment)") }
        if !options.feature.isEmpty { args.append("--feature=\(options.feature)") }
        if !options.context.isEmpty { args.append("--context=\(options.context)") }
        if options.n > 0 { args.append("--n=\(options.n)") }
        if options.variation { args.append("--variation") }
        if !options.variable.isEmpty { args.append("--variable=\(options.variable)") }
        if !options.schemaVersion.isEmpty { args.append("--schema-version=\(options.schemaVersion)") }
        if options.inflate > 0 { args.append("--inflate=\(options.inflate)") }
        if options.verbose { args.append("--verbose") }
        if options.quiet { args.append("--quiet") }

        let result = FeaturevisorProcess.run(projectDirectoryPath: options.projectDirectoryPath, args: args)
        if result.code == 0 {
            if !result.stdout.isEmpty { print(result.stdout) }
            if !result.stderr.isEmpty { fputs(result.stderr + "\n", stderr) }
            return 0
        }

        return -1
    }
}
