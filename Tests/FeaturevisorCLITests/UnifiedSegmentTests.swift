import Foundation
import XCTest
import Featurevisor
@testable import FeaturevisorCLI

final class UnifiedSegmentTests: XCTestCase {
    private func datafile(_ raw: [String: Any] = [:]) throws -> DatafileContent {
        var value: [String: Any] = ["schemaVersion": "4", "revision": "segments", "features": [:], "segments": [:], "variables": [:]]
        value.merge(raw, uniquingKeysWith: { _, new in new })
        return try DatafileContent.fromData(JSONSerialization.data(withJSONObject: value))
    }

    func testDependentOwnerAndChildChecksUseSDKState() throws {
        let definitions: [String: Any] = [
            "eligible": ["conditions": ["and": [
                ["feature": "checkout"],
                ["variable": "policy", "path": ["items", 0, "enabled"], "operator": "equals", "value": true],
            ]]],
        ]
        let selected = try datafile([
            "features": ["checkout": ["bucketBy": "userId", "traffic": [["key": "all", "conditions": "*", "percentage": 50000]]]],
            "variables": ["policy": ["type": "object", "defaultValue": ["items": [["enabled": false]]]]],
        ])
        let command = TestCommand()
        let assertion: [String: Any] = [
            "environment": "production", "at": 20, "context": ["country": "nl"],
            "stickyVariables": ["policy": ["items": [["enabled": true]]]],
            "expectedToMatch": true,
            "children": [["stickyFeatures": ["checkout": ["enabled": false]], "expectedToMatch": false]],
        ]
        let result = command.runSegmentTest(segmentKey: "eligible", test: ["_segments": definitions, "assertions": [assertion]], segmentsByKey: [:], options: CLIOptions(), datafileCache: [command.datafileCacheKey("production"): selected])
        XCTAssertTrue(result.ok, "\(result.reports)")
        let missed = command.runSegmentTest(segmentKey: "eligible", test: ["_segments": definitions, "assertions": [["expectedToMatch": false]]], segmentsByKey: [:], options: CLIOptions())
        XCTAssertFalse(missed.ok)
    }

    func testAttributeOnlyChainsWithoutEnvironmentAndMissingTarget() throws {
        let command = TestCommand()
        let definitions: [String: Any] = [
            "dutch": ["conditions": ["attribute": "country", "operator": "equals", "value": "nl"]],
            "eligible": ["conditions": "dutch"],
        ]
        let test: [String: Any] = ["_segments": definitions, "assertions": [["context": ["country": "nl"], "expectedToMatch": true]]]
        XCTAssertTrue(command.runSegmentTest(segmentKey: "eligible", test: test, segmentsByKey: [:], options: CLIOptions()).ok)
        let targeted: [String: Any] = ["_segments": definitions, "assertions": [["target": "missing", "expectedToMatch": false]]]
        XCTAssertFalse(command.runSegmentTest(segmentKey: "eligible", test: targeted, segmentsByKey: [:], options: CLIOptions()).ok)
        var options = CLIOptions()
        options.targets = ["web"]
        let filtered: [String: Any] = ["_segments": definitions, "assertions": [
            ["target": "web", "context": ["country": "nl"], "expectedToMatch": true],
            ["target": "mobile", "context": ["country": "nl"], "expectedToMatch": false],
        ]]
        let result = command.runSegmentTest(segmentKey: "eligible", test: filtered, segmentsByKey: [:], options: options, datafileCache: [command.targetDatafileCacheKey(nil, "web"): try datafile()])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.passed, 1)
        options.quiet = true
        options.targets = []
        let cyclic: [String: Any] = ["_segments": ["cycle": ["conditions": ["not": ["cycle"]]]], "assertions": [["expectedToMatch": false]]]
        XCTAssertFalse(command.runSegmentTest(segmentKey: "cycle", test: cyclic, segmentsByKey: [:], options: options).ok)
    }

    func testSelectedTargetSpecializationWinsAndSyntheticGatesDoNotCover() throws {
        let selected = try datafile([
            "segments": ["eligible": ["conditions": "*"]],
            "features": ["__featurevisor_segment_test__eligible": ["traffic": [], "bucketBy": "userId"]],
        ])
        let definitions: [String: Any] = ["eligible": ["conditions": ["attribute": "country", "operator": "equals", "value": "nl"]]]
        var options = CLIOptions()
        let coverage = TestCoverageCollector()
        options.coverageSink = coverage
        let built = TestCommand().sdkForAssertion(datafile: selected, assertion: [:], options: options, segmentDefinitions: definitions)
        defer { built.sdk.close() }
        XCTAssertEqual(built.segmentGates["eligible"], "__featurevisor_segment_test__eligible_")
        let resolver = NativeCheckResolver(built.sdk, diagnostics: built.diagnostics, segmentDefinitions: definitions, segmentGates: built.segmentGates)
        XCTAssertTrue(try resolver.checkSegment("eligible"))
        XCTAssertTrue(coverage.selections().isEmpty)
    }

    func testTransitivePreflightVisitsSkippedBranchesAndComposeWithoutGetters() throws {
        let reads = CheckDiagnosticCollector()
        let datafile = try datafile([
            "variables": ["alias": ["type": "object", "compose": [["key": "missing", "feature": "absent"]]]],
        ])
        let definitions: [String: Any] = [
            "root": ["conditions": ["or": ["all", ["variable": "alias", "operator": "notNull"]]]],
            "all": ["conditions": "*"],
        ]
        XCTAssertThrowsError(try preflightExpandedAssertionChecks(
            ["checks": [["or": [["segment": "all", "matches": true], ["segment": "root", "matches": false]]]]],
            ownerVariable: nil, datafile: datafile, segmentDefinitions: definitions
        ))
        XCTAssertNil(reads.take())
        XCTAssertThrowsError(try preflightExpandedAssertionChecks(
            ["children": [["checks": [["segment": "root", "matches": false]]]]],
            ownerVariable: nil, datafile: datafile, segmentDefinitions: definitions
        ))
    }

    func testCheckUsesChildContextStickyAndCompiledPaths() throws {
        let selected = try datafile(["variables": ["policy": ["type": "object", "defaultValue": ["items": [["enabled": false]]]]]])
        let definitions: [String: Any] = ["eligible": ["conditions": [
            ["attribute": "country", "operator": "equals", "value": "nl"],
            ["variable": "policy", "path": ["items", 0, "enabled"], "operator": "equals", "value": true],
        ]]]
        let built = TestCommand().sdkForAssertion(datafile: selected, assertion: [:], options: CLIOptions(), segmentDefinitions: definitions)
        defer { built.sdk.close() }
        let child = built.sdk.spawn(["country": .string("nl")], options: SpawnOptions(stickyVariables: ["policy": .object(["items": .array([.object(["enabled": .bool(true)])])])]))
        defer { child.close() }
        let resolver = NativeCheckResolver(child, diagnostics: built.diagnostics, segmentDefinitions: definitions, segmentGates: built.segmentGates)
        XCTAssertTrue(try resolver.checkSegment("eligible"))
        XCTAssertEqual(built.sdk.getVariable("policy"), .object(["items": .array([.object(["enabled": .bool(false)])])]))
    }
}
