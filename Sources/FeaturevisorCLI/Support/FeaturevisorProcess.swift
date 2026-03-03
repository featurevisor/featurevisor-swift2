import Foundation

struct ProcessResult {
    var code: Int32
    var stdout: String
    var stderr: String
}

enum FeaturevisorProcess {
    static func run(projectDirectoryPath: String, args: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "featurevisor"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: projectDirectoryPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(code: 1, stdout: "", stderr: error.localizedDescription)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            code: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func runJSON(projectDirectoryPath: String, args: [String]) throws -> Any {
        let result = run(projectDirectoryPath: projectDirectoryPath, args: args)
        guard result.code == 0 else {
            throw NSError(domain: "FeaturevisorCLI", code: Int(result.code), userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }

        let data = Data(result.stdout.utf8)
        return try JSONSerialization.jsonObject(with: data)
    }
}
