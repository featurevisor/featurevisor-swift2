import XCTest
@testable import FeaturevisorCLI

final class FeaturevisorCLITests: XCTestCase {
    func testCLIParser() {
        let opts = CLIParser.parse([
            "test",
            "--keyPattern=foo",
            "--with-scopes",
            "--n=10",
            "--projectDirectoryPath=/tmp/project",
        ])

        XCTAssertEqual(opts.command, "test")
        XCTAssertEqual(opts.keyPattern, "foo")
        XCTAssertTrue(opts.withScopes)
        XCTAssertEqual(opts.n, 10)
        XCTAssertEqual(opts.projectDirectoryPath, "/tmp/project")
    }

    func testDefaultCommandShowsHelp() {
        let code = CLI().run(args: [])
        XCTAssertEqual(code, 0)
    }
}
