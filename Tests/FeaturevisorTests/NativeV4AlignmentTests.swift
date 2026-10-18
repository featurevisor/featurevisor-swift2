import Foundation
import XCTest
@testable import Featurevisor

final class NativeV4AlignmentTests: XCTestCase {
    private func datafile(_ schema: String = "4", segments: [String: Any] = [:], features: [String: Any] = [:], variables: [String: Any] = [:], revision: String = "native") throws -> DatafileContent {
        try DatafileContent.fromData(JSONSerialization.data(withJSONObject: [
            "schemaVersion": schema, "revision": revision, "segments": segments, "features": features, "variables": variables,
        ]))
    }

    private func feature(_ conditions: Any = "*") -> [String: Any] {
        ["bucketBy": "userId", "conditions": conditions, "traffic": [["key": "all", "conditions": "*", "percentage": 100000]]]
    }

    func testEagerAndLazyDiagnosticsReentryAndIncomingInvalidation() throws {
        for schema in ["2", "4"] {
            let errors = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
            let owner = ConcurrencyBox<Featurevisor?>(nil)
            let f = createFeaturevisor(FeaturevisorOptions(logLevel: .error, onDiagnostic: { item in
                guard item.code == "conditions_parse_error" else { return }
                errors.mutate { $0.append(item) }
                XCTAssertEqual(owner.value?.getRevision(), "broken")
                XCTAssertFalse(owner.value?.isEnabled("subject") ?? true)
            }))
            owner.mutate { $0 = f }
            defer { owner.mutate { $0 = nil }; f.close() }
            let input = try datafile(schema, features: ["subject": feature(" \n{\"or\":[oops]")], revision: "broken")
            let before = input
            XCTAssertTrue(f.setDatafile(input))
            XCTAssertEqual(errors.value.count, schema == "2" ? 1 : 0)
            XCTAssertFalse(f.isEnabled("subject"))
            XCTAssertEqual(errors.value.count, 1)
            XCTAssertEqual(errors.value[0].details, [
                "conditions": .string(" \n{\"or\":[oops]"), "entityType": .string("feature"), "entityKey": .string("subject"),
            ])
            XCTAssertEqual(input, before)
            XCTAssertTrue(f.setDatafile(try datafile(features: ["healthy": feature()], revision: "broken")))
            XCTAssertFalse(f.isEnabled("subject"))
            XCTAssertEqual(errors.value.count, 1)
            XCTAssertTrue(f.setDatafile(input))
            XCTAssertFalse(f.isEnabled("subject"))
            XCTAssertEqual(errors.value.count, 2)
            XCTAssertTrue(f.setDatafile(input, replace: true))
            XCTAssertFalse(f.isEnabled("subject"))
            XCTAssertEqual(errors.value.count, 3)
        }
    }

