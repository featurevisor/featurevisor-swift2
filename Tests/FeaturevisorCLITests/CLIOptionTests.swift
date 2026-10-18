import Foundation
import XCTest
@testable import FeaturevisorCLI

final class CLIOptionTests: XCTestCase {
    func testAliasesAndValueForms() {
        let aliases: [(String, String, KeyPath<CLIOptions, String>)] = [
            ("key-pattern", "keyPattern", \.keyPattern),
            ("assertion-pattern", "assertionPattern", \.assertionPattern),
            ("entity-type", "entityType", \.entityType),
            ("project-directory-path", "projectDirectoryPath", \.projectDirectoryPath),
            ("root-directory-path", "projectDirectoryPath", \.projectDirectoryPath),
            ("rootDirectoryPath", "projectDirectoryPath", \.projectDirectoryPath),
        ]
        for command in ["test", "benchmark", "assess-distribution"] {
            for (alias, original, key) in aliases {
                let value = alias == "entity-type" ? "feature" : "a space and 'quote' = value"
                let expected = CLIParser.parse([command, "--\(original)=\(value)"])
                for flags in [["--\(alias)=\(value)"], ["--\(alias)", value]] {
                    let options = CLIParser.parse([command] + flags)
                    XCTAssertNil(options.error, "\(flags)")
                    XCTAssertEqual(options[keyPath: key], expected[keyPath: key])
                }
            }
            for flags in [["--only-failures", "--show-datafile"], ["--onlyFailures=true", "--showDatafile=true"]] {
                let options = CLIParser.parse([command] + flags)
                XCTAssertNil(options.error)
                XCTAssertTrue(options.onlyFailures)
                XCTAssertTrue(options.showDatafile)
            }
            let falseFlags = CLIParser.parse([command, "--only-failures=false", "--show-datafile=false"])
            XCTAssertFalse(falseFlags.onlyFailures)
            XCTAssertFalse(falseFlags.showDatafile)
            for flag in ["--n", "-n"] {
                for flags in [["\(flag)=2"], [flag, "2"]] {
                    let options = CLIParser.parse([command] + flags)
                    XCTAssertNil(options.error)
                    XCTAssertEqual(options.n, 2)
                }
            }
        }
        let options = CLIParser.parse(["assess-distribution", "--target", "web", "--populate-uuid", "userId",
            "--target=mobile", "--populateUuid=deviceId", "--target=web", "--populate-uuid=accountId"])
        XCTAssertNil(options.error)
        XCTAssertEqual(options.targets, ["web", "mobile"])
        XCTAssertEqual(options.populateUuid, ["userId", "deviceId", "accountId"])
        let context = #"{"name":"Ada Lovelace","quote":"it's a \"test\"","literal":"$(touch marker)"}"#
        XCTAssertEqual(CLIParser.parse(["benchmark", "--context", context]).context, context)
        XCTAssertNil(CLIParser.parse(["benchmark", "--context", context]).error)
    }

    func testInvalidArgumentsFailBeforeDelegation() throws {
        var invalid = [["--typo"], ["extra"], ["--target=web", "extra"], ["--", "extra"],
                       ["--only-failures=wat"], ["--entity-type=typo"]]
        for name in ["target", "populate-uuid", "key-pattern", "project-directory-path", "context", "set", "n", "inflate"] {
            invalid += [["--\(name)"], ["--\(name)", "--quiet"]]
        }
        for name in ["target", "populate-uuid", "project-directory-path", "context", "feature", "entity-type"] {
            invalid.append(["--\(name)="])
        }
        for name in ["--n", "-n", "--inflate"] {
            for value in ["0", "-1", "1.5", "NaN", "", "999999999999999999999"] {
                invalid += [["\(name)=\(value)"], [name, value]]
            }
        }
        for context in ["[]", "null", "42", "true", "{"] { invalid.append(["--context", context]) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let npx = directory.appendingPathComponent("npx")
        try "#!/bin/sh\ntouch delegated\nexit 99\n".write(to: npx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npx.path)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(directory.path):\(path)", 1)
        defer { setenv("PATH", path, 1) }
        for command in ["test", "benchmark", "assess-distribution"] {
            for flags in invalid {
                let args = [command, "--project-directory-path", directory.path, "--feature=checkout"] + flags
                XCTAssertNotNil(CLIParser.parse(args).error, "\(args)")
                XCTAssertNotEqual(CLI().run(args: args), 0, "\(args)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("delegated").path))
    }

    func testHelpAndDispatchWithoutDelegation() {
        for args in [[], ["--help"], ["-h"], ["help"], ["help", "test"], ["test", "--help"],
                     ["benchmark", "--help"], ["assess-distribution", "-h"]] {
            XCTAssertEqual(CLI().run(args: args), 0, "\(args)")
        }
        for args in [["typo"], ["evaluate"], ["help", "typo"], ["help", "test", "extra"], ["--quiet"]] {
            XCTAssertNotEqual(CLI().run(args: args), 0, "\(args)")
        }
    }

    func testDelegationPreservesArgumentBoundariesAndStreams() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swift cli 'quoted' \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let npx = directory.appendingPathComponent("npx")
        try #"""
        #!/bin/sh
        printf '%s\n' "$@" > arguments
        printf '{"ok":true}'
        printf 'warning\n' >&2
        """#.write(to: npx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npx.path)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(directory.path):\(path)", 1)
        defer { setenv("PATH", path, 1) }
        let args = ["list", "--keyPattern=a 'quoted' value", #"--context={"name":"Ada Lovelace","literal":"$(touch marker)"}"#, "--json"]
        let result = FeaturevisorProcess.run(projectDirectoryPath: directory.path, args: args)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stdout, #"{"ok":true}"#)
        XCTAssertEqual(result.stderr, "warning")
        let captured = try String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8)
        XCTAssertEqual(captured, (["featurevisor"] + args).joined(separator: "\n") + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("marker").path))
    }

    func testUsageErrorsKeepStdoutEmpty() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/featurevisor")
        for args in [["typo"], ["test", "--json", "--unknown"], ["benchmark"],
                     ["assess-distribution", "--feature=checkout", "--context=[]"],
                     ["test", "--target=web", "extra"]] {
            let process = Process()
            process.executableURL = binary
            process.arguments = args
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            XCTAssertNotEqual(process.terminationStatus, 0, "\(args)")
            XCTAssertTrue(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty, "\(args)")
            XCTAssertFalse(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty, "\(args)")
        }
    }
}
