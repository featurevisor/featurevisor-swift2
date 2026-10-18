import Foundation
import XCTest
@testable import Featurevisor

final class LazyDependencyIndexTests: XCTestCase {
    private func datafile() throws -> DatafileContent {
        try DatafileContent.fromJSON(#"""
        {
          "schemaVersion":"4","revision":"initial",
          "segments":{"eligible":{"conditions":"[{\"variable\":\"gate\",\"operator\":\"equals\",\"value\":true}]"}},
          "features":{
            "dependent":{"hash":"dependent","bucketBy":"userId","conditions":"eligible","traffic":[{"key":"all","conditions":"*","percentage":100000}]}
          },
          "variables":{
            "gate":{"hash":"gate1","type":"boolean","defaultValue":true},
            "alias":{"hash":"alias","type":"boolean","compose":"gate"}
          }
        }
        """#)
    }

    func testInitialLoadDefersIndexesAndFirstUpdateStillFindsDependents() throws {
        let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
        let empty = InstanceEvaluationDataProvider(
            datafile: DatafileContent(schemaVersion: "4", revision: "empty", segments: [:], features: [:]),
            reportDiagnostic: { item in diagnostics.mutate { $0.append(item) } }
        )
        let initial = try datafile()
        let first = InstanceEvaluationDataProvider(
            datafile: initial, reportDiagnostic: { item in diagnostics.mutate { $0.append(item) } },
            previous: empty, incoming: initial, replace: true)
        let event = getParamsForDatafileSetEvent(previousInstanceEvaluationDataProvider: empty, newInstanceEvaluationDataProvider: first, replace: true)
        XCTAssertEqual(event["features"], .array([.string("dependent")]))
        XCTAssertEqual(event["variables"], .array([.string("alias"), .string("gate")]))
        XCTAssertEqual(empty.getCachedDependencyIndexCount(), 0)
        XCTAssertEqual(first.getCachedDependencyIndexCount(), 0)
        XCTAssertEqual(first.getCachedEntityCount(), 0)

        var updated = initial
        updated.revision = "updated"
        updated.variables?["gate"]?.hash = "gate2"
        updated.variables?["gate"]?.defaultValue = .bool(false)
        let next = InstanceEvaluationDataProvider(datafile: updated, reportDiagnostic: { item in diagnostics.mutate { $0.append(item) } })
        let changed = getParamsForDatafileSetEvent(previousInstanceEvaluationDataProvider: first, newInstanceEvaluationDataProvider: next, replace: false)
        XCTAssertEqual(changed["features"], .array([.string("dependent")]))
        XCTAssertEqual(changed["variables"], .array([.string("alias"), .string("gate")]))
        XCTAssertEqual(first.getCachedDependencyIndexCount(), 1)
        XCTAssertEqual(next.getCachedDependencyIndexCount(), 1)
        XCTAssertEqual(first.getCachedEntityCount(), 0)
        XCTAssertEqual(next.getCachedEntityCount(), 0)
        XCTAssertTrue(diagnostics.value.isEmpty)
        next.closeEntityCache()
        XCTAssertEqual(next.getCachedDependencyIndexCount(), 0)
    }

    func testSegmentOnlyPreviousStateDoesNotUseTheEmptyShortcut() throws {
        let initial = try datafile()
        let old = InstanceEvaluationDataProvider(
            datafile: DatafileContent(schemaVersion: "4", revision: "segments", segments: initial.segments, features: [:]),
            reportDiagnostic: { _ in }
        )
        let next = InstanceEvaluationDataProvider(datafile: initial, reportDiagnostic: { _ in })
        let event = getParamsForDatafileSetEvent(previousInstanceEvaluationDataProvider: old, newInstanceEvaluationDataProvider: next, replace: false)
        XCTAssertEqual(event["features"], .array([.string("dependent")]))
        XCTAssertEqual(old.getCachedDependencyIndexCount(), 1)
        XCTAssertEqual(next.getCachedDependencyIndexCount(), 1)
    }
}
