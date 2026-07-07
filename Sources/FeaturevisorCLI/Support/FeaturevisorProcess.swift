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

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stdoutURL = temporaryDirectory.appendingPathComponent("featurevisor-swift-stdout-\(UUID().uuidString)")
        let stderrURL = temporaryDirectory.appendingPathComponent("featurevisor-swift-stderr-\(UUID().uuidString)")

        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return ProcessResult(code: 1, stdout: "", stderr: "Could not create temporary process output files")
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
            return ProcessResult(code: 1, stdout: "", stderr: error.localizedDescription)
        }

        try? stdoutHandle.close()
        try? stderrHandle.close()

        let outData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let errData = (try? Data(contentsOf: stderrURL)) ?? Data()

        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)

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
