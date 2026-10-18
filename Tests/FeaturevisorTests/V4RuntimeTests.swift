import Foundation
import XCTest
@testable import Featurevisor

final class V4RuntimeTests: XCTestCase {
    private func datafile(_ json: String) throws -> DatafileContent {
        try DatafileContent.fromJSON(json)
    }

    func testRequirementGroupsShortCircuitAndObserveNestedModuleGetter() throws {
        let raw = #"{"schemaVersion":"2","revision":"callbacks","segments":{},"features":{"gated":{"bucketBy":"userId","conditions":[{"or":[{"variable":"source","operator":"equals","value":true},{"variable":"skipped","operator":"equals","value":true}]}],"traffic":[{"key":"all","segments":"*","percentage":100000}]}},"variables":{"source":{"type":"boolean","defaultValue":false},"skipped":{"type":"boolean","defaultValue":true}}}"#
        let seen = ConcurrencyBox<[String]>([])
        let module = FeaturevisorModule(name: "requirements", afterEvaluation: { evaluation, _ in
            var updated = evaluation
            if evaluation.featureKey == nil, let key = evaluation.variableKey {
                seen.mutate { $0.append(key) }
                if key == "source" { updated.variableValue = .bool(true) }
            }
            return updated
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(raw), modules: [module]))
        XCTAssertTrue(sdk.isEnabled("gated"))
        XCTAssertTrue(sdk.isEnabled("gated"))
        XCTAssertEqual(seen.value, ["source", "source"])
    }

    func testFeatureOverrideFalseConditionsSkipPrerequisites() throws {
        let raw = #"{"schemaVersion":"2","revision":"override-order","segments":{},"features":{"source":{"bucketBy":"userId","force":[{"segments":"*","enabled":true}],"traffic":[]},"host":{"bucketBy":"userId","variablesSchema":{"message":{"type":"string","defaultValue":"default"}},"variations":[{"value":"control","variableOverrides":{"message":[{"key":"variation","requiredFeatures":["source"],"conditions":[{"attribute":"match","operator":"equals","value":true}],"value":"wrong"}]}}],"traffic":[{"key":"all","segments":"*","percentage":100000,"variation":"control","variableOverrides":{"message":[{"key":"rule","requiredFeatures":["source"],"conditions":[{"attribute":"match","operator":"equals","value":true}],"value":"wrong"}]}}]}}}"#
        let calls = ConcurrencyBox<Int>(0)
        let module = FeaturevisorModule(name: "count-prerequisite", afterEvaluation: { evaluation, _ in
            if evaluation.type == .flag, evaluation.featureKey == "source" { calls.mutate { $0 += 1 } }
            return evaluation
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(raw), modules: [module]))
        XCTAssertEqual(sdk.getVariableString("host", "message", ["match": .bool(false)]), "default")
        XCTAssertEqual(calls.value, 0)
    }

