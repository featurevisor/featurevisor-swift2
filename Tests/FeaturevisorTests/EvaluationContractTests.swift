import Foundation
import XCTest
@testable import Featurevisor

final class EvaluationContractTests: XCTestCase {
    private func datafile(_ features: [String: Any], variables: [String: Any] = [:]) throws -> DatafileContent {
        try DatafileContent.fromData(JSONSerialization.data(withJSONObject: [
            "schemaVersion": "4", "revision": "evaluation-contract", "segments": [:],
            "features": features, "variables": variables,
        ]))
    }

    func testEmptyListsAndNullOperandsHaveOrdinaryBooleanSemantics() throws {
        XCTAssertFalse(allConditionsAreMatched(.list([]), context: [:]))
        XCTAssertTrue(allConditionsAreMatched(.not([.null]), context: [:]))
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile([
            "empty": ["conditions": [], "traffic": [["key": "all", "conditions": "*", "percentage": 100000]]],
            "notNull": ["conditions": ["not": [NSNull()]], "traffic": [["key": "all", "conditions": "*", "percentage": 100000]]],
        ]), logLevel: .fatal))
        defer { f.close() }
        XCTAssertFalse(f.isEnabled("empty"))
        XCTAssertTrue(f.isEnabled("notNull"))
    }

    func testExplicitNullRootConditionsAreNotAbsent() throws {
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile([
            "subject": ["conditions": NSNull(), "traffic": [["key": "all", "conditions": "*", "percentage": 100000]]],
        ], variables: ["subject": ["type": "string", "defaultValue": "wrong", "disabledValue": "blocked", "conditions": NSNull()]]), logLevel: .fatal))
        defer { f.close() }
        XCTAssertEqual(f.evaluateFlag("subject").reason, .conditionsUnmet)
        XCTAssertEqual(f.evaluateVariable("subject").reason, .conditionsUnmet)
        XCTAssertEqual(f.getVariable("subject"), .string("blocked"))
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.evaluateFlag("subject"))) as? [String: Any]
        XCTAssertTrue(wire?["conditions"] is NSNull)
    }

    func testMissedCompositionGateDoesNotUseCallerOrModuleDefaults() throws {
        let reads = ConcurrencyBox(0)
        let module = FeaturevisorModule(name: "default", beforeEvaluation: { options in
            if options.dependencyPurpose == "composition" { reads.mutate { $0 += 1 } }
            var updated = options
            updated.dependencies.defaultVariableValue = .string("module-default")
            return updated
        })
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile([:], variables: [
            "source": ["type": "string", "defaultValue": "source"],
            "alias": ["type": "string", "compose": "source", "conditions": []],
            "map": ["type": "object", "compose": [["key": "source", "variable": "source"]], "conditions": []],
        ]), logLevel: .fatal, modules: [module]))
        defer { f.close() }
        let defaults = OverrideOptions(defaultVariableValue: .string("caller-default"))
        for key in ["alias", "map"] {
            XCTAssertNil(f.getVariable(key, [:], defaults))
            let evaluation = f.evaluateVariable(key, options: defaults)
            XCTAssertEqual(evaluation.reason, .conditionsUnmet)
            XCTAssertNil(evaluation.variableValue)
        }
        XCTAssertEqual(f.getVariable("missing", [:], defaults), .string("module-default"))
        XCTAssertEqual(reads.value, 0)
    }

    func testInternalFlagGateRetainsOuterRequesterIncludingCompositionSources() throws {
        for kind in [EvaluationType.variation, .variable] {
            for composed in [false, true] {
                let expected = DependencyOf(type: kind, featureKey: "subject", variableKey: kind == .variable ? "value" : nil)
                let seen = ConcurrencyBox<[DependencyOf?]>([])
                let module = FeaturevisorModule(name: "requester", beforeEvaluation: { options in
                    if options.featureKey == "healthy" {
                        seen.mutate { $0.append(options.dependencyOf) }
                        XCTAssertEqual(options.dependencyPurpose, "condition")
                    }
                    return options
                }, afterEvaluation: { evaluation, options in
                    var result = evaluation
                    if options.featureKey == "healthy" { result.enabled = options.dependencyOf == expected }
                    return result
                })
                let source: [String: Any] = kind == .variable
                    ? ["key": "result", "feature": "subject", "variable": "value"]
                    : ["key": "result", "feature": "subject", "variation": true]
                let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile([
                    "healthy": ["bucketBy": "userId", "traffic": [["key": "all", "conditions": "*", "percentage": 100000]]],
                    "subject": ["bucketBy": "userId", "conditions": ["feature": "healthy"],
                                "variablesSchema": ["value": ["type": "string", "defaultValue": "hello"]],
                                "variations": [["value": "on"]],
                                "traffic": [["key": "all", "conditions": "*", "percentage": 100000, "variation": "on"]]],
                ], variables: ["map": ["type": "object", "compose": [source]]]), logLevel: .fatal, modules: [module]))
                defer { f.close() }
                if composed {
                    XCTAssertEqual(f.getVariable("map"), .object(["result": .string(kind == .variable ? "hello" : "on")]))
                } else if kind == .variable {
                    XCTAssertEqual(f.getVariable("subject", "value"), .string("hello"))
                } else {
                    XCTAssertEqual(f.getVariation("subject"), "on")
                }
                XCTAssertEqual(seen.value, [expected], "kind=\(kind), composed=\(composed)")
            }
        }
    }

    func testConditionMemoRetainsJSONFailureAndNullFallbackPerRoot() throws {
        let failures = ConcurrencyBox(0)
        let leaf: [String: Any] = ["variable": "source", "operator": "isNull"]
        let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile([
            "subject": ["bucketBy": "userId", "conditions": [leaf, leaf],
                        "traffic": [["key": "all", "conditions": "*", "percentage": 100000]]],
        ], variables: ["source": ["type": "json", "defaultValue": "{oops"]]), logLevel: .error, onDiagnostic: { diagnostic in
            if diagnostic.message == "getVariable failed" { failures.mutate { $0 += 1 } }
        }))
        defer { f.close() }
        for run in 1...2 {
            XCTAssertTrue(f.isEnabled("subject"))
            XCTAssertEqual(failures.value, run)
        }
    }

    func testCompositionMemoInvalidatesOnModuleDrivenSourceChanges() throws {
        for change in ["datafile", "sticky", "context", "remove", "unsubscribe"] {
            let owner = ConcurrencyBox<Featurevisor?>(nil)
            let reads = ConcurrencyBox(0)
            let changed = ConcurrencyBox(false)
            let unsubscribe = ConcurrencyBox<FeaturevisorUnsubscribe?>(nil)
            let next = try datafile([:], variables: ["source": ["type": "string", "defaultValue": "two"]])
            let module = FeaturevisorModule(name: "change-source", beforeEvaluation: { options in
                var updated = options
                if options.variableKey == "map" { updated.dependencies.context = ["country": .string("one")] }
                return updated
            }, afterEvaluation: { evaluation, options in
                var result = evaluation
                if options.variableKey == "source" {
                    reads.mutate { $0 += 1 }
                    if change == "context" { result.variableValue = options.dependencies.context["country"] }
                }
                if options.variableKey == "missing", !changed.value {
                    changed.value = true
                    XCTAssertEqual(owner.value?.getVariable("healthy"), .string("healthy"))
                    switch change {
                    case "remove": owner.value?.removeModule("temporary")
                    case "unsubscribe": unsubscribe.value?()
                    case "datafile": XCTAssertTrue(owner.value?.setDatafile(next) ?? false)
                    case "sticky": owner.value?.setStickyVariables(["source": .string("two")])
                    default:
                        _ = owner.value?.addModule(FeaturevisorModule(name: "context", beforeEvaluation: { next in
                            var updated = next
                            if next.variableKey == "source" { updated.dependencies.context = ["country": .string("two")] }
                            return updated
                        }))
                    }
                }
                return result
            })
            let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile([:], variables: [
                "source": ["type": "string", "defaultValue": change == "remove" || change == "unsubscribe" ? "two" : "one"],
                "healthy": ["type": "string", "defaultValue": "healthy"],
                "map": ["type": "object", "compose": [
                    ["key": "a", "variable": "source"], ["key": "pivot", "variable": "missing"],
                    ["key": "b", "variable": "source"], ["key": "c", "variable": "source"],
                ]],
            ]), logLevel: .fatal, modules: [module]))
            owner.value = f
            if change == "remove" || change == "unsubscribe" {
                unsubscribe.value = f.addModule(FeaturevisorModule(name: "temporary", afterEvaluation: { evaluation, options in
                    var result = evaluation
                    if options.variableKey == "source" { result.variableValue = .string("one") }
                    return result
                }))
            }
            defer { owner.value = nil; unsubscribe.value = nil; f.close() }
            XCTAssertEqual(f.getVariable("map", [:], OverrideOptions(defaultVariableValue: .string("outer-default"))), .object([
                "a": .string("one"), "pivot": .null, "b": .string("two"), "c": .string("two"),
            ]), change)
            XCTAssertEqual(reads.value, 2, change)
        }
    }

    func testCompletedSessionsAndLiveHandlesDoNotRetainOwnersOrOldProviders() throws {
        for (fail, childMode) in [(false, false), (true, false), (false, true), (true, true)] {
            let provider = LifecycleWeakReference<InstanceEvaluationDataProvider>()
            let session = ConcurrencyBox<EvaluationSession?>(nil)
            let live = ConcurrencyBox<StickySourceHandle?>(nil)
            let module = FeaturevisorModule(name: "lifetime", beforeEvaluation: { options in
                provider.value = options.dependencies.evaluationData
                session.value = options.dependencies.session
                live.value = options.dependencies.stickySource
                return options
            })
            var f: Featurevisor? = createFeaturevisor(FeaturevisorOptions(logLevel: .fatal, modules: [module]))
            weak var weakOwner = f
            var child: FeaturevisorChildInstance? = childMode ? f!.spawn() : nil
            weak var weakChild = child
            for revision in 0..<32 {
                XCTAssertTrue(f!.setDatafile(try datafile([:], variables: [
                    "source": ["type": "integer", "defaultValue": revision],
                    "map": ["type": "object", "compose": [["key": "value", "variable": fail ? "map" : "source"]]],
                ]), replace: true))
                XCTAssertNil(provider.value, "completed session retained a previous provider")
                let evaluation = child?.evaluateVariable("map") ?? f!.evaluateVariable("map")
                XCTAssertEqual(evaluation.reason, fail ? .error : .variableComposed)
                XCTAssertNotNil(session.value)
                XCTAssertNil(live.value?.current(), "completed request retained a live state reader")
            }
            child?.close()
            child = nil
            XCTAssertNil(weakChild)
            f!.close()
            f = nil
            XCTAssertNil(weakOwner, "provider diagnostics or live state retained the SDK")
            XCTAssertNil(provider.value)
            XCTAssertNil(live.value?.current())
            XCTAssertNil(session.value?.current())
        }
    }

    func testRootFeatureHooksKeepJSStickySnapshotUntilNextCall() throws {
        for childMode in [false, true] {
            for kind in [EvaluationType.flag, .variation, .variable] {
                let owner = ConcurrencyBox<Featurevisor?>(nil)
                let child = ConcurrencyBox<FeaturevisorChildInstance?>(nil)
                let module = FeaturevisorModule(name: "root-sticky", beforeEvaluation: { options in
                    if options.featureKey == "subject" {
                        let sticky = ["subject": EvaluatedFeature(enabled: true, variation: "on", variables: ["value": .int(7)])]
                        if childMode { child.value?.setStickyFeatures(sticky) }
                        else { owner.value?.setStickyFeatures(sticky) }
                    }
                    return options
                })
                let f = createFeaturevisor(FeaturevisorOptions(datafile: try datafile([
                    "subject": ["traffic": [], "variablesSchema": ["value": ["type": "integer", "defaultValue": 1]]],
                ]), logLevel: .fatal, modules: [module]))
                owner.value = f
                if childMode { child.value = f.spawn() }
                defer { child.value?.close(); child.value = nil; owner.value = nil; f.close() }
                switch kind {
                case .flag:
                    XCTAssertFalse(child.value?.isEnabled("subject") ?? f.isEnabled("subject"))
                    XCTAssertTrue(child.value?.isEnabled("subject") ?? f.isEnabled("subject"))
                case .variation:
                    XCTAssertNil(childMode ? child.value?.getVariation("subject") : f.getVariation("subject"))
                    XCTAssertEqual(childMode ? child.value?.getVariation("subject") : f.getVariation("subject"), "on")
                case .variable:
                    XCTAssertNil(childMode ? child.value?.getVariable("subject", "value") : f.getVariable("subject", "value"))
                    XCTAssertEqual(childMode ? child.value?.getVariable("subject", "value") : f.getVariable("subject", "value"), .int(7))
                }
            }
        }
    }

    func testSegmentAfterGetterCallbackReadsCurrentDatafile() throws {
        let owner = ConcurrencyBox<Featurevisor?>(nil)
        var input = try datafile([
            "subject": ["conditions": [["variable": "pivot", "operator": "equals", "value": true], "gate"],
                        "traffic": [["key": "all", "conditions": "*", "percentage": 100000]]],
        ], variables: ["pivot": ["type": "boolean", "defaultValue": true]])
        input.segments["gate"] = Segment(conditions: .tree(.list([])))
        var next = try datafile([:])
        next.segments["gate"] = Segment(conditions: .tree(.all))
        let replacement = next
        let module = FeaturevisorModule(name: "replace", beforeEvaluation: { options in
            if options.variableKey == "pivot" { XCTAssertTrue(owner.value?.setDatafile(replacement) ?? false) }
            return options
        })
        let f = createFeaturevisor(FeaturevisorOptions(datafile: input, logLevel: .fatal, modules: [module]))
        owner.value = f
        defer { owner.value = nil; f.close() }
        XCTAssertTrue(f.isEnabled("subject"))
    }

    func testTerminalAttributeFastPathMatchesJSActiveHandoffBound() throws {
        for getters in [0, 1, 128, 255, 256] {
            for offset in [-1, 0, 1, 2] {
                let segments = 256 - getters + offset
                guard segments > 0 else { continue }
                for terminal in ["wildcard", "attribute", "attribute group"] {
                    var variables: [String: Any] = [:]
                    for index in 0...getters {
                        variables["g\(index)"] = index < getters
                            ? ["type": "boolean", "compose": "g\(index + 1)"]
                            : ["type": "boolean", "defaultValue": true, "disabledValue": false, "conditions": "s0"]
                    }
                    var input = try datafile([
                        "healthy": ["traffic": [["key": "all", "conditions": "*", "percentage": 100000]]],
                        "subject": ["conditions": "s0", "traffic": [["key": "all", "conditions": "*", "percentage": 100000]]],
                    ], variables: variables)
                    for index in 0..<segments {
                        var condition = Condition.invalidToken("s\(index + 1)")
                        if index == segments - 1 {
                            condition = .all
                            if terminal != "wildcard" {
                                condition = .predicate(.init(attribute: "country", operator: "equals", value: .string("nl")))
                                if terminal == "attribute group" { condition = .and([condition]) }
                            }
                        }
                        input.segments["s\(index)"] = Segment(conditions: .tree(condition))
                    }
                    let f = createFeaturevisor(FeaturevisorOptions(datafile: input, logLevel: .fatal))
                    defer { f.close() }
                    let active = getters + segments - (terminal == "wildcard" ? 0 : 1)
                    let name = "getters=\(getters), segments=\(segments), terminal=\(terminal)"
                    for _ in 0..<2 {
                        for country in ["nl", "de"] {
                            if getters == 0 {
                                let flag = f.evaluateFlag("subject", context: ["country": .string(country)])
                                let expected: EvaluationReason = active > 256 ? .error : terminal == "wildcard" || country == "nl" ? .rule : .conditionsUnmet
                                XCTAssertEqual(flag.reason, expected, name)
                            }
                            let evaluation = f.evaluateVariable("g0", context: ["country": .string(country)])
                            if active > 256 {
                                XCTAssertEqual(evaluation.reason, .error, name)
                                XCTAssertNil(f.getVariable("g0", ["country": .string(country)]), name)
                            } else {
                                XCTAssertNotEqual(evaluation.reason, .error, name)
                                XCTAssertEqual(evaluation.variableValue, .bool(terminal == "wildcard" || country == "nl"), name)
                            }
                        }
                        XCTAssertTrue(f.isEnabled("healthy"), name)
                    }
                }
            }
        }
    }
}

private final class LifecycleWeakReference<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}
