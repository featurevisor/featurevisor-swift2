import Foundation
import XCTest
@testable import Featurevisor

final class DependencyEdgeReuseTests: XCTestCase {
    private func input(_ schema: String) throws -> DatafileContent {
        var value = try DatafileContent.fromJSON(#"""
        {"schemaVersion":"4","revision":"one",
         "segments":{"s":{"conditions":"[{\"variable\":\"gate\",\"operator\":\"equals\",\"value\":true}]"}},
         "features":{"f":{"hash":"f","conditions":"s","traffic":[]},
                     "broken":{"hash":"broken","conditions":"[broken","traffic":[]}},
         "variables":{"gate":{"hash":"gate","type":"boolean","defaultValue":true},
                      "alias":{"hash":"alias","type":"boolean","compose":"gate"},
                      "broken":{"hash":"broken","type":"boolean","conditions":"[broken"},
                      "payload":{"hash":"payload","type":"object","defaultValue":{"conditions":{"variable":"fake"},"compose":"fake"}}}}
        """#)
        value.schemaVersion = schema
        return value
    }

    func testEqualIncomingEdgesStayReusableWhileIncomingCachesRestart() throws {
        for schema in ["2", "4"] {
            for replace in [false, true] {
                let raw = normalizeLegacyDatafile(try input(schema)).0
                let errors = ConcurrencyBox(0)
                let report: FeaturevisorDiagnosticHandler = { _ in errors.mutate { $0 += 1 } }
                let old = InstanceEvaluationDataProvider(datafile: raw, reportDiagnostic: report)
                _ = old.getFeature("broken")
                _ = old.getGlobalVariable("broken")
                _ = old.getSegment("s")
                let oldIndex = old.getDependencyIndex()
                var incoming = raw
                incoming.revision = "two"
                let next = InstanceEvaluationDataProvider(
                    datafile: incoming, reportDiagnostic: report, previous: old, incoming: incoming, replace: replace)
                let index = next.deriveDependencyIndex(previous: old)
                XCTAssertEqual(index.extractedEntities, 0)
                XCTAssertEqual(index.decodedConditions, 0)
                XCTAssertEqual(index.edges, oldIndex.edges)
                XCTAssertEqual(index.owners, oldIndex.owners)
                XCTAssertEqual(next.getCachedEntityCount(), 0)
                XCTAssertNil(index.edges[1][1]["fake"])
                for _ in 0..<2 {
                    _ = next.getFeature("broken")
                    _ = next.getGlobalVariable("broken")
                }
                XCTAssertEqual(errors.value, schema == "4" ? 4 : 0)
                XCTAssertEqual(old.getCachedEntityCount(), 3)
                XCTAssertEqual(next.getCachedEntityCount(), 2)
            }
        }
    }

    func testReplacementDropsRemovedCachesAndOwnersButMergeRetainsUnsentCaches() throws {
        for schema in ["2", "4"] {
            for replace in [false, true] {
                let raw = normalizeLegacyDatafile(try input(schema)).0
                let old = InstanceEvaluationDataProvider(datafile: raw, reportDiagnostic: { _ in })
                for key in raw.features.keys { _ = old.getFeature(key) }
                for key in raw.variables?.keys ?? [:].keys { _ = old.getGlobalVariable(key) }
                _ = old.getSegment("s")
                var incoming = raw
                incoming.features = [:]
                incoming.segments = [:]
                incoming.variables = ["gate": raw.variables!["gate"]!]
                var stored = replace ? incoming : raw
                stored.revision = "two"
                let next = InstanceEvaluationDataProvider(
                    datafile: stored, reportDiagnostic: { _ in }, previous: old, incoming: incoming, replace: replace)
                let index = next.deriveDependencyIndex(previous: old)
                let rebuilt = createDatafileDependencyIndex(stored)
                XCTAssertEqual(index.edges, rebuilt.edges)
                XCTAssertEqual(index.owners, rebuilt.owners)
                XCTAssertEqual(index.extractedEntities, 0)
                XCTAssertEqual(next.getCachedEntityCount(), replace ? 0 : 6)
                if replace {
                    XCTAssertNil(next.getFeature("broken"))
                    XCTAssertNil(next.getGlobalVariable("alias"))
                    XCTAssertNil(next.getSegment("s"))
                    XCTAssertEqual(next.getCachedEntityCount(), 0)
                    XCTAssertTrue(index.owners.isEmpty)
                }
            }
        }
    }

    func testSameHashChangedDefinitionsRefreshEdgesAndIgnorePayloadSelectors() throws {
        for schema in ["2", "4"] {
            for replace in [false, true] {
                let raw = normalizeLegacyDatafile(try input(schema)).0
                let old = InstanceEvaluationDataProvider(datafile: raw, reportDiagnostic: { _ in })
                var incoming = raw
                incoming.features["f"]?.conditions = .invalidToken("other")
                incoming.variables?["alias"]?.compose = .alias("other")
                incoming.variables?["payload"]?.defaultValue = .object(["conditions": .string("other")])
                incoming.segments["s"]?.conditions = .tree(.invalidToken("other"))
                let next = InstanceEvaluationDataProvider(
                    datafile: incoming, reportDiagnostic: { _ in }, previous: old, incoming: incoming, replace: replace)
                let index = next.deriveDependencyIndex(previous: old)
                let rebuilt = createDatafileDependencyIndex(incoming)
                XCTAssertEqual(index.extractedEntities, 4)
                XCTAssertEqual(index.edges, rebuilt.edges)
                XCTAssertEqual(index.owners, rebuilt.owners)
                XCTAssertNil(index.edges[1][1]["gate"])
                XCTAssertNil(index.edges[2][1]["other"])
                XCTAssertEqual(old.getDependencyIndex().edges[1][1]["gate"], ["alias"])
                XCTAssertEqual(raw.variables?["alias"]?.compose, .alias("gate"))
            }
        }
    }

    func testEachAcceptedLoadReportsMalformedSelectorsOnceAndAllowsReentry() throws {
        for schema in ["2", "4"] {
            for replace in [false, true] {
                let errors = ConcurrencyBox(0)
                let owner = ConcurrencyBox<Featurevisor?>(nil)
                let sdk = createFeaturevisor(FeaturevisorOptions(logLevel: .error, onDiagnostic: { item in
                    guard item.code == "conditions_parse_error" else { return }
                    errors.mutate { $0 += 1 }
                    _ = owner.value?.isEnabled("broken")
                    _ = owner.value?.getVariable("broken")
                }))
                owner.value = sdk
                var raw = try input(schema)
                for revision in 1...3 {
                    raw.revision = "\(revision)"
                    XCTAssertTrue(sdk.setDatafile(raw, replace: replace))
                    for _ in 0..<2 {
                        XCTAssertFalse(sdk.isEnabled("broken"))
                        XCTAssertNil(sdk.getVariable("broken"))
                    }
                    XCTAssertEqual(errors.value, revision * 2)
                }
                sdk.close()
                owner.value = nil
            }
        }
    }

    func testHashlessEqualDefinitionsStillNotifyOnBothUpdateModes() throws {
        for schema in ["2", "4"] {
            for replace in [false, true] {
                var raw = normalizeLegacyDatafile(try input(schema)).0
                raw.features["f"]?.hash = nil
                raw.variables?["gate"]?.hash = nil
                let old = InstanceEvaluationDataProvider(datafile: raw, reportDiagnostic: { _ in })
                let next = InstanceEvaluationDataProvider(
                    datafile: raw, reportDiagnostic: { _ in }, previous: old, incoming: raw, replace: replace)
                let event = getParamsForDatafileSetEvent(
                    previousInstanceEvaluationDataProvider: old, newInstanceEvaluationDataProvider: next, replace: replace)
                XCTAssertEqual(event["features"], .array([.string("f")]))
                XCTAssertEqual(event["variables"], .array([.string("alias"), .string("gate")]))
                XCTAssertEqual(next.getDependencyIndex().extractedEntities, 0)
            }
        }
    }

    func testMalformedSegmentEdgesCanBeReusedWithoutRetainingItsDiagnosticCache() throws {
        for replace in [false, true] {
            var raw = try input("4")
            raw.segments["s"]?.conditions = .string("[broken")
            let errors = ConcurrencyBox(0)
            let report: FeaturevisorDiagnosticHandler = { _ in errors.mutate { $0 += 1 } }
            let old = InstanceEvaluationDataProvider(datafile: raw, reportDiagnostic: report)
            _ = old.getSegment("s")
            let next = InstanceEvaluationDataProvider(
                datafile: raw, reportDiagnostic: report, previous: old, incoming: raw, replace: replace)
            XCTAssertEqual(next.deriveDependencyIndex(previous: old).extractedEntities, 0)
            XCTAssertEqual(errors.value, 1)
            XCTAssertEqual(next.getCachedEntityCount(), 0)
            for _ in 0..<2 { _ = next.getSegment("s") }
            XCTAssertEqual(errors.value, 2)
        }
    }
}
