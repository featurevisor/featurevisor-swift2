import Foundation
import XCTest

@testable import Featurevisor

final class EvaluationStateLifecycleTests: XCTestCase {
    private func datafile(
        _ features: [String: Any] = [:], variables: [String: Any] = [:], segments: [String: Any] = [:]
    ) throws -> DatafileContent {
        try DatafileContent.fromData(
            JSONSerialization.data(withJSONObject: [
                "schemaVersion": "4", "revision": "evaluation-state", "features": features,
                "variables": variables, "segments": segments,
            ]))
    }

    func testRootStorageIsLazyAndKeepsBothCycleIdentities() throws {
        let session = EvaluationSession()
        let original = DependencyOf(type: .flag, featureKey: "original")
        let redirected = DependencyOf(type: .flag, featureKey: "redirected")
        XCTAssertTrue(session.beginRoot(original))
        session.updateCurrent(redirected)
        XCTAssertEqual(session.current(), redirected)
        XCTAssertFalse(session.hasDependencyStorage)
        XCTAssertEqual(session.workCounts.keys, 0)
        let provider = InstanceEvaluationDataProvider(datafile: try datafile(), reportDiagnostic: { _ in })
        let manager = ModulesManager(
            modules: [], reportDiagnostic: { _, _ in },
            getModuleApi: { _ in
                FeaturevisorModuleApi(
                    getRevision: { "evaluation-state" }, onDiagnostic: { _, _ in {} }, reportDiagnostic: { _ in })
            }, clearModuleDiagnosticSubscriptions: { _ in })
        let dependencies = EvaluateDependencies(
            context: [:], reportDiagnostic: { _ in },
            diagnosticAudience: EvaluationDiagnosticAudience(logLevel: .fatal),
            modulesManager: manager, evaluationData: provider, session: session)
        for identity in [original, redirected] {
            XCTAssertThrowsError(try session.read(identity, dependencies: dependencies) { _ in .flag(true) })
        }
        XCTAssertTrue(session.hasDependencyStorage)
        session.endRoot()
        XCTAssertNil(session.current())
        XCTAssertFalse(session.hasDependencyStorage)
        XCTAssertTrue(session.beginRoot(original))
        XCTAssertTrue(try session.segment("terminal") { true })
        XCTAssertTrue(session.hasDependencyStorage)
        session.endRoot()
    }

    func testStickyTokenDomainsInvalidateIndependentlyAndRootsStayDistinct() throws {
        let provider = InstanceEvaluationDataProvider(datafile: try datafile(), reportDiagnostic: { _ in })
        let manager = ModulesManager(
            modules: [], reportDiagnostic: { _, _ in }, getModuleApi: { _ in fatalError() },
            clearModuleDiagnosticSubscriptions: { _ in })
        func dependencies() -> EvaluateDependencies {
            EvaluateDependencies(
                context: [:], reportDiagnostic: { _ in },
                diagnosticAudience: EvaluationDiagnosticAudience(logLevel: .fatal),
                modulesManager: manager, evaluationData: provider)
        }
        var first = dependencies()
        let second = dependencies()
        XCTAssertNotEqual(first.stickyFeaturesToken, second.stickyFeaturesToken)
        XCTAssertNotEqual(first.stickyVariablesToken, second.stickyVariablesToken)
        let original = first
        first.stickyFeatures = [:]
        XCTAssertNotEqual(first.stickyFeaturesToken, original.stickyFeaturesToken)
        XCTAssertEqual(first.stickyVariablesToken, original.stickyVariablesToken)
        let featureToken = first.stickyFeaturesToken
        first.stickyVariables = [:]
        XCTAssertEqual(first.stickyFeaturesToken, featureToken)
        XCTAssertNotEqual(first.stickyVariablesToken, original.stickyVariablesToken)
        let copied = first
        XCTAssertEqual(copied.stickyFeaturesToken, first.stickyFeaturesToken)
        XCTAssertEqual(copied.stickyVariablesToken, first.stickyVariablesToken)
    }

