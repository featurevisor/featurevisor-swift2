import XCTest
import Featurevisor
@testable import FeaturevisorCLI

final class FeaturevisorCLITests: XCTestCase {
    func testCLIParser() {
        let opts = CLIParser.parse([
            "test",
            "--keyPattern=foo",
            "--with-scopes",
            "--with-tags",
            "--schemaVersion=1",
            "--schema-version=2",
            "--n=10",
            "--projectDirectoryPath=/tmp/project",
        ])

        XCTAssertEqual(opts.command, "test")
        XCTAssertEqual(opts.keyPattern, "foo")
        XCTAssertTrue(opts.withScopes)
        XCTAssertTrue(opts.withTags)
        XCTAssertEqual(opts.schemaVersion, "2")
        XCTAssertEqual(opts.n, 10)
        XCTAssertEqual(opts.projectDirectoryPath, "/tmp/project")
    }

    func testRepeatedTargets() {
        let opts = CLIParser.parse(["benchmark", "--target=web", "--target=mobile", "--target=web"])
        XCTAssertEqual(opts.targets, ["web", "mobile"])
    }

    func testTargetDatafileCacheKey() {
        let command = TestCommand()

        XCTAssertEqual(command.targetDatafileCacheKey(nil, "checkout"), "false-target-checkout")
        XCTAssertEqual(command.targetDatafileCacheKey("production", "checkout"), "production-target-checkout")
    }

    func testTargetAssertionSelectsTargetDatafile() {
        let command = TestCommand()
        let cache = [
            "production": DatafileContent(schemaVersion: "2", revision: "base", segments: [:], features: [:]),
            "production-target-checkout": DatafileContent(schemaVersion: "2", revision: "target", segments: [:], features: [:]),
        ]

        XCTAssertEqual(
            command.datafileCacheKeyForAssertion(
                ["environment": "production", "target": "checkout"],
                datafileCache: cache
            ),
            "production-target-checkout"
        )
    }

    func testTargetAssertionDoesNotFallBackToBaseDatafile() {
        let command = TestCommand()
        let cache = [
            "production": DatafileContent(schemaVersion: "2", revision: "base", segments: [:], features: [:]),
        ]

        XCTAssertEqual(
            command.datafileCacheKeyForAssertion(
                ["environment": "production", "target": "checkout"],
                datafileCache: cache
            ),
            "production-target-checkout"
        )
    }

    func testNoEnvironmentTargetAssertionSelectsTargetDatafile() {
        let command = TestCommand()
        let cache = [
            CLIHelpers.noEnvironmentKey: DatafileContent(schemaVersion: "2", revision: "base", segments: [:], features: [:]),
            "false-target-checkout": DatafileContent(schemaVersion: "2", revision: "target", segments: [:], features: [:]),
        ]

        XCTAssertEqual(
            command.datafileCacheKeyForAssertion(
                ["target": "checkout"],
                datafileCache: cache
            ),
            "false-target-checkout"
        )
    }

    func testDefaultCommandShowsHelp() {
        let code = CLI().run(args: [])
        XCTAssertEqual(code, 0)
    }
}
