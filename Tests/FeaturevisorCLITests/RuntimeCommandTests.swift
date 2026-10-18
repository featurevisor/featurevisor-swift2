import Foundation
import XCTest
@testable import FeaturevisorCLI

final class RuntimeCommandTests: XCTestCase {
    func testFlatProjectsRejectExplicitSetsIncludingEmptyValues() throws {
        XCTAssertFalse(CLIParser.parse(["test"]).setProvided)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swift-sets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let npx = directory.appendingPathComponent("npx")
        try #"""
        #!/bin/sh
        printf '%s\n' "$*" >> commands
        case "$2" in
          config) printf '%s\n' '{"sets":false}' ;;
          list)
            case "$*" in
              *--tests*) printf '%s\n' '{"kind":"featurevisor.test-execution","schemaVersion":1,"tests":[]}' ;;
              *) printf '%s\n' '[]' ;;
            esac ;;
          build) printf '%s\n' '{"schemaVersion":"2","revision":"1","segments":{},"features":{},"variables":{}}' ;;
          *) exit 19 ;;
        esac
        """#.write(to: npx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npx.path)
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(directory.path):\(oldPath)", 1)
        defer { setenv("PATH", oldPath, 1) }
        let log = directory.appendingPathComponent("commands")
        for command in ["test", "benchmark", "assess-distribution"] {
            let args = [command, "--projectDirectoryPath=\(directory.path)", "--feature=checkout", "--n=1"]
            XCTAssertEqual(CLI().run(args: args), 0, "Omission must remain valid")
            for flags in [["--set=unexpected"], ["--set="], ["--set"]] {
                let options = CLIParser.parse(args + flags)
                XCTAssertTrue(options.setProvided)
                XCTAssertThrowsError(try CLIHelpers.projectSets(options: options, config: ["sets": false])) { error in
                    XCTAssertTrue(error.localizedDescription.contains("Omit --set"))
                }
                try Data().write(to: log)
                XCTAssertEqual(CLI().run(args: args + flags), 1, "\(command) \(flags)")
                let expected = flags == ["--set"] ? "" : "featurevisor config --json\n"
                XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), expected, "Missing values fail before delegation, invalid selections before tests or builds")
            }
        }
    }

    func testInflateValidationAndForwarding() throws {
        XCTAssertNil(CLIParser.parse(["benchmark"]).inflate)
        XCTAssertEqual(CLIParser.parse(["benchmark", "--inflate=0"]).inflate, 0)
        XCTAssertEqual(CLIParser.parse(["benchmark", "--inflate=1"]).inflate, 1)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swift inflate \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("npx")
        try #"""
        #!/bin/sh
        printf '%s\n' "$*" >> commands
        case "$*" in
          *"config --json"*) printf '%s\n' '{}' ;;
          *"list --tests"*) printf '%s\n' '{"kind":"featurevisor.test-execution","schemaVersion":1,"tests":[]}' ;;
          *"list --segments"*|*"list --targets"*) printf '%s\n' '[]' ;;
          *"build"*) printf '%s\n' '{"schemaVersion":"2","revision":"1","segments":{},"features":{},"variables":{}}' ;;
          *) exit 17 ;;
        esac
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(directory.path):\(oldPath)", 1)
        defer { setenv("PATH", oldPath, 1) }
        let log = directory.appendingPathComponent("commands")
        for command in ["benchmark", "assess-distribution", "test"] {
            let args = [command, "--projectDirectoryPath=\(directory.path)", "--feature=checkout", "--n=1"]
            try Data().write(to: log)
            for value in ["0", "-1", "0.5", "1.5", "invalid", "", "999999999999999999999999999999"] {
                XCTAssertEqual(CLI().run(args: args + ["--inflate=\(value)"]), 1, "\(command) --inflate=\(value)")
            }
            XCTAssertEqual(CLI().run(args: args + ["--inflate"]), 1)
            XCTAssertEqual(try Data(contentsOf: log).count, 0, "Invalid inflate must fail before delegation")
            for flags in [[], ["--inflate=1"]] {
                try Data().write(to: log)
                XCTAssertEqual(CLI().run(args: args + flags), 0)
                let builds = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").filter { $0.contains(" build ") }.map(String.init)
                XCTAssertEqual(builds, [flags.isEmpty ? "featurevisor build --json" : "featurevisor build --inflate=1 --json"])
            }
        }
    }

    func testRelativeProjectDirectoryWithSpacesReachesDelegatedProcess() throws {
        let invocationDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let relativeDirectory = ".build/cli relative \(UUID().uuidString)"
        let directory = invocationDirectory.appendingPathComponent(relativeDirectory)
        let project = directory.appendingPathComponent("project with spaces")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("npx")
        try #"""
        #!/bin/sh
        pwd -P >> delegated-directories
        case "$*" in
          *"config --json"*) printf '%s\n' '{}' ;;
          *"list --tests"*) printf '%s\n' '{"kind":"featurevisor.test-execution","schemaVersion":1,"tests":[]}' ;;
          *"list --segments"*|*"list --targets"*) printf '%s\n' '[]' ;;
          *"build"*) printf '%s\n' '{"schemaVersion":"2","revision":"1","segments":{},"features":{},"variables":{}}' ;;
          *) exit 17 ;;
        esac
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(directory.path):\(oldPath)", 1)
        defer { setenv("PATH", oldPath, 1) }

        let relativeProject = "./\(relativeDirectory)/project with spaces/../project with spaces"
        let options = CLIParser.parse(["test", "--projectDirectoryPath=\(relativeProject)"])
        XCTAssertEqual(options.projectDirectoryPath, project.standardizedFileURL.path)
        XCTAssertEqual(CLIParser.parse(["test"]).projectDirectoryPath, invocationDirectory.path)
        XCTAssertEqual(CLIParser.parse(["test", "--projectDirectoryPath=\(project.path)"]).projectDirectoryPath, project.path)

        let parentRelativeProject = "../\(invocationDirectory.lastPathComponent)/\(relativeDirectory)/project with spaces"
        for path in [relativeProject, parentRelativeProject] {
            for command in ["test", "benchmark", "assess-distribution"] {
                XCTAssertEqual(CLI().run(args: [command, "--projectDirectoryPath=\(path)", "--feature=checkout", "--n=1"]), 0, command)
            }
        }
        let paths = try String(contentsOf: project.appendingPathComponent("delegated-directories"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(paths.count, 18)
        XCTAssertEqual(Set(paths), [project.resolvingSymlinksInPath().path])
        XCTAssertEqual(FileManager.default.currentDirectoryPath, invocationDirectory.path)
    }

    func testSelectionDelegationAndBuildFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("npx")
        try #"""
        #!/bin/sh
        printf '%s\n' "$*" >> commands
        case "$*" in
          *"config --json"*) cat config.json; exit 0 ;;
          *--environment=unknown*|*--set=unknown*|*--target=unknown*) echo 'Invalid project selection' >&2; exit 17 ;;
          *--target=malformed*) echo 'not JSON'; exit 0 ;;
        esac
        printf '%s\n' '{"schemaVersion":"2","revision":"1","segments":{},"features":{"checkout":{"bucketBy":"userId","traffic":[{"key":"all","segments":"*","percentage":100000}]}},"variables":{"colour":{"type":"string","defaultValue":"blue"}}}'
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(directory.path):\(oldPath)", 1)
        defer { setenv("PATH", oldPath, 1) }

        for command in ["benchmark", "assess-distribution"] {
            let base = [command, "--root-directory-path", directory.path, "--feature", "checkout", "-n", "1"]
            let config = directory.appendingPathComponent("config.json")
            try "{}".write(to: config, atomically: true, encoding: .utf8)
            XCTAssertEqual(CLI().run(args: base), 0)
            try #"{"sets":true}"#.write(to: config, atomically: true, encoding: .utf8)
            XCTAssertEqual(CLI().run(args: base + ["--environment", "production", "--set", "storefront", "--target", "web", "--target=mobile", "--target=web", "--populate-uuid", "userId", "--populateUuid=deviceId"]), 0)
            try "{}".write(to: config, atomically: true, encoding: .utf8)
            for invalid in ["--environment=unknown", "--set=unknown", "--target=unknown", "--target=malformed"] {
                XCTAssertEqual(CLI().run(args: base + [invalid]), 1, "\(command) \(invalid)")
            }
            XCTAssertEqual(CLI().run(args: base + ["--target=web", "--target=unknown", "--target=unreached"]), 1)
        }
        XCTAssertEqual(CLI().run(args: ["benchmark", "--projectDirectoryPath=\(directory.path)", "--variable=colour", "--n=1"]), 0)
        let commands = try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
        XCTAssertTrue(commands.contains("featurevisor build --json\n"))
        XCTAssertEqual(commands.components(separatedBy: "--target=web --set=storefront").count - 1, 2)
        XCTAssertEqual(commands.components(separatedBy: "--target=mobile --set=storefront").count - 1, 2)
        XCTAssertTrue(commands.contains("--environment=production"))
        XCTAssertFalse(commands.contains("--environment= --"))
        XCTAssertFalse(commands.contains("unreached"))
    }

    func testInvalidOptionsFailBeforeDelegation() {
        for command in ["benchmark", "assess-distribution"] {
            XCTAssertEqual(CLI().run(args: [command]), 1)
            for n in ["0", "-1", "invalid", "1.5"] {
                XCTAssertEqual(CLI().run(args: [command, "--feature=checkout", "--n=\(n)"]), 1)
            }
        }
        XCTAssertEqual(CLI().run(args: ["benchmark", "--variable=colour", "--variation"]), 1)
        XCTAssertEqual(CLI().run(args: ["benchmark", "--feature=checkout", "--variable=colour", "--variation"]), 1)
    }

    func testAllSetsAndExplicitSetsWithNestedTargets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swift sets \(UUID().uuidString)")
        let sets = directory.appendingPathComponent("lanes with spaces")
        try FileManager.default.createDirectory(at: sets.appendingPathComponent("store front"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sets.appendingPathComponent("admin"), withIntermediateDirectories: true)
        try Data().write(to: sets.appendingPathComponent("ignored.txt"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try #"{"sets":true,"setsDirectoryPath":"lanes with spaces"}"#.write(to: config, atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("npx")
        try #"""
        #!/bin/sh
        printf '%s\n' "$*" >> commands
        case "$*" in
          *"config --json"*) cat config.json; exit 0 ;;
          *--set=unknown*|*--target=unknown*) echo 'Invalid project selection' >&2; exit 17 ;;
        esac
        printf '%s\n' '{"schemaVersion":"2","revision":"1","segments":{},"features":{},"variables":{}}'
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(directory.path):\(oldPath)", 1)
        defer { setenv("PATH", oldPath, 1) }
        let log = directory.appendingPathComponent("commands")
        func run(_ command: String, _ flags: [String], _ status: Int32 = 0) throws -> [String] {
            try Data().write(to: log)
            XCTAssertEqual(CLI().run(args: [command, "--projectDirectoryPath=\(directory.path)", "--feature=checkout", "--n=1"] + flags), status)
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        for command in ["benchmark", "assess-distribution"] {
            XCTAssertEqual(try run(command, []), [
                "featurevisor config --json", "featurevisor build --set=admin --json", "featurevisor build --set=store front --json",
            ])
            XCTAssertEqual(try run(command, ["--set=store front"]), ["featurevisor config --json", "featurevisor build --set=store front --json"])
            let targets = ["--environment=production", "--target=nested.web", "--target=mobile", "--target=nested.web"]
            XCTAssertEqual(try run(command, targets), ["featurevisor config --json"] + ["admin", "store front"].flatMap { set in
                ["nested.web", "mobile"].map { "featurevisor build --environment=production --target=\($0) --set=\(set) --json" }
            })
            XCTAssertEqual(try run(command, targets + ["--set=store front"]), ["featurevisor config --json"] + ["nested.web", "mobile"].map {
                "featurevisor build --environment=production --target=\($0) --set=store front --json"
            })
            XCTAssertEqual(try run(command, ["--set=unknown"], 1), ["featurevisor config --json", "featurevisor build --set=unknown --json"])
            XCTAssertEqual(try run(command, ["--target=unknown", "--target=unreached"], 1), [
                "featurevisor config --json", "featurevisor build --target=unknown --set=admin --json",
            ])
        }
        for name in ["admin", "store front"] { try FileManager.default.removeItem(at: sets.appendingPathComponent(name)) }
        for command in ["benchmark", "assess-distribution"] {
            XCTAssertEqual(try run(command, [], 1), ["featurevisor config --json"])
        }
        try FileManager.default.removeItem(at: sets)
        for command in ["benchmark", "assess-distribution"] {
            XCTAssertEqual(try run(command, [], 1), ["featurevisor config --json"])
        }
        try "not JSON".write(to: config, atomically: true, encoding: .utf8)
        for command in ["benchmark", "assess-distribution"] {
            XCTAssertEqual(try run(command, [], 1), ["featurevisor config --json"])
        }
    }
}
