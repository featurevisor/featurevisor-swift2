#if os(macOS)
import Foundation
import XCTest

final class ReadmeInitializationTests: XCTestCase {
    func testReadmeInitialization() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let section = try XCTUnwrap(readme.range(of: "## Initialization\n"))
        let fence = try XCTUnwrap(readme.range(of: "```swift\n", range: section.upperBound..<readme.endIndex))
        let end = try XCTUnwrap(readme.range(of: "\n```", range: fence.upperBound..<readme.endIndex))
        let snippet = String(readme[fence.upperBound..<end.lowerBound])
        XCTAssertEqual(snippet.components(separatedBy: "f.isEnabled(").count - 1, 1)
        XCTAssertTrue(snippet.contains("defer { f.close() }"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("featurevisor readme \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Compile an isolated consumer of the current SDK without invoking a nested package build.
        let sources = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sources/Featurevisor"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        let library = directory.appendingPathComponent("libFeaturevisor.dylib")
        let compileLibrary = try run([
            "swiftc", "-swift-version", "6", "-emit-library", "-emit-module",
            "-package-name", "featurevisor_swift2",
            "-module-name", "Featurevisor", "-emit-module-path",
            directory.appendingPathComponent("Featurevisor.swiftmodule").path,
            "-o", library.path,
        ] + sources.map(\.path), in: directory)
        try requireSuccess(compileLibrary)

        let source = directory.appendingPathComponent("example.swift")
        let executable = directory.appendingPathComponent("example")
        let compileArguments = [
            "swiftc", "-swift-version", "6", "-I", directory.path, "-L", directory.path,
            "-lFeaturevisor", "-Xlinker", "-rpath", "-Xlinker", directory.path,
            source.path, "-o", executable.path,
        ]
        // First compile the complete, unmodified Markdown example as a standalone program.
        try snippet.write(to: source, atomically: true, encoding: .utf8)
        try requireSuccess(run(compileArguments, in: directory))

        // Execute that same body with deterministic URLSession responses and observable cleanup.
        let lines = snippet.components(separatedBy: "\n")
        let imports = lines.filter { $0.hasPrefix("import ") }.joined(separator: "\n")
        let body = lines.filter { !$0.hasPrefix("import ") }.joined(separator: "\n")
        let harness = imports + "\n" + Self.transport + "\n" + """
        @MainActor func runExample() async throws -> Featurevisor {
        \(body)
            return f
        }

        do {
            let f = try await runExample()
            precondition(!f.setDatafile(json: ReadmeURLProtocol.fixture), "README instance was not closed")
        } catch {
            FileHandle.standardError.write(Data("loading failed: \\(error)\\n".utf8))
            exit(1)
        }
        """
        try harness.write(to: source, atomically: true, encoding: .utf8)
        try requireSuccess(run(compileArguments, in: directory))

        for mode in ["enabled", "disabled", "http-error", "invalid-json", "network-error"] {
            let result = try run([executable.path], in: directory, mode: mode)
            if mode == "enabled" || mode == "disabled" {
                XCTAssertEqual(result.status, 0, "\(mode): \(result.stderr)")
                XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                               mode == "enabled" ? "true" : "false", mode)
                XCTAssertTrue(result.stderr.contains("SDK initialized"), mode)
                XCTAssertFalse(result.stderr.contains("loading failed:"), mode)
            } else {
                XCTAssertEqual(result.status, 1, "\(mode): \(result.stderr)")
                XCTAssertTrue(result.stdout.isEmpty, "\(mode) evaluated before loading succeeded")
                XCTAssertFalse(result.stderr.contains("SDK initialized"), mode)
                XCTAssertTrue(result.stderr.contains("loading failed:"), "\(mode): \(result.stderr)")
            }
        }
    }

    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func requireSuccess(_ result: Result) throws {
        guard result.status == 0 else {
            XCTFail(result.stdout + result.stderr)
            throw NSError(domain: "ReadmeCompilation", code: Int(result.status))
        }
    }

    private func run(_ arguments: [String], in directory: URL, mode: String = "enabled") throws -> Result {
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let output = try FileHandle(forWritingTo: stdout)
        let errors = try FileHandle(forWritingTo: stderr)
        defer {
            try? output.close()
            try? errors.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["README_FIXTURE"] = mode
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 120) == .success else {
            process.terminate()
            throw NSError(domain: "ReadmeProcessTimeout", code: 1)
        }
        return Result(
            status: process.terminationStatus,
            stdout: try String(contentsOf: stdout, encoding: .utf8),
            stderr: try String(contentsOf: stderr, encoding: .utf8)
        )
    }

    private static let transport = #"""
    final class ReadmeURLProtocol: URLProtocol, @unchecked Sendable {
        static var fixture: String {
            let enabled = ProcessInfo.processInfo.environment["README_FIXTURE"] != "disabled"
            return """
            {"schemaVersion":"2","revision":"readme","segments":{},"variables":{},
             "features":{"checkout":{"key":"checkout","bucketBy":"userId","traffic":[
                {"key":"all","segments":"*","percentage":100000,"enabled":\(enabled)}
             ]}}}
            """
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard request.url?.absoluteString == "https://cdn.yoursite.com/featurevisor-all.json" else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let mode = ProcessInfo.processInfo.environment["README_FIXTURE"]
            if mode == "network-error" {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: mode == "http-error" ? 503 : 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((mode == "invalid-json" ? "{" : Self.fixture).utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    precondition(URLProtocol.registerClass(ReadmeURLProtocol.self))
    """#
}
#endif