    func testDependencyExtractionVisitsEverySelectorWithoutWarmingCaches() throws {
        let raw = try datafile([
            "subject": [
                "conditions": #"[{"variable":"root","operator":"equals","value":true}]"#,
                "requiredFeatures": ["required"],
                "force": [["segments": "force", "enabled": true]],
                "traffic": [[
                    "key": "all", "segments": "traffic", "percentage": 100000,
                    "variableOverrides": ["value": [["segments": "trafficOverride", "value": true]]],
                ]],
                "variations": [[
                    "value": "a", "variableOverrides": ["value": [[
                        "requiredFeatures": ["variationRequired"], "conditions": "variationOverride", "value": true,
                    ]]],
                ]],
            ],
            "invalid": ["conditions": "[broken", "requiredFeatures": ["discarded"], "traffic": []],
        ], variables: [
            "ordinary": ["type": "boolean", "defaultValue": true, "overrides": [[
                "conditions": "globalOverride", "requiredFeatures": ["globalRequired"], "value": false,
            ]]],
            "program": [
                "type": "boolean", "defaultValue": true,
                "overrides": [["conditions": "ignoredOverride", "value": false]],
                "overrideProgram": [[
                    "key": "step", "conditions": "programCondition", "segments": "programSegment",
                    "requiredFeatures": ["programRequired"], "operations": [], "onMatch": 1, "onMiss": 1,
                ]],
            ],
            "alias": ["type": "boolean", "compose": "ordinary"],
            "map": ["type": "object", "compose": [
                ["key": "feature", "feature": "subject"], ["key": "variable", "variable": "ordinary"],
            ]],
        ], segments: ["segment": ["conditions": #"[{"feature":"segmentFeature"}]"#]])
        for schema in ["2", "4"] {
            var input = raw
            input.schemaVersion = schema
            input = normalizeLegacyDatafile(input).0
            let provider = InstanceEvaluationDataProvider(datafile: input, reportDiagnostic: { _ in XCTFail("index reported a diagnostic") })
            let index = provider.getDependencyIndex()
            let expected: [DatafileDependencyOwner: Set<DatafileDependencyOwner>] = [
                .init(kind: 0, key: "subject"): [
                    .init(kind: 1, key: "root"), .init(kind: 0, key: "required"),
                    .init(kind: 2, key: "force"), .init(kind: 2, key: "traffic"),
                    .init(kind: 2, key: "trafficOverride"), .init(kind: 2, key: "variationOverride"),
                    .init(kind: 0, key: "variationRequired"),
                ],
                .init(kind: 1, key: "ordinary"): [.init(kind: 2, key: "globalOverride"), .init(kind: 0, key: "globalRequired")],
                .init(kind: 1, key: "program"): [
                    .init(kind: 2, key: "programCondition"), .init(kind: 2, key: "programSegment"), .init(kind: 0, key: "programRequired"),
                ],
                .init(kind: 1, key: "alias"): [.init(kind: 1, key: "ordinary")],
                .init(kind: 1, key: "map"): [.init(kind: 0, key: "subject"), .init(kind: 1, key: "ordinary")],
                .init(kind: 2, key: "segment"): [.init(kind: 0, key: "segmentFeature")],
            ]
            XCTAssertEqual(index.owners, expected, "schema \(schema)")
            XCTAssertEqual(provider.getCachedEntityCount(), 0)
        }
    }

    func testFullMergeRefreshesChangedEdgesEvenWithUnchangedHashes() throws {
        let before = try datafile([
            "subject": ["hash": "same", "conditions": "old", "traffic": []],
        ], variables: [
            "gate": ["hash": "gate1", "type": "boolean", "defaultValue": true],
            "alias": ["hash": "same", "type": "boolean", "compose": "removed"],
        ], segments: ["old": ["conditions": "*"], "new": ["conditions": "*"]])
        var after = before
        after.features["subject"]?.conditions = .invalidToken("new")
        after.variables?["alias"]?.compose = .alias("gate")
        after.variables?["gate"]?.hash = "gate2"
        let previous = InstanceEvaluationDataProvider(datafile: before, reportDiagnostic: { _ in })
        let next = InstanceEvaluationDataProvider(datafile: after, reportDiagnostic: { _ in }, previous: previous, incoming: after)
        let event = getParamsForDatafileSetEvent(
            previousInstanceEvaluationDataProvider: previous, newInstanceEvaluationDataProvider: next, replace: false)
        XCTAssertEqual(event["features"], .array([]))
        XCTAssertEqual(event["variables"], .array([.string("alias"), .string("gate")]))
        XCTAssertEqual(event["replaced"], .bool(false))
        let index = next.getDependencyIndex()
        let rebuilt = createDatafileDependencyIndex(after)
        XCTAssertEqual(index.edges, rebuilt.edges)
        XCTAssertEqual(index.owners, rebuilt.owners)
        XCTAssertEqual(index.extractedEntities, 3)
        XCTAssertEqual(previous.getDependencyIndex().edges[2][0]["old"], ["subject"])
        XCTAssertNil(index.edges[2][0]["old"])
        XCTAssertNil(index.edges[1][1]["removed"])
        XCTAssertEqual(index.edges[2][0]["new"], ["subject"])
        XCTAssertEqual(next.getCachedEntityCount(), 0)
    }

    func testIndexSharesOnlyTemporaryParsesAndPreservesEntityDiagnostics() throws {
        let shared = #"[{"variable":"gate","operator":"equals","value":true}]"#
        let broken = "[broken"
        var segments: [String: Any] = [:]
        for index in 0..<500 { segments["s\(index)"] = ["conditions": shared] }
        let raw = try datafile([
            "first": ["conditions": broken, "traffic": []],
            "second": ["conditions": broken, "traffic": []],
            "valid": ["conditions": shared, "traffic": []],
        ], variables: [
            "broken": ["type": "boolean", "conditions": broken],
            "valid": ["type": "boolean", "conditions": shared],
        ], segments: segments)
        let diagnostics = ConcurrencyBox<[AnyValue]>([])
        let provider = InstanceEvaluationDataProvider(datafile: raw, reportDiagnostic: { item in
            XCTAssertEqual(item.code, "conditions_parse_error")
            diagnostics.mutate { $0.append(item.details["entityKey"] ?? .null) }
        })
        let index = provider.getDependencyIndex()
        XCTAssertEqual(index.decodedConditions, 2)
        XCTAssertEqual(index.extractedEntities, 505)
        XCTAssertEqual(index.edges[1][2]["gate"]?.count, 500)
        XCTAssertEqual(index.edges[1][0]["gate"], ["valid"])
        XCTAssertEqual(index.edges[1][1]["gate"], ["valid"])
        XCTAssertEqual(provider.getCachedEntityCount(), 0)
        XCTAssertEqual(diagnostics.value, [])
        for _ in 0..<2 {
            _ = provider.getFeature("first")
            _ = provider.getFeature("second")
            _ = provider.getGlobalVariable("broken")
        }
        XCTAssertEqual(diagnostics.value, [.string("first"), .string("second"), .string("broken")])
        XCTAssertEqual(provider.getCachedEntityCount(), 3)
        XCTAssertEqual(createDatafileDependencyIndex(raw).decodedConditions, 2)
    }

    func testIndexStillExtractsDistinctSelectorsBeyondItsParseCacheBound() throws {
        var segments: [String: Any] = [:]
        for index in 0..<300 {
            segments["s\(index)"] = ["conditions": "[{\"feature\":\"f\(index)\"}]"]
        }
        let index = createDatafileDependencyIndex(try datafile(segments: segments))
        XCTAssertEqual(index.decodedConditions, 300)
        XCTAssertEqual(index.owners.count, 300)
        for key in 0..<300 { XCTAssertEqual(index.edges[0][2]["f\(key)"], ["s\(key)"]) }
    }

    func testRetainedSelectorsAreNeverExtractedDuringCachedUpdates() throws {
        for size in [8, 512] {
            var segments: [String: Any] = [:]
            for index in 0..<size {
                segments["s\(index)"] = [
                    "conditions": "[{\"variable\":\"gate\",\"operator\":\"equals\",\"value\":true}]"
                ]
            }
            var raw = try datafile(
                [
                    "subject": ["hash": "subject", "conditions": "s0", "bucketBy": "userId", "traffic": []]
                ],
                variables: [
                    "gate": ["hash": "gate0", "type": "boolean", "defaultValue": true],
                    "alias": ["hash": "alias", "type": "boolean", "compose": "gate"],
                ], segments: segments)
            var provider = InstanceEvaluationDataProvider(
                datafile: raw, reportDiagnostic: { _ in XCTFail("index emitted a diagnostic") })
            XCTAssertEqual(provider.getCachedDependencyIndexCount(), 0)
            for revision in 1...8 {
                let incoming = try datafile(variables: [
                    "gate": ["hash": "gate\(revision)", "type": "boolean", "defaultValue": revision % 2 == 0]
                ])
                raw.variables?["gate"] = incoming.variables?["gate"]
                let next = InstanceEvaluationDataProvider(
                    datafile: raw, reportDiagnostic: { _ in XCTFail("index emitted a diagnostic") }, previous: provider,
                    incoming: incoming)
                let event = getParamsForDatafileSetEvent(
                    previousInstanceEvaluationDataProvider: provider, newInstanceEvaluationDataProvider: next,
                    replace: false)
                XCTAssertEqual(event["features"], .array([.string("subject")]))
                XCTAssertEqual(event["variables"], .array([.string("alias"), .string("gate")]))
                XCTAssertEqual(next.getDependencyIndex().extractedEntities, 1, "size=\(size), revision=\(revision)")
                XCTAssertEqual(next.getCachedEntityCount(), 0)
                provider = next
            }
        }
    }

    func testOldAndNewGraphsRemainIndependentAndRemovedOwnerEdgesDisappear() throws {
        let before = try datafile(variables: [
            "root": ["hash": "root", "type": "boolean", "defaultValue": true],
            "bridge": ["hash": "bridge", "type": "boolean", "defaultValue": true],
            "phantom": ["hash": "phantom", "type": "boolean", "compose": "bridge"],
        ])
        let after = try datafile(variables: [
            "root": ["hash": "root2", "type": "boolean", "defaultValue": false],
            "bridge": ["hash": "bridge2", "type": "boolean", "compose": "root"],
        ])
        let old = createDatafileDependencyIndex(before)
        let next = createDatafileDependencyIndex(
            after, previous: old, replacing: [[], ["root", "bridge", "phantom"], []])
        var features = Set<String>()
        var variables: Set<String> = ["root"]
        addDatafileDependencyChanges(features: &features, variables: &variables, changedSegments: [], index: old)
        addDatafileDependencyChanges(features: &features, variables: &variables, changedSegments: [], index: next)
        XCTAssertEqual(variables, ["root", "bridge"])
        XCTAssertEqual(old.edges[1][1]["bridge"], ["phantom"])
        XCTAssertNil(next.edges[1][1]["bridge"])
        XCTAssertNil(next.owners[DatafileDependencyOwner(kind: 1, key: "phantom")])
    }

    func testConcurrentPartialWritersKeepAllEntitiesAndRetainedDiagnosticCaches() throws {
        let diagnostics = ConcurrencyBox(0)
        let sdk = createFeaturevisor(
            FeaturevisorOptions(
                datafile: try datafile(variables: [
                    "source": ["hash": "source", "type": "string", "defaultValue": "stable"],
                    "alias": ["hash": "alias", "type": "string", "compose": "source"],
                    "broken": ["hash": "broken", "type": "string", "defaultValue": "wrong", "conditions": "[broken"],
                ]), logLevel: .error,
                onDiagnostic: { diagnostic in
                    if diagnostic.code == "conditions_parse_error" { diagnostics.mutate { $0 += 1 } }
                }))
        defer { sdk.close() }
        XCTAssertNil(sdk.getVariable("broken"))
        let patches = try (0..<32).map { index in
            try datafile(variables: [
                "v\(index * 4)": ["hash": "v\(index * 4)", "type": "integer", "defaultValue": index * 4]
            ])
        }
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            if index % 4 == 0 {
                XCTAssertTrue(sdk.setDatafile(patches[index / 4]))
            } else {
                XCTAssertEqual(sdk.getVariable("alias"), .string("stable"))
                XCTAssertNil(sdk.getVariable("broken"))
            }
        }
        for index in stride(from: 0, to: 128, by: 4) { XCTAssertEqual(sdk.getVariable("v\(index)"), .int(index)) }
        XCTAssertEqual(diagnostics.value, 1)
    }

    func testCurrentPhaseModulesIncludeLateAdditionsAndExcludeRemovals() throws {
        for global in [false, true] {
            for removing in [false, true] {
                for disableGate in [false, true] {
                    let trace = ConcurrencyBox<[String]>([])
                    let owner = ConcurrencyBox<Featurevisor?>(nil)
                    let late = FeaturevisorModule(
                        name: "observer",
                        beforeEvaluation: { options in
                            trace.mutate {
                                $0.append(
                                    "before:\(options.globalVariable ? options.variableKey! : options.featureKey)")
                            }
                            return options
                        },
                        afterEvaluation: { evaluation, options in
                            trace.mutate {
                                $0.append("after:\(options.globalVariable ? options.variableKey! : options.featureKey)")
                            }
                            var result = evaluation
                            if disableGate && options.featureKey == "gate" { result.enabled = false }
                            return result
                        })
                    let raw = try datafile(
                        [
                            "broken": [
                                "bucketBy": "userId", "conditions": "[broken",
                                "traffic": [
                                    ["key": "all", "conditions": "*", "percentage": 100000]
                                ],
                            ],
                            "gate": [
                                "bucketBy": "userId",
                                "traffic": [["key": "all", "conditions": "*", "percentage": 100000]],
                            ],
                            "subject": [
                                "bucketBy": "userId",
                                "conditions": ["or": [["feature": "broken"], ["feature": "gate"]]],
                                "traffic": [["key": "all", "conditions": "*", "percentage": 100000]],
                            ],
                        ],
                        variables: [
                            "subject": [
                                "type": "string", "defaultValue": "matched",
                                "conditions": ["or": [["feature": "broken"], ["feature": "gate"]]],
                            ]
                        ])
                    let sdk = createFeaturevisor(
                        FeaturevisorOptions(
                            datafile: raw, logLevel: .error,
                            onDiagnostic: { diagnostic in
                                guard diagnostic.code == "conditions_parse_error" else { return }
                                if removing {
                                    owner.value?.removeModule("observer")
                                } else {
                                    _ = owner.value?.addModule(late)
                                }
                            }, modules: removing ? [late] : []))
                    owner.value = sdk
                    let blocked = disableGate && !removing
                    let result =
                        global
                        ? sdk.evaluateVariable("subject")
                        : sdk.evaluateFlag("subject", context: ["userId": .string("u")])
                    if global {
                        XCTAssertEqual(result.variableValue, blocked ? nil : .string("matched"))
                    } else {
                        XCTAssertEqual(result.enabled, !blocked)
                    }
                    if blocked { XCTAssertEqual(result.reason, .conditionsUnmet) }
                    XCTAssertEqual(
                        trace.value,
                        removing
                            ? ["before:subject", "before:broken"]
                            : ["after:broken", "before:gate", "after:gate", "after:subject"])
                    sdk.close()
                    owner.value = nil
                }
            }
        }
    }
}
