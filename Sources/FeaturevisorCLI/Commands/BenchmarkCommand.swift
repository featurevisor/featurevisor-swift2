import Foundation
import Featurevisor

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
}
