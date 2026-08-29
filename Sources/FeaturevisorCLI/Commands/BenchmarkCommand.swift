import Foundation
import Featurevisor

struct BenchmarkOutput {
    let value: AnyValue?
    let duration: TimeInterval
    let minDuration: TimeInterval
    let averageDuration: TimeInterval
    let maxDuration: TimeInterval
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
        var value: AnyValue?
        var totalNanoseconds: UInt64 = 0
        var minNanoseconds: UInt64?
        var maxNanoseconds: UInt64 = 0

        for _ in 0..<n {
            let start = DispatchTime.now().uptimeNanoseconds
            value = block()
            let duration = DispatchTime.now().uptimeNanoseconds - start

            totalNanoseconds += duration
            if minNanoseconds == nil || duration < minNanoseconds! { minNanoseconds = duration }
            if duration > maxNanoseconds { maxNanoseconds = duration }
        }

        let totalSeconds = Double(totalNanoseconds) / 1_000_000_000
        return BenchmarkOutput(
            value: value,
            duration: totalSeconds,
            minDuration: Double(minNanoseconds ?? 0) / 1_000_000_000,
            averageDuration: totalSeconds / Double(n),
            maxDuration: Double(maxNanoseconds) / 1_000_000_000
        )
    }

    private func formatDurationMs(_ seconds: TimeInterval) -> String {
        String(format: "%.6fms", seconds * 1000)
    }

    func run(_ options: CLIOptions) -> Int32 {
        guard !options.environment.isEmpty else {
            print("Environment is required")
            return 1
        }
        guard !options.feature.isEmpty || !options.variable.isEmpty else {
            print("Feature or global variable is required")
            return 1
        }

        if options.targets.count > 1 {
            for target in options.targets {
                var selected = options
                selected.targets = [target]
                if run(selected) != 0 { return 1 }
            }
            return 0
        }

        let target = options.targets.first

        let context = CLIHelpers.parseContext(options.context)
        guard let datafile = CLIHelpers.buildDatafileJSON(
            projectDirectoryPath: options.projectDirectoryPath,
            environment: options.environment,
            inflate: options.inflate,
            target: target
        ) else {
            return 1
        }

        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: CLIHelpers.logLevel(options)))

        print("\nBenchmark Featurevisor feature")
        if options.feature.isEmpty { print("  Global variable: \(options.variable)") }
        else { print("  Feature: \(options.feature)") }
        print("  Environment: \(options.environment)")
        if let target { print("  Target: \(target)") }
        print("  Iterations: \(options.n)")
        print("Against context: \(options.context.isEmpty ? "{}" : options.context)")

        let output: BenchmarkOutput
        if options.feature.isEmpty {
            print("Evaluating global variable \"\(options.variable)\" \(options.n) times...")
            output = benchmark(options.n) { sdk.getVariable(options.variable, context) }
        } else if options.variation {
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
        print("Minimum duration: \(formatDurationMs(output.minDuration))")
        print("Average duration: \(formatDurationMs(output.averageDuration))")
        print("Maximum duration: \(formatDurationMs(output.maxDuration))")

        return 0
    }
}
