import XCTest
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

    func testTargetDatafileCacheKey() {
        let command = TestCommand()

        XCTAssertEqual(command.targetDatafileCacheKey(nil, "checkout"), "false-target-checkout")
        XCTAssertEqual(command.targetDatafileCacheKey("production", "checkout"), "production-target-checkout")
    }

    func testDefaultCommandShowsHelp() {
        let code = CLI().run(args: [])
        XCTAssertEqual(code, 0)
    }
}
