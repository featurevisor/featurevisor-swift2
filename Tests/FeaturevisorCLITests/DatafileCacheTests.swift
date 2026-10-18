import Foundation
import Featurevisor
import XCTest
@testable import FeaturevisorCLI

final class DatafileCacheTests: XCTestCase {
    func testKeysRoundTripAndSelectWithoutCollisions() throws {
        let command = TestCommand()
        let values: [String?] = [nil, "", "false", "__no_environment__", "prod", "prod-target-web", "web", "web-target-mobile", "mobile", "東京\"\\🦀"]
        var cache: [String: DatafileContent] = [:]
        for environment in values {
            for target in values {
                let key = target.map { command.targetDatafileCacheKey(environment, $0) } ?? command.datafileCacheKey(environment)
                let decoded = try JSONDecoder().decode([String?].self, from: Data(key.utf8))
                XCTAssertEqual(decoded, [environment, target])
                XCTAssertNil(cache[key], "Colliding selection: \(key)")
                cache[key] = DatafileContent(schemaVersion: "2", revision: "\(cache.count)", segments: [:], features: [:])
            }
        }
        XCTAssertEqual(cache.count, 100)
        for environment in values {
            for target in values {
                let key = target.map { command.targetDatafileCacheKey(environment, $0) } ?? command.datafileCacheKey(environment)
                var assertion: [String: Any] = [:]
                if let environment { assertion["environment"] = environment }
                if let target { assertion["target"] = target }
                let selected = command.datafileCacheKeyForAssertion(assertion, datafileCache: cache)
                XCTAssertEqual(cache[selected]?.revision, cache[key]?.revision)
            }
        }
        for environment: Any in [NSNull(), false] {
            for target: Any in [NSNull(), false] {
                XCTAssertEqual(command.datafileCacheKeyForAssertion(["environment": environment, "target": target], datafileCache: cache), command.datafileCacheKey(nil))
            }
            XCTAssertEqual(command.datafileCacheKeyForAssertion(["environment": environment, "target": "web"], datafileCache: cache), command.targetDatafileCacheKey(nil, "web"))
        }
    }

    func testCacheBuilderKeepsBaseAndTargetSelectionsDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swift-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(directory.path):\(oldPath)", 1)
        defer { setenv("PATH", oldPath, 1) }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let command = TestCommand()
        let targets = ["web", "web-target-mobile", "mobile", "東京\"\\🦀"]
        for flat in [false, true] {
            let environments: [String?] = flat ? [nil] : ["prod", "prod-target-web", "false", "false-target-web", "__no_environment__", "東京\"\\🦀"]
            var script = #"""
            #!/bin/sh
            case "$2" in list) printf '%s\n' '[]'; exit ;; esac
            environment=__absent__
            target=__absent__
            for arg do
              case "$arg" in
                --environment=*) environment=${arg#*=} ;;
                --target=*) target=${arg#*=} ;;
              esac
            done

            """#
            var expected: [String: String] = [:]
            for environment in environments {
                for target in [nil] + targets.map(Optional.some) {
                    let marker = "selection-\(expected.count)"
                    let key = target.map { command.targetDatafileCacheKey(environment, $0) } ?? command.datafileCacheKey(environment)
                    expected[key] = marker
                    let datafile: [String: Any] = ["schemaVersion": "2", "revision": marker, "segments": [:], "features": [:]]
                    try JSONSerialization.data(withJSONObject: datafile).write(to: directory.appendingPathComponent("\(marker).json"))
                    script += "if [ \"$environment\" = \(quote(environment ?? "__absent__")) ] && [ \"$target\" = \(quote(target ?? "__absent__")) ]; then cat \(marker).json; exit; fi\n"
                }
            }
            script += "exit 19\n"
            let npx = directory.appendingPathComponent("npx")
            try script.write(to: npx, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npx.path)
            var options = CLIOptions()
            options.projectDirectoryPath = directory.path
            options.targets = targets
            let config: [String: Any] = flat ? [:] : ["environments": environments.compactMap { $0 }]
            let cache = command.buildDatafileCache(options: options, config: config)
            XCTAssertEqual(cache.count, expected.count)
            for (key, revision) in expected { XCTAssertEqual(cache[key]?.revision, revision, key) }
        }
    }
}