    func testEmptyRequiredVariablesMatchOnlySupportedContainerContents() throws {
        let raw = #"{"schemaVersion":"2","revision":"empty-requirements","segments":{},"features":{},"variables":{"emptyString":{"type":"string","defaultValue":""},"whitespace":{"type":"string","defaultValue":" "},"emptyArray":{"type":"array","defaultValue":[]},"arrayWithNull":{"type":"array","defaultValue":[null]},"emptyObject":{"type":"object","defaultValue":{}},"objectWithNull":{"type":"object","defaultValue":{"value":null}},"nullValue":{"type":"object","defaultValue":null},"number":{"type":"integer","defaultValue":0},"boolean":{"type":"boolean","defaultValue":false},"nested":{"type":"object","defaultValue":{"items":[]}},"emptyStringGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"emptyString","operator":"empty"}]},"whitespaceGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"whitespace","operator":"notEmpty"}]},"emptyArrayGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"emptyArray","operator":"empty"}]},"arrayWithNullGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"arrayWithNull","operator":"notEmpty"}]},"emptyObjectGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"emptyObject","operator":"empty"}]},"objectWithNullGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"objectWithNull","operator":"notEmpty"}]},"nestedGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"nested","path":["items"],"operator":"empty"}]},"nullEmptyGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"nullValue","operator":"empty"}]},"nullNotEmptyGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"nullValue","operator":"notEmpty"}]},"missingGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"missing","operator":"empty"}]},"numberGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"number","operator":"notEmpty"}]},"booleanGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"boolean","operator":"empty"}]}}}"#
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(raw)))

        for key in ["emptyStringGate", "whitespaceGate", "emptyArrayGate", "arrayWithNullGate", "emptyObjectGate", "objectWithNullGate", "nestedGate"] {
            XCTAssertEqual(sdk.getVariableString(key), "matched", key)
        }
        for key in ["nullEmptyGate", "nullNotEmptyGate", "missingGate", "numberGate", "booleanGate"] {
            XCTAssertEqual(sdk.getVariableString(key), "miss", key)
            XCTAssertEqual(sdk.evaluateVariable(key).reason, .conditionsUnmet, key)
        }
    }

    func testEmptyRequirementsDoNotMaskSourceModuleErrors() throws {
        let raw = #"{"schemaVersion":"2","revision":"empty-module-error","segments":{},"features":{},"variables":{"source":{"type":"string","defaultValue":""},"emptyGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"source","operator":"empty"}]},"notEmptyGate":{"type":"string","defaultValue":"matched","disabledValue":"miss","conditions":[{"variable":"source","operator":"notEmpty"}]}}}"#
        let module = FeaturevisorModule(name: "source-error", afterEvaluation: { evaluation, _ in
            guard evaluation.variableKey == "source" else { return evaluation }
            var failed = evaluation
            failed.reason = .error
            failed.variableValue = nil
            failed.error = "source failed"
            return failed
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(raw), logLevel: .fatal, modules: [module]))

        XCTAssertEqual(sdk.getVariableString("emptyGate"), "miss")
        XCTAssertEqual(sdk.getVariableString("notEmptyGate"), "miss")
    }

    func testSourceFeatureErrorMatchesDisabledAndNotPrerequisites() throws {
        let raw = #"{"schemaVersion":"2","revision":"feature-error","segments":{},"features":{"source":{"bucketBy":"userId","force":[{"segments":"*","enabled":true}],"traffic":[]},"disabledGate":{"bucketBy":"userId","requiredFeatures":[{"feature":"source","enabled":false}],"traffic":[{"key":"all","segments":"*","percentage":100000}]},"notGate":{"bucketBy":"userId","requiredFeatures":[{"not":["source"]}],"traffic":[{"key":"all","segments":"*","percentage":100000}]}},"variables":{}}"#
        let module = FeaturevisorModule(name: "source-error", afterEvaluation: { evaluation, _ in
            guard evaluation.type == .flag, evaluation.featureKey == "source" else { return evaluation }
            var failed = evaluation
            failed.reason = .error
            failed.enabled = nil
            failed.error = "source failed"
            return failed
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(raw), logLevel: .fatal, modules: [module]))
        XCTAssertEqual(sdk.evaluateFlag("source").reason, .error)
        XCTAssertTrue(sdk.isEnabled("disabledGate"))
        XCTAssertTrue(sdk.isEnabled("notGate"))
    }

    func testChildStickyRequirementsAndOuterDefaultIsolation() throws {
        let raw = #"{"schemaVersion":"2","revision":"child","segments":{},"features":{"source":{"variablesSchema":{"profile":{"type":"integer","defaultValue":0}},"bucketBy":"userId","traffic":[]},"gated":{"bucketBy":"userId","conditions":[{"variable":"globalSource","operator":"equals","value":3},{"feature":"source","variable":"profile","operator":"equals","value":4}],"traffic":[{"key":"all","segments":"*","percentage":100000}]}},"variables":{"globalSource":{"type":"integer","defaultValue":0},"outer":{"type":"string","defaultValue":"default","conditions":[{"variable":"missing","operator":"equals","value":"caller"}]}}}"#
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(raw)))
        let child = sdk.spawn(
            [:],
            options: SpawnOptions(
                stickyFeatures: ["source": EvaluatedFeature(enabled: true, variables: ["profile": .int(4)])],
                stickyVariables: ["globalSource": .int(3)]
            )
        )
        XCTAssertFalse(sdk.isEnabled("gated"))
        XCTAssertTrue(child.isEnabled("gated"))
        XCTAssertEqual(child.getVariableString("outer", [:], OverrideOptions(defaultVariableValue: .string("caller"))), "caller")
        XCTAssertEqual(child.evaluateVariable("outer").reason, .conditionsUnmet)
    }

    func testCycleStateIsIsolatedAcrossConcurrentEvaluationChains() throws {
        let raw = #"{"schemaVersion":"2","revision":"cycles","segments":{},"features":{},"variables":{"cycle":{"type":"string","defaultValue":"cycle","conditions":[{"not":[{"variable":"cycle","operator":"notNull"}]}]},"safe":{"type":"string","defaultValue":"safe"}}}"#
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(raw), logLevel: .fatal))
        let results = ConcurrencyBox<[Bool]>([])
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let passed: Bool
            if index.isMultiple(of: 2) {
                passed = sdk.evaluateVariable("cycle").reason == .error
            } else {
                passed = sdk.getVariableString("safe") == "safe"
            }
            results.mutate { $0.append(passed) }
        }
        XCTAssertEqual(results.value.count, 100)
        XCTAssertTrue(results.value.allSatisfy { $0 })
        XCTAssertEqual(sdk.getVariableString("safe"), "safe")
    }

    func testMixedDependencyNotificationsReachFixedPoint() throws {
        let initial = #"{"schemaVersion":"2","revision":"one","segments":{},"features":{"checkout":{"bucketBy":"userId","conditions":[{"variable":"currency","operator":"equals","value":"EUR"}],"traffic":[]},"receipt":{"bucketBy":"userId","requiredFeatures":["checkout"],"variablesSchema":{"title":{"type":"string","defaultValue":"Receipt"}},"traffic":[]}},"variables":{"currency":{"hash":"one","type":"string","defaultValue":"EUR"},"summary":{"type":"string","defaultValue":"","conditions":[{"feature":"receipt","variable":"title","operator":"equals","value":"Receipt"}]},"final":{"type":"string","defaultValue":"","conditions":[{"variable":"summary","operator":"equals","value":""}]}}}"#
        let updated = initial.replacingOccurrences(of: #""revision":"one""#, with: #""revision":"two""#)
            .replacingOccurrences(of: #""hash":"one""#, with: #""hash":"two""#)
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(initial)))
        let event = ConcurrencyBox<EventPayload?>(nil)
        let unsubscribe = sdk.on(.datafileSet) { event.value = $0 }
        sdk.setDatafile(try datafile(updated), replace: true)
        XCTAssertEqual(
            Set(event.value?.params["features"]?.asArray()?.compactMap { $0.asString() } ?? []),
            Set(["checkout", "receipt"])
        )
        XCTAssertEqual(
            Set(event.value?.params["variables"]?.asArray()?.compactMap { $0.asString() } ?? []),
            Set(["currency", "summary", "final"])
        )
        unsubscribe()
    }

    func testHashlessFeatureSeedsMixedDependencyNotifications() throws {
        let initial = #"{"schemaVersion":"2","revision":"one","segments":{},"features":{"source":{"hash":"","bucketBy":"userId","traffic":[]},"gate":{"hash":"gate","bucketBy":"userId","requiredFeatures":["source"],"traffic":[]},"finalGate":{"hash":"finalGate","bucketBy":"userId","conditions":[{"variable":"final","operator":"equals","value":"f"}],"traffic":[]},"globalGate":{"hash":"globalGate","bucketBy":"userId","conditions":[{"variable":"globalSource","operator":"equals","value":"g"}],"traffic":[]}},"variables":{"middle":{"hash":"middle","type":"string","defaultValue":"m","requiredFeatures":["gate"]},"final":{"hash":"final","type":"string","defaultValue":"f","conditions":[{"variable":"middle","operator":"equals","value":"m"}]},"globalSource":{"hash":"","type":"string","defaultValue":"g"}}}"#
        let updated = initial.replacingOccurrences(of: #""revision":"one""#, with: #""revision":"two""#)
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(initial)))
        let event = ConcurrencyBox<EventPayload?>(nil)
        _ = sdk.on(.datafileSet) { event.value = $0 }

        sdk.setDatafile(try datafile(updated), replace: true)

        XCTAssertEqual(
            Set(event.value?.params["features"]?.asArray()?.compactMap { $0.asString() } ?? []),
            Set(["source", "gate", "finalGate", "globalGate"])
        )
        XCTAssertEqual(
            Set(event.value?.params["variables"]?.asArray()?.compactMap { $0.asString() } ?? []),
            Set(["middle", "final", "globalSource"])
        )
    }

    func testNonemptyVariableHashesAreAuthoritativeForUpdateNotifications() throws {
        let initial = #"{"schemaVersion":"2","revision":"one","segments":{},"features":{"gate":{"hash":"gate","bucketBy":"userId","conditions":[{"variable":"source","operator":"equals","value":"before"}],"traffic":[]}},"variables":{"source":{"hash":"stable","type":"string","defaultValue":"before"}}}"#
        let sameHash = #"{"schemaVersion":"2","revision":"two","segments":{},"features":{"gate":{"hash":"gate","bucketBy":"userId","conditions":[{"variable":"source","operator":"equals","value":"before"}],"traffic":[]}},"variables":{"source":{"hash":"stable","type":"string","defaultValue":"after"}}}"#
        let changedHash = sameHash
            .replacingOccurrences(of: #""revision":"two""#, with: #""revision":"three""#)
            .replacingOccurrences(of: #""hash":"stable""#, with: #""hash":"changed""#)
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(initial)))
        let event = ConcurrencyBox<EventPayload?>(nil)
        _ = sdk.on(.datafileSet) { event.value = $0 }

        sdk.setDatafile(try datafile(sameHash), replace: true)
        XCTAssertEqual(event.value?.params["variables"]?.asArray(), [])
        XCTAssertEqual(event.value?.params["features"]?.asArray(), [])

        sdk.setDatafile(try datafile(changedHash), replace: true)
        XCTAssertEqual(
            Set(event.value?.params["variables"]?.asArray()?.compactMap { $0.asString() } ?? []),
            Set(["source"])
        )
        XCTAssertEqual(
            Set(event.value?.params["features"]?.asArray()?.compactMap { $0.asString() } ?? []),
            Set(["gate"])
        )
    }

    func testEmptyProgramWinsOverOrdinaryOverridesAndKeepsEmptyContainers() throws {
        let raw = #"{"schemaVersion":"2","revision":"empty","segments":{},"features":{},"variables":{"subject":{"type":"object","defaultValue":{},"overrideProgram":[],"overrides":[{"key":"legacy","segments":"*","value":{"wrong":true}}]},"array":{"type":"array","defaultValue":[]}}}"#
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(raw)))
        let evaluation = sdk.evaluateVariable("subject")
        XCTAssertEqual(evaluation.reason, .variableDefault)
        XCTAssertEqual(evaluation.variableValue, .object([:]))
        XCTAssertNil(evaluation.variableOverrideIndex)
        XCTAssertNil(evaluation.variableOverridePaths)
        XCTAssertEqual(sdk.getVariableArray("array"), [])
        XCTAssertEqual(sdk.getVariableObject("subject"), [:])
    }

    func testMalformedStringifiedSegmentsFailGlobalOverrideSelectors() throws {
        let raw = #"{"schemaVersion":"2","revision":"segment-errors","segments":{},"features":{},"variables":{"ordinary":{"type":"string","defaultValue":"default","overrides":[{"key":"broken","segments":"{","value":"wrong"}]},"program":{"type":"string","defaultValue":"default","overrideProgram":[{"key":"root","segments":"{","operations":[{"op":"set","path":[],"value":"wrong"}],"onMatch":1,"onMiss":1}]}}}"#
        let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
        let sdk = createFeaturevisor(FeaturevisorOptions(
            datafile: try datafile(raw),
            logLevel: .debug,
            onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }
        ))

        let ordinary = sdk.evaluateVariable("ordinary")
        let program = sdk.evaluateVariable("program")

        XCTAssertEqual(ordinary.reason, .variableDefault)
        XCTAssertEqual(ordinary.variableValue, .string("default"))
        XCTAssertEqual(program.reason, .variableDefault)
        XCTAssertEqual(program.variableValue, .string("default"))
        let errors = diagnostics.value.filter { $0.code == "conditions_parse_error" }
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.allSatisfy { $0.message == "Error parsing conditions" })
        XCTAssertEqual(Set(errors.compactMap { $0.details["entityKey"]?.asString() }), Set(["ordinary", "program"]))
    }

    func testNullOperatorsDistinguishMissingContextFromNull() {
        XCTAssertFalse(allConditionsAreMatched(.predicate(.init(attribute: "value", operator: "isNull")), context: [:]))
        XCTAssertFalse(allConditionsAreMatched(.predicate(.init(attribute: "value", operator: "notNull")), context: [:]))
        XCTAssertTrue(allConditionsAreMatched(.predicate(.init(attribute: "value", operator: "isNull")), context: ["value": .null]))
        XCTAssertFalse(allConditionsAreMatched(.predicate(.init(attribute: "value", operator: "notNull")), context: ["value": .null]))
    }

    func testExplicitNullDisabledValuesRemainPresent() throws {
        let raw = #"{"schemaVersion":"2","revision":"nulls","segments":{},"features":{"off":{"variablesSchema":{"value":{"type":"object","defaultValue":{},"disabledValue":null}},"bucketBy":"userId","traffic":[]}},"variables":{"source":{"type":"boolean","defaultValue":false},"subject":{"type":"object","defaultValue":{},"disabledValue":null,"conditions":[{"variable":"source","operator":"equals","value":true}]}}}"#
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(raw)))
        XCTAssertEqual(sdk.evaluateVariable("off", "value").variableValue, .null)
        XCTAssertEqual(sdk.getVariable("off", "value"), .null)
        XCTAssertEqual(sdk.evaluateVariable("subject").variableValue, .null)
        XCTAssertEqual(sdk.getVariable("subject"), .null)
    }
}