    func testMalformedSelectorsStayLocalThroughNotAndAliases() throws {
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(
            segments: ["broken": ["conditions": "{\"not\":["], "alias": ["conditions": "broken"]],
            features: [
                "subject": feature(["not": ["alias"]]), "healthy": feature(),
                "forced": ["conditions": "{", "force": [["conditions": "*", "enabled": true]]],
            ]
        ), logLevel: .fatal))
        defer { f.close() }
        XCTAssertEqual(f.evaluateFlag("subject").reason, .conditionsUnmet)
        XCTAssertFalse(f.isEnabled("subject"))
        XCTAssertTrue(f.isEnabled("healthy"))
        XCTAssertTrue(f.isEnabled("forced"))
    }

    func testLegacyEmptySemanticsAndMixedVersionMerges() throws {
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile("2",
            segments: ["empty": ["conditions": ["and": []]]],
            features: [
                "legacy": ["bucketBy": "userId", "force": [["conditions": [], "enabled": true]], "traffic": []],
                "root": feature([]),
                "mixed": ["conditions": [], "requiredFeatures": ["legacy"], "traffic": []],
                "segment": feature("empty"),
            ],
            variables: [
                "oldOverride": ["type": "string", "defaultValue": "default", "overrides": [["conditions": [], "value": "old"]]],
                "program": ["type": "string", "defaultValue": "default", "overrideProgram": [["key": "empty", "conditions": [], "operations": [["op": "set", "path": [], "value": "wrong"]], "onMatch": 1, "onMiss": 1]]],
            ]
        ), logLevel: .fatal))
        defer { f.close() }
        XCTAssertTrue(f.setDatafile(try datafile(features: ["fresh": feature([])])))
        XCTAssertTrue(f.isEnabled("legacy"))
        XCTAssertTrue(f.isEnabled("segment"))
        XCTAssertFalse(f.isEnabled("root"))
        XCTAssertFalse(f.isEnabled("mixed"))
        XCTAssertFalse(f.isEnabled("fresh"))
        XCTAssertEqual(f.getVariableString("oldOverride"), "old")
        XCTAssertEqual(f.getVariableString("program"), "default")
        XCTAssertTrue(f.setDatafile(try datafile("2", features: ["newLegacy": feature("*")])))
        XCTAssertFalse(f.isEnabled("fresh"))
        XCTAssertTrue(f.isEnabled("legacy"))
        XCTAssertTrue(f.setDatafile(try datafile("4", features: ["fresh": feature("*")]), replace: true))
        XCTAssertFalse(f.isEnabled("legacy"))
        XCTAssertTrue(f.isEnabled("fresh"))
    }

    func testIgnoredUnreleasedFieldsDoNotDecodeOrEvaluate() throws {
        XCTAssertThrowsError(try datafile(features: ["subject": feature(["feature": "available", "variable": "copy", "path": "not compiled", "operator": "notNull"])]))
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(
            features: ["subject": feature().merging(["required": ["missing"], "requiredVariables": "malformed ignored field"], uniquingKeysWith: { _, new in new })],
            variables: ["subject": ["type": "boolean", "defaultValue": true, "requiredVariables": ["invalid": true]]]
        ), logLevel: .fatal))
        defer { f.close() }
        XCTAssertTrue(f.isEnabled("subject"))
        XCTAssertEqual(f.getVariableBoolean("subject"), true)
    }

    func testEverySelectorPlacementReportsOnceAtTheCorrectTime() throws {
        let malformed = " {\"not\":["
        for schema in ["2", "4"] {
            for placement in 0..<10 {
                var subject = feature()
                var segments: [String: Any] = [:]
                var variables: [String: Any] = [:]
                var entityType = "feature"
                switch placement {
                case 0: subject["conditions"] = malformed
                case 1: subject["force"] = [["conditions": malformed, "enabled": true]]
                case 2: subject["traffic"] = [["key": "rule", "conditions": malformed, "percentage": 100000]]
                case 3: subject["traffic"] = [["key": "rule", "conditions": "*", "percentage": 100000, "variableOverrides": ["copy": [["conditions": malformed, "value": "wrong"]]]]]
                case 4: subject["variations"] = [["value": "treatment", "variableOverrides": ["copy": [["conditions": malformed, "value": "wrong"]]]]]
                case 5: subject["traffic"] = [["key": "rule", "segments": malformed, "percentage": 100000]]
                case 6:
                    entityType = "segment"
                    segments["subject"] = ["conditions": malformed]
                case 7:
                    entityType = "variable"
                    variables["subject"] = ["type": "string", "defaultValue": "safe", "conditions": malformed]
                case 8:
                    entityType = "variable"
                    variables["subject"] = ["type": "string", "defaultValue": "safe", "overrides": [["conditions": malformed, "value": "wrong"]]]
                default:
                    entityType = "variable"
                    variables["subject"] = ["type": "string", "defaultValue": "safe", "overrideProgram": [["key": "nested", "keyPath": ["parent", "child"], "conditions": malformed, "operations": [], "onMatch": 1, "onMiss": 1]]]
                }
                let errors = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
                let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(schema, segments: segments, features: ["subject": subject], variables: variables), logLevel: .error, onDiagnostic: { item in
                    if item.code == "conditions_parse_error" { errors.mutate { $0.append(item) } }
                }))
                defer { f.close() }
                XCTAssertEqual(errors.value.count, schema == "2" ? 1 : 0, "\(schema) placement \(placement)")
                for _ in 0..<2 {
                    if entityType == "feature" { _ = f.getFeature("subject") }
                    else if entityType == "segment" { _ = f.getSegment("subject") }
                    else { _ = f.evaluateVariable("subject") }
                }
                XCTAssertEqual(errors.value.count, 1, "\(schema) placement \(placement)")
                XCTAssertEqual(errors.value.first?.details, ["conditions": .string(malformed), "entityType": .string(entityType), "entityKey": .string("subject")])
            }
        }
    }

    func testNormalizedPublicConditionsFlattenWithoutDroppingEmptyParts() throws {
        var mixed = feature([])
        mixed["requiredFeatures"] = ["missing"]
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(features: ["subject": mixed, "broken": feature("{")]), logLevel: .fatal))
        defer { f.close() }
        let evaluation = f.evaluateFlag("subject")
        XCTAssertEqual(evaluation.reason, .conditionsUnmet)
        XCTAssertEqual(evaluation.conditions, .list([.and([]), .feature(FeatureCondition(feature: "missing"))]))
        let wire = try JSONDecoder().decode([String: AnyValue].self, from: JSONEncoder().encode(f.evaluateFlag("broken")))
        XCTAssertEqual(wire["conditions"], .object(["or": .array([])]))
        XCTAssertEqual(wire["reason"], .string("conditions_unmet"))
    }

    func testExact256HandoffBoundForEveryEntityKindAndValueCopies() throws {
        var segments: [String: Any] = [:]
        var features: [String: Any] = [:]
        var variables: [String: Any] = [:]
        for index in 0...256 {
            features["f\(index)"] = feature(index == 256 ? "*" : ["feature": "f\(index + 1)"])
            variables["v\(index)"] = index == 256 ? ["type": "integer", "defaultValue": 1] : ["type": "integer", "compose": "v\(index + 1)"]
            if index < 256 { segments["s\(index)"] = ["conditions": index == 255 ? "*" : "s\(index + 1)"] }
        }
        features["segment"] = feature("s0")
        segments["overflow"] = ["conditions": "s0"]
        features["segmentOverflow"] = feature("overflow")
        features["featureOverflow"] = feature(["feature": "f0"])
        variables["overflow"] = ["type": "integer", "compose": "v0"]
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(segments: segments, features: features, variables: variables), logLevel: .fatal))
        defer { f.close() }
        XCTAssertTrue(f.isEnabled("f0"))
        XCTAssertEqual(f.getVariable("v0"), .int(1))
        XCTAssertTrue(f.isEnabled("segment"))
        for key in ["segmentOverflow", "featureOverflow"] { XCTAssertEqual(f.evaluateFlag(key).reason, .error, key) }
        XCTAssertEqual(f.evaluateVariable("overflow").reason, .error)
        let first = f.evaluateFlag("f256")
        var second = first
        second.enabled = false
        second.reason = .disabled
        XCTAssertEqual(first.enabled, true)
        XCTAssertEqual(first.reason, .rule)
        XCTAssertEqual(second.enabled, false)
        XCTAssertEqual(f.getVariable("v0"), .int(1))
    }

    private func chain(_ length: Int) throws -> DatafileContent {
        var features: [String: Any] = [:]
        for index in 0..<length {
            features["f\(index)"] = feature(index == 0 ? "*" : ["feature": "f\(index - 1)"])
        }
        return try datafile(features: features)
    }

    /// Runs on a 512 KB thread, the size of Dispatch and Swift concurrency workers.
    private func onSmallStack<T>(_ body: @escaping () -> T) -> T {
        let result = ConcurrencyBox<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.mutate { $0 = body() }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        return result.value!
    }

    func testSmallThreadStacksFailDeepChainsWithoutCrashing() throws {
        let errors = ConcurrencyBox<[String]>([])
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try chain(300), logLevel: .error, onDiagnostic: { item in
            if item.level == .error { errors.mutate { $0.append(item.code) } }
        }))
        defer { f.close() }
        XCTAssertTrue(onSmallStack { f.isEnabled("f16") })
        XCTAssertEqual(errors.value, [])
        for key in ["f40", "f256", "f299"] {
            XCTAssertEqual(onSmallStack { f.evaluateFlag(key).reason }, .error, key)
        }
        XCTAssertEqual(errors.value, ["evaluation_error", "evaluation_error", "evaluation_error"])
        XCTAssertTrue(f.isEnabled("f256"))
        XCTAssertNotNil(StackGuard.remaining())
    }

    func testDependencyFailuresReportOnePublicError() throws {
        let errors = ConcurrencyBox<[String]>([])
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try chain(300), logLevel: .error, onDiagnostic: { item in
            if item.level == .error { errors.mutate { $0.append(item.code) } }
        }))
        defer { f.close() }
        XCTAssertFalse(f.isEnabled("f299"))
        XCTAssertNil(f.getVariation("f299"))
        XCTAssertEqual(errors.value, ["evaluation_error", "evaluation_error"])
    }

    func testCompositionUsesModulesChildStateAndPurposeSeparatedMemo() throws {
        let calls = ConcurrencyBox<[(String, String?, DependencyOf?)]>([])
        let module = FeaturevisorModule(name: "observe", beforeEvaluation: { options in
            calls.mutate { $0.append((options.variableKey ?? options.featureKey, options.dependencyPurpose, options.dependencyOf)) }
            var updated = options
            if options.variableKey == "source" { updated.dependencies.context["country"] = .string("nl") }
            return updated
        }, afterEvaluation: { evaluation, options in
            var result = evaluation
            if options.variableKey == "source", options.dependencies.context["country"] == .string("nl"),
               result.reason != .sticky { result.variableValue = .object(["count": .int(7)]) }
            return result
        })
        let input = try datafile(variables: [
            "source": ["type": "object", "defaultValue": ["count": 1]],
            "map": ["type": "object", "conditions": ["variable": "source", "operator": "notNull"],
                    "compose": [["key": "a", "variable": "source"], ["key": "b", "variable": "source"]],
                    "overrideProgram": [["key": "change", "conditions": "*", "operations": [["op": "set", "path": ["a", "count"], "value": 9]], "onMatch": 1, "onMiss": 1]]],
            "alias": ["type": "object", "compose": "map"],
        ])
        let before = input
        let f = createFeaturevisor(FeaturevisorOptions(datafile: input, logLevel: .fatal, modules: [module]))
        defer { f.close() }
        let child = f.spawn(["country": .string("de")], options: SpawnOptions(stickyVariables: ["source": .object(["count": .int(3)])]))
        defer { child.close() }
        XCTAssertEqual(child.getVariable("map"), .object(["a": .object(["count": .int(9)]), "b": .object(["count": .int(3)])]))
        let sourceCalls = calls.value.filter { $0.0 == "source" }
        XCTAssertEqual(sourceCalls.map { $0.1 }, ["condition", "composition"])
        XCTAssertTrue(sourceCalls.allSatisfy { $0.2 == DependencyOf(type: .variable, variableKey: "map") })
        XCTAssertNil(calls.value[0].1)
        XCTAssertNil(calls.value[0].2)
        XCTAssertEqual(child.getVariable("source"), .object(["count": .int(3)]))
        XCTAssertEqual(f.getVariable("map"), .object(["a": .object(["count": .int(9)]), "b": .object(["count": .int(7)])]))
        XCTAssertEqual(input, before)
    }

    func testComposedGatesSkipSourcesAndWholeStickyBypassesGate() throws {
        let calls = ConcurrencyBox<[String]>([])
        let module = FeaturevisorModule(name: "observe", beforeEvaluation: { options in
            calls.mutate { $0.append(options.variableKey ?? "") }
            return options
        })
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables: [
            "source": ["type": "integer", "defaultValue": 5],
            "alias": ["type": "integer", "compose": "source", "conditions": [], "disabledValue": 0],
            "map": ["type": "object", "compose": [["key": "source", "variable": "source"]], "conditions": []],
        ]), logLevel: .fatal, modules: [module]))
        defer { f.close() }
        XCTAssertEqual(f.getVariable("alias"), .int(0))
        XCTAssertNil(f.getVariable("map"))
        XCTAssertFalse(calls.value.contains("source"))
        f.setStickyVariables(["alias": .int(8)])
        XCTAssertEqual(f.getVariable("alias"), .int(8))
        XCTAssertFalse(calls.value.contains("source"))
    }

    func testLaterCompositionMembersObserveDatafileAndStickyChanges() throws {
        for sticky in [false, true] {
            let owner = ConcurrencyBox<Featurevisor?>(nil)
            let reads = ConcurrencyBox(0)
            let next = try datafile(variables: ["source": ["type": "integer", "defaultValue": 2]], revision: "two")
            let module = FeaturevisorModule(name: "replace-source", afterEvaluation: { evaluation, options in
                guard options.variableKey == "source" else { return evaluation }
                reads.mutate { $0 += 1 }
                if reads.value == 1 {
                    if sticky { owner.value?.setStickyVariables(["source": .int(2)]) }
                    else { XCTAssertTrue(owner.value?.setDatafile(next) ?? false) }
                }
                return evaluation
            })
            let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables: [
                "source": ["type": "integer", "defaultValue": 1],
                "map": ["type": "object", "compose": [["key": "a", "variable": "source"], ["key": "b", "variable": "source"]]],
            ]), logLevel: .fatal, modules: [module]))
            owner.value = f
            defer { owner.value = nil; f.close() }
            XCTAssertEqual(f.getVariable("map"), .object(["a": .int(1), "b": .int(2)]))
            XCTAssertEqual(reads.value, 2)
            XCTAssertEqual(f.getVariable("map"), .object(["a": .int(2), "b": .int(2)]))
        }
    }

    func testStickyJSONSourcesDecodeOnceAndWholeComposedStickyStaysEvaluated() throws {
        let input = try datafile(features: ["checkout": ["bucketBy": "userId", "variablesSchema": ["raw": ["type": "json", "defaultValue": "null"]], "traffic": []]], variables: [
            "raw": ["type": "json", "defaultValue": "null"],
            "alias": ["type": "json", "compose": "raw"],
            "chain": ["type": "json", "compose": "alias"],
            "map": ["type": "object", "compose": [["key": "raw", "feature": "checkout", "variable": "raw"]]],
        ])
        XCTAssertNil(input.variables?["alias"]?.defaultValue)
        let f = createFeaturevisor(FeaturevisorOptions(datafile: input, logLevel: .fatal,
            stickyFeatures: ["checkout": EvaluatedFeature(enabled: true, variables: ["raw": .string("\"null\"")])],
            stickyVariables: ["raw": .string("\"null\"")]
        ))
        defer { f.close() }
        XCTAssertEqual(f.getVariable("raw"), .string("null"))
        XCTAssertEqual(f.getVariable("chain"), .string("null"))
        XCTAssertEqual(f.getVariable("map"), .object(["raw": .string("null")]))
        f.setStickyVariables(["alias": .string("null")])
        XCTAssertEqual(f.getVariable("alias"), .string("null"))
        XCTAssertEqual(f.getVariable("chain"), .string("null"))
    }

    func testOrdinarySourceErrorsCompleteWithNullRatherThanFailingComposition() throws {
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables: [
            "badComposition": ["type": "object", "compose": [["key": "constructor", "variable": "source"]]],
            "badProgram": ["type": "integer", "defaultValue": 0, "overrideProgram": [["key": "bad", "conditions": "*", "operations": [], "onMatch": 0, "onMiss": 0]]],
            "source": ["type": "integer", "defaultValue": 3],
            "map": ["type": "object", "compose": [["key": "badComposition", "variable": "badComposition"], ["key": "badProgram", "variable": "badProgram"], ["key": "source", "variable": "source"]]],
        ]), logLevel: .fatal))
        defer { f.close() }
        XCTAssertEqual(f.evaluateVariable("badComposition").reason, .error)
        XCTAssertEqual(f.getVariable("map"), .object(["badComposition": .null, "badProgram": .null, "source": .int(3)]))
        XCTAssertEqual(f.evaluateVariable("map").reason, .variableComposed)
    }

    func testCombinedDepthBoundAndCleanup() throws {
        var segments: [String: Any] = [:]
        var variables: [String: Any] = [:]
        for index in 0..<130 {
            segments["s\(index)"] = ["conditions": index == 129 ? ["variable": "v0", "operator": "notNull"] : "s\(index + 1)"]
            variables["v\(index)"] = index == 129 ? ["type": "integer", "defaultValue": 1] : ["type": "integer", "compose": "v\(index + 1)"]
        }
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(
            segments: segments, features: ["subject": feature("s0"), "healthy": feature()], variables: variables
        ), logLevel: .fatal))
        defer { f.close() }
        for _ in 0..<2 {
            XCTAssertEqual(f.evaluateFlag("subject").reason, .error)
            XCTAssertEqual(f.getVariable("v0"), .int(1))
            XCTAssertTrue(f.isEnabled("healthy"))
        }
    }

    func testMixedDependencyEventsTraverseAllKindsAndDoNotWarmCaches() throws {
        let errors = ConcurrencyBox<[String]>([])
        let events = ConcurrencyBox<[EventPayload]>([])
        let initial = try datafile(
            segments: ["s": ["conditions": "{\"variable\":\"source\",\"operator\":\"notNull\"}"]],
            features: ["gate": feature("s").merging(["hash": "gate"], uniquingKeysWith: { _, new in new })],
            variables: [
                "source": ["type": "integer", "defaultValue": 1, "hash": "one"],
                "view": ["type": "object", "compose": [["key": "gate", "feature": "gate"]], "hash": "view"],
                "broken": ["type": "string", "defaultValue": "safe", "conditions": "{", "hash": "broken"],
            ]
        )
        let f = createFeaturevisor(FeaturevisorOptions(datafile: initial, logLevel: .error, onDiagnostic: { item in
            if item.code == "conditions_parse_error" { errors.mutate { $0.append(item.code) } }
        }))
        defer { f.close() }
        _ = f.on(.datafileSet) { payload in events.mutate { $0.append(payload) } }
        XCTAssertTrue(errors.value.isEmpty)
        XCTAssertTrue(f.setDatafile(try datafile(variables: ["source": ["type": "integer", "defaultValue": 2, "hash": "two"]])))
        XCTAssertEqual(events.value.last?.params["features"], .array([.string("gate")]))
        XCTAssertEqual(events.value.last?.params["variables"], .array([.string("source"), .string("view")]))
        XCTAssertTrue(errors.value.isEmpty)
        XCTAssertNil(f.getVariable("broken"))
        XCTAssertEqual(errors.value.count, 1)
        XCTAssertTrue(f.setDatafile(try datafile(features: ["other": feature()])))
        XCTAssertNil(f.getVariable("broken"))
        XCTAssertEqual(errors.value.count, 1)
    }
}
