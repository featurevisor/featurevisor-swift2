import Foundation
import XCTest
@testable import Featurevisor

final class SessionTests: XCTestCase {
    func testStickyScalingBenchmarkForSerialRuns() throws {
        guard ProcessInfo.processInfo.environment["FEATUREVISOR_STICKY_BENCHMARK"] == "1" else {
            throw XCTSkip("Run only during an isolated serial benchmark")
        }
        let warmup = try benchmarkCount("FEATUREVISOR_STICKY_WARMUP", defaultValue: 5000)
        let iterations = try benchmarkCount("FEATUREVISOR_STICKY_ITERATIONS", defaultValue: 10000)
        print("kind,size,instance,nanoseconds_per_evaluation")
        let enabled: [String: Any] = [
            "bucketBy": "userId",
            "traffic": [["key": "all", "segments": "*", "percentage": 100000]],
        ]
        for kind in ["features", "variables"] {
            var root = variable(kind == "variables" ? [requirement("leaf"), requirement("leaf")] : [])
            if kind == "features" { root["requiredFeatures"] = ["leaf", "leaf"] }
            let fixture = try datafile(["root": root, "leaf": variable(value: 0)], features: ["leaf": enabled])
            for size in [0, 100, 1000, 5000] {
                let (stickyFeatures, stickyVariables) = try exportedSticky(kind, size: size, enabled: enabled)
                for childMode in [false, true] {
                    let sdk = createFeaturevisor(FeaturevisorOptions(
                        datafile: fixture, logLevel: .fatal,
                        stickyFeatures: childMode || kind != "features" ? nil : stickyFeatures,
                        stickyVariables: childMode || kind != "variables" ? nil : stickyVariables
                    ))
                    let child = childMode ? sdk.spawn(options: SpawnOptions(
                        stickyFeatures: kind == "features" ? stickyFeatures : nil,
                        stickyVariables: kind == "variables" ? stickyVariables : nil
                    )) : nil
                    defer { child?.close(); sdk.close() }
                    XCTAssertEqual(childMode ? child!.getVariableInteger("root") : sdk.getVariableInteger("root"), 1)
                    for _ in 0..<warmup {
                        _ = childMode ? child!.getVariableInteger("root") : sdk.getVariableInteger("root")
                    }
                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<iterations {
                        _ = childMode ? child!.getVariableInteger("root") : sdk.getVariableInteger("root")
                    }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    print("\(kind),\(size),\(childMode ? "child" : "primary"),\(elapsed / UInt64(iterations))")
                }
            }
        }
    }

    func testExportedStickyCorpusWorksForPrimaryAndChild() throws {
        let enabled: [String: Any] = [
            "bucketBy": "userId",
            "traffic": [["key": "all", "segments": "*", "percentage": 100000]],
        ]
        for kind in ["features", "variables"] {
            let (stickyFeatures, stickyVariables) = try exportedSticky(kind, size: 100, enabled: enabled)
            XCTAssertEqual(kind == "features" ? stickyFeatures.count : stickyVariables.count, 101)
            var root = variable(kind == "variables" ? [requirement("leaf"), requirement("leaf")] : [])
            if kind == "features" { root["requiredFeatures"] = ["leaf", "leaf"] }
            let sdk = createFeaturevisor(FeaturevisorOptions(
                datafile: try datafile(["root": root, "leaf": variable(value: 0)], features: ["leaf": enabled]),
                logLevel: .fatal,
                stickyFeatures: kind == "features" ? stickyFeatures : nil,
                stickyVariables: kind == "variables" ? stickyVariables : nil
            ))
            defer { sdk.close() }
            XCTAssertEqual(sdk.getVariableInteger("root"), 1)
            let child = sdk.spawn(options: SpawnOptions(
                stickyFeatures: kind == "features" ? stickyFeatures : nil,
                stickyVariables: kind == "variables" ? stickyVariables : nil
            ))
            defer { child.close() }
            XCTAssertEqual(child.getVariableInteger("root"), 1)
        }
    }

    private func exportedSticky(
        _ kind: String, size: Int, enabled: [String: Any]
    ) throws -> (StickyFeatures, StickyVariables) {
        var sourceFeatures: [String: [String: Any]] = [:]
        var sourceVariables: [String: [String: Any]] = [:]
        for index in 0..<size {
            if kind == "features" { sourceFeatures["unrelated\(index)"] = enabled }
            else { sourceVariables["unrelated\(index)"] = variable(value: index) }
        }
        if kind == "features" { sourceFeatures["leaf"] = enabled }
        else { sourceVariables["leaf"] = variable(value: 1) }
        let exporter = createFeaturevisor(FeaturevisorOptions(
            datafile: try datafile(sourceVariables, features: sourceFeatures), logLevel: .fatal
        ))
        defer { exporter.close() }
        return (
            kind == "features" ? exporter.getFeatureEvaluations(["userId": .string("bench")]) : [:],
            kind == "variables" ? exporter.getVariableEvaluations() : [:]
        )
    }

    func testStickyMemoWorkStaysBoundedAcrossRootAndChildInputs() throws {
        let enabled: [String: Any] = [
            "bucketBy": "userId",
            "traffic": [["key": "all", "segments": "*", "percentage": 100000]],
        ]
        var rootFeature = enabled
        rootFeature["requiredFeatures"] = ["leaf", "leaf"]
        let featureDatafile = try datafile([:], features: ["root": rootFeature, "leaf": enabled])
        let variableDatafile = try datafile([
            "root": variable([requirement("leaf"), requirement("leaf")]),
            "leaf": variable(value: 0),
        ])
        for kind in ["features", "variables"] {
            for childMode in [false, true] {
                for size in [0, 100, 1000, 5000] {
                    var stickyFeatures: StickyFeatures = ["leaf": EvaluatedFeature(enabled: true)]
                    var stickyVariables: StickyVariables = ["leaf": .int(1)]
                    for index in 0..<size {
                        if kind == "features" {
                            stickyFeatures["unrelated\(index)"] = EvaluatedFeature(
                                enabled: true, variables: ["payload": .object(["nested": .int(index)])]
                            )
                        } else {
                            stickyVariables["unrelated\(index)"] = .object(["nested": .int(index)])
                        }
                    }
                    let leafReads = ConcurrencyBox(0)
                    let session = ConcurrencyBox<EvaluationSession?>(nil)
                    let module = FeaturevisorModule(name: "key-size", beforeEvaluation: { options in
                        let leaf = kind == "features" ? options.featureKey == "leaf" : options.variableKey == "leaf"
                        if leaf {
                            leafReads.mutate { $0 += 1 }
                            session.value = options.dependencies.session
                        }
                        return options
                    })
                    let sdk = createFeaturevisor(FeaturevisorOptions(
                        datafile: kind == "features" ? featureDatafile : variableDatafile,
                        logLevel: .fatal,
                        stickyFeatures: childMode || kind != "features" ? nil : stickyFeatures,
                        stickyVariables: childMode || kind != "variables" ? nil : stickyVariables,
                        modules: [module]
                    ))
                    let child = childMode ? sdk.spawn(options: SpawnOptions(
                        stickyFeatures: kind == "features" ? stickyFeatures : nil,
                        stickyVariables: kind == "variables" ? stickyVariables : nil
                    )) : nil
                    defer { child?.close(); sdk.close() }
                    if kind == "features" {
                        XCTAssertTrue(childMode ? child!.isEnabled("root") : sdk.isEnabled("root"))
                    } else {
                        XCTAssertEqual(childMode ? child!.getVariableInteger("root") : sdk.getVariableInteger("root"), 1)
                    }
                    XCTAssertEqual(leafReads.value, 1, "\(kind), child=\(childMode), size=\(size)")
                    XCTAssertEqual(session.value?.workCounts.keys, 2, "\(kind), child=\(childMode), size=\(size)")
                    XCTAssertEqual(session.value?.workCounts.snapshots, 1, "\(kind), child=\(childMode), size=\(size)")
                }
            }
        }
    }

    private func benchmarkCount(_ name: String, defaultValue: Int) throws -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return defaultValue }
        guard let value = Int(raw), value > 0 else {
            throw NSError(domain: "\(name) must be a positive integer", code: 1)
        }
        return value
    }

    private func datafile(_ variables: [String: [String: Any]], features: [String: [String: Any]] = [:]) throws -> DatafileContent {
        let value: [String: Any] = [
            "schemaVersion": "2", "revision": "session", "segments": [:],
            "features": features, "variables": variables,
        ]
        return try DatafileContent.fromData(JSONSerialization.data(withJSONObject: value))
    }

    private func variable(_ requirements: [[String: Any]] = [], value: Any = 1) -> [String: Any] {
        var result: [String: Any] = ["type": "integer", "defaultValue": value]
        if !requirements.isEmpty { result["conditions"] = requirements }
        return result
    }

    private func requirement(_ key: String, value: Any = 1) -> [String: Any] {
        ["variable": key, "operator": "equals", "value": value]
    }

    func testDiamondMemoUsesOneDependencyReadPerRequestAndImmediateParent() throws {
        var variables: [String: [String: Any]] = ["leaf": variable()]
        var previous = "leaf"
        for index in 0..<18 {
            variables["level\(index)"] = variable([requirement(previous), requirement(previous)])
            previous = "level\(index)"
        }
        let seen = ConcurrencyBox<[(String, DependencyOf?)]>([])
        let module = FeaturevisorModule(name: "observe", beforeEvaluation: { options in
            seen.mutate { $0.append((options.variableKey ?? "", options.dependencyOf)) }
            return options
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), modules: [module]))

        XCTAssertEqual(sdk.getVariableInteger(previous), 1)
        XCTAssertEqual(seen.value.count, 19)
        XCTAssertEqual(seen.value.first?.0, "level17")
        XCTAssertNil(seen.value.first?.1)
        XCTAssertEqual(seen.value[1].1, DependencyOf(type: .variable, variableKey: "level17"))
        XCTAssertEqual(seen.value.last?.1, DependencyOf(type: .variable, variableKey: "level0"))
        XCTAssertEqual(sdk.getVariableInteger(previous), 1)
        XCTAssertEqual(seen.value.count, 38)
    }

    func testFeatureDiamondMemoIsBounded() throws {
        var features: [String: [String: Any]] = [:]
        var previous = "leaf"
        let enabled: [String: Any] = ["bucketBy": "userId", "traffic": [["key": "all", "segments": "*", "percentage": 100000]]]
        features[previous] = enabled
        for index in 0..<18 {
            var feature = enabled
            feature["requiredFeatures"] = [previous, previous]
            features["level\(index)"] = feature
            previous = "level\(index)"
        }
        let reads = ConcurrencyBox(0)
        let module = FeaturevisorModule(name: "count", beforeEvaluation: { options in
            reads.mutate { $0 += 1 }
            return options
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile([:], features: features), modules: [module]))
        XCTAssertTrue(sdk.isEnabled(previous))
        XCTAssertEqual(reads.value, 19)
    }

    func testTwoNodePerLevelGraphMemoIsBoundedByEdges() throws {
        var variables: [String: [String: Any]] = ["leafA": variable(), "leafB": variable()]
        var left = "leafA"
        var right = "leafB"
        for index in 0..<18 {
            let nextLeft = "a\(index)"
            let nextRight = "b\(index)"
            let requirements = [requirement(left), requirement(right)]
            variables[nextLeft] = variable(requirements)
            variables[nextRight] = variable(requirements)
            left = nextLeft
            right = nextRight
        }
        variables["root"] = variable([requirement(left), requirement(right)])
        let before = ConcurrencyBox(0)
        let after = ConcurrencyBox(0)
        let module = FeaturevisorModule(name: "bounded", beforeEvaluation: { options in
            before.mutate { $0 += 1 }
            return options
        }, afterEvaluation: { evaluation, _ in
            after.mutate { $0 += 1 }
            return evaluation
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), logLevel: .fatal, modules: [module]))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(before.value, 75)
        XCTAssertEqual(after.value, 75)
    }

    func testContextSnapshotKeepsIntegerAndDoubleDistinct() throws {
        let variables: [String: [String: Any]] = [
            "leaf": variable(),
            "a": variable([requirement("leaf", value: 1)]),
            "b": variable([requirement("leaf", value: 2)]),
            "root": variable([requirement("a"), requirement("b")]),
        ]
        let reads = ConcurrencyBox(0)
        let module = FeaturevisorModule(
            name: "typed-context",
            beforeEvaluation: { options in
                var updated = options
                if options.variableKey == "a" { updated.dependencies.context["number"] = .int(1) }
                if options.variableKey == "b" { updated.dependencies.context["number"] = .double(1) }
                return updated
            },
            afterEvaluation: { evaluation, options in
                guard evaluation.variableKey == "leaf" else { return evaluation }
                reads.mutate { $0 += 1 }
                var updated = evaluation
                updated.variableValue = options.dependencies.context["number"] == .int(1) ? .int(1) : .int(2)
                return updated
            }
        )
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), modules: [module]))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(reads.value, 2)
    }

    func testContextSnapshotKeepsSignedZeroDistinct() throws {
        let variables: [String: [String: Any]] = [
            "leaf": variable(value: 0),
            "negative": variable([requirement("leaf", value: 1)]),
            "positive": variable([requirement("leaf", value: 2)]),
            "root": variable([requirement("negative"), requirement("positive")]),
        ]
        let reads = ConcurrencyBox(0)
        let module = FeaturevisorModule(
            name: "signed-zero-context",
            beforeEvaluation: { options in
                var updated = options
                if options.variableKey == "negative" {
                    updated.dependencies.context["nested"] = .object(["number": .array([.double(-0.0)])])
                }
                if options.variableKey == "positive" {
                    updated.dependencies.context["nested"] = .object(["number": .array([.double(0.0)])])
                }
                return updated
            },
            afterEvaluation: { evaluation, options in
                guard evaluation.variableKey == "leaf" else { return evaluation }
                reads.mutate { $0 += 1 }
                var updated = evaluation
                if case .object(let object) = options.dependencies.context["nested"],
                   case .array(let array) = object["number"],
                   case .double(let number) = array.first {
                    updated.variableValue = .int(number.sign == .minus ? 1 : 2)
                }
                return updated
            }
        )
        let sdk = createFeaturevisor(FeaturevisorOptions(
            datafile: try datafile(variables), logLevel: .fatal, modules: [module]
        ))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(reads.value, 2)
    }

    func testSignedZeroContextsWithOneRequesterDoNotShareMemo() throws {
        let reads = ConcurrencyBox(0)
        let values = ConcurrencyBox<[AnyValue]>([])
        let module = FeaturevisorModule(name: "signed-zero-direct", beforeEvaluation: { options in
            guard options.variableKey == "root" else { return options }
            let identity = DependencyOf(type: .variable, variableKey: "leaf")
            var negative = options.dependencies
            negative.context["nested"] = .object(["number": .array([.double(-0.0)])])
            var positive = options.dependencies
            positive.context["nested"] = .object(["number": .array([.double(0.0)])])
            let first = try? options.dependencies.session.read(identity, dependencies: negative) { _ in
                reads.mutate { $0 += 1 }
                return .variable(.int(1))
            }
            let second = try? options.dependencies.session.read(identity, dependencies: positive) { _ in
                reads.mutate { $0 += 1 }
                return .variable(.int(2))
            }
            for result in [first, second] {
                if case .variable(let value) = result { values.mutate { $0.append(value) } }
            }
            return options
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(
            datafile: try datafile(["root": variable()]), logLevel: .fatal, modules: [module]
        ))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(values.value, [.int(1), .int(2)])
    }

    func testNonfiniteAndOversizedContextsBypassMemo() throws {
        var deeplyNested: AnyValue = .int(1)
        for _ in 0..<65 { deeplyNested = .array([deeplyNested]) }
        let cases: [(String, AnyValue)] = [
            ("nan", .double(.nan)),
            ("infinity", .double(.infinity)),
            ("deep", deeplyNested),
            ("wide", .array(Array(repeating: .int(1), count: 4096))),
        ]
        let variables = ["leaf": variable(), "root": variable([requirement("leaf"), requirement("leaf")])]
        for (name, value) in cases {
            let reads = ConcurrencyBox(0)
            let session = ConcurrencyBox<EvaluationSession?>(nil)
            let module = FeaturevisorModule(name: "count", beforeEvaluation: { options in
                if options.variableKey == "leaf" {
                    reads.mutate { $0 += 1 }
                    session.value = options.dependencies.session
                }
                return options
            })
            let sdk = createFeaturevisor(FeaturevisorOptions(
                datafile: try datafile(variables), context: ["input": value],
                logLevel: .fatal, modules: [module]
            ))
            XCTAssertEqual(sdk.getVariableInteger("root"), 1, name)
            XCTAssertEqual(reads.value, 2, name)
            XCTAssertEqual(session.value?.workCounts.keys, 2, name)
            XCTAssertEqual(session.value?.workCounts.entries, 0, name)
            sdk.close()
        }
    }

    func testCallbackStateChangePreventsMemoStoreAfterEvaluation() throws {
        let variables = [
            "leaf": variable(),
            "root": variable([requirement("leaf", value: 1), requirement("leaf", value: 2)]),
        ]
        let sdkBox = ConcurrencyBox<Featurevisor?>(nil)
        let reads = ConcurrencyBox(0)
        let session = ConcurrencyBox<EvaluationSession?>(nil)
        let module = FeaturevisorModule(name: "change-owner", afterEvaluation: { evaluation, options in
            guard evaluation.variableKey == "leaf" else { return evaluation }
            session.value = options.dependencies.session
            reads.mutate { $0 += 1 }
            if reads.value == 1 { sdkBox.value?.setStickyVariables(["leaf": .int(2)]) }
            return evaluation
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(
            datafile: try datafile(variables), logLevel: .fatal,
            stickyVariables: ["leaf": .int(1)], modules: [module]
        ))
        sdkBox.value = sdk
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(session.value?.workCounts.keys, 2)
        XCTAssertEqual(session.value?.workCounts.entries, 1)
    }

    func testRootHookContextReplacementIsInheritedWithoutInstanceRemerge() throws {
        let variables = ["leaf": variable(), "root": variable([requirement("leaf")])]
        let module = FeaturevisorModule(
            name: "replace-context",
            beforeEvaluation: { options in
                guard options.variableKey == "root" else { return options }
                var updated = options
                updated.dependencies.context = [:]
                return updated
            },
            afterEvaluation: { evaluation, options in
                guard evaluation.variableKey == "leaf" else { return evaluation }
                var updated = evaluation
                updated.variableValue = options.dependencies.context["country"] == nil ? .int(1) : .int(2)
                return updated
            }
        )
        let sdk = createFeaturevisor(FeaturevisorOptions(
            datafile: try datafile(variables), context: ["country": .string("de")], modules: [module]
        ))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
    }

    func testKnownStickyFeatureSnapshotRetainsDiamondMemo() throws {
        let variables = ["leaf": variable(), "root": variable([requirement("leaf"), requirement("leaf")])]
        let reads = ConcurrencyBox(0)
        let module = FeaturevisorModule(name: "count", beforeEvaluation: { options in
            if options.variableKey == "leaf" { reads.mutate { $0 += 1 } }
            return options
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(
            datafile: try datafile(variables),
            stickyFeatures: ["unrelated": EvaluatedFeature(enabled: true, variables: ["nested": .object(["number": .int(1)])])],
            modules: [module]
        ))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(reads.value, 1)
    }

    func testNestedContextsHaveDifferentMemoKeys() throws {
        let variables: [String: [String: Any]] = [
            "leaf": ["type": "string", "defaultValue": "base"],
            "a": ["type": "string", "defaultValue": "ready", "conditions": [requirement("leaf", value: "nl")]],
            "b": ["type": "string", "defaultValue": "ready", "conditions": [requirement("leaf", value: "de")]],
            "root": ["type": "string", "defaultValue": "done", "conditions": [requirement("a", value: "ready"), requirement("b", value: "ready")]],
        ]
        let leafReads = ConcurrencyBox(0)
        let module = FeaturevisorModule(
            name: "contexts",
            beforeEvaluation: { options in
                var updated = options
                if options.variableKey == "a" { updated.dependencies.context = ["country": .string("nl")] }
                if options.variableKey == "b" { updated.dependencies.context = ["country": .string("de")] }
                return updated
            },
            afterEvaluation: { evaluation, options in
                guard evaluation.variableKey == "leaf" else { return evaluation }
                leafReads.mutate { $0 += 1 }
                var updated = evaluation
                updated.variableValue = options.dependencies.context["country"]
                return updated
            }
        )
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), modules: [module]))
        XCTAssertEqual(sdk.getVariableString("root"), "done")
        XCTAssertEqual(leafReads.value, 2)
    }

    func testRequesterAwareMemoKeepsHookResultsSeparateByImmediateParent() throws {
        let variables: [String: [String: Any]] = [
            "leaf": variable(value: 0),
            "a": variable([requirement("leaf", value: 1), requirement("leaf", value: 1)]),
            "b": variable([requirement("leaf", value: 2), requirement("leaf", value: 2)]),
            "root": variable([requirement("a"), requirement("b")]),
        ]
        let reads = ConcurrencyBox(0)
        let module = FeaturevisorModule(name: "requester", afterEvaluation: { evaluation, options in
            guard evaluation.variableKey == "leaf" else { return evaluation }
            reads.mutate { $0 += 1 }
            var updated = evaluation
            updated.variableValue = options.dependencyOf?.variableKey == "a" ? .int(1) : .int(2)
            return updated
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), modules: [module]))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(reads.value, 2)
    }

    func testDependencyMetadataDistinguishesAllGetterKinds() throws {
        let features: [String: [String: Any]] = [
            "source": [
                "bucketBy": "userId",
                "variations": [["value": "beta", "variables": ["count": 1]]],
                "variablesSchema": ["count": ["type": "integer", "defaultValue": 1]],
                "traffic": [["key": "all", "segments": "*", "percentage": 100000, "variation": "beta"]],
            ],
        ]
        let variables: [String: [String: Any]] = [
            "global": variable(),
            "root": ["type": "integer", "defaultValue": 1,
                     "requiredFeatures": [["feature": "source", "enabled": true, "variation": "beta"]],
                     "conditions": [
                        ["feature": "source", "variable": "count", "operator": "equals", "value": 1],
                        requirement("global"),
                     ]],
        ]
        let seen = ConcurrencyBox<[(DependencyOf, DependencyOf?)]>([])
        let module = FeaturevisorModule(name: "metadata", beforeEvaluation: { options in
            seen.mutate { $0.append((DependencyOf(options), options.dependencyOf)) }
            return options
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables, features: features), modules: [module]))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        let requester = DependencyOf(type: .variable, variableKey: "root")
        XCTAssertEqual(Set(seen.value.dropFirst().map(\.0)), Set([
            DependencyOf(type: .flag, featureKey: "source"),
            DependencyOf(type: .variation, featureKey: "source"),
            DependencyOf(type: .variable, featureKey: "source", variableKey: "count"),
            DependencyOf(type: .variable, variableKey: "global"),
        ]))
        XCTAssertTrue(seen.value.dropFirst().allSatisfy { $0.1 == requester })
        XCTAssertNil(seen.value.first?.1)
    }

    func testRedirectedRootCycleChecksOriginalAndCurrentIdentities() throws {
        let variables = [
            "a": variable(),
            "b": variable([requirement("a")]),
        ]
        let originalReads = ConcurrencyBox(0)
        let module = FeaturevisorModule(name: "redirect", beforeEvaluation: { options in
            guard options.variableKey == "a" else { return options }
            originalReads.mutate { $0 += 1 }
            var updated = options
            updated.variableKey = "b"
            return updated
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), logLevel: .fatal, modules: [module]))
        XCTAssertEqual(sdk.evaluateVariable("a").reason, .error)
        XCTAssertEqual(originalReads.value, 1)
    }

    func testNestedInvalidRequirementPathCannotBecomeNullGetter() throws {
        let variables: [String: [String: Any]] = [
            "leaf": ["type": "object", "defaultValue": [:] as [String: Any]],
            "bad": variable([["variable": "leaf", "path": ["__proto__"], "operator": "notExists"]]),
            "root": variable([["variable": "bad", "operator": "isNull"]]),
        ]
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), logLevel: .fatal))
        XCTAssertEqual(sdk.evaluateVariable("root").reason, .error)
    }

    func testCyclesPropagateButHandledModuleOutcomesCanMatch() throws {
        let features: [String: [String: Any]] = [
            "gate": ["bucketBy": "userId", "conditions": [["variable": "source", "operator": "notNull"]], "traffic": [["key": "all", "segments": "*", "percentage": 100000]]],
            "broken": ["bucketBy": "userId", "traffic": []],
            "disabledGate": ["bucketBy": "userId", "requiredFeatures": [["feature": "broken", "enabled": false], ["not": ["broken"]]], "traffic": [["key": "all", "segments": "*", "percentage": 100000]]],
        ]
        let variables: [String: [String: Any]] = [
            "source": ["type": "integer", "defaultValue": 1, "requiredFeatures": ["gate"]],
            "nilGate": ["type": "integer", "defaultValue": 1, "conditions": [["variable": "missing", "operator": "isNull"], ["variable": "missing", "operator": "isNull"]]],
        ]
        let brokenReads = ConcurrencyBox(0)
        let missingReads = ConcurrencyBox(0)
        let module = FeaturevisorModule(name: "error", afterEvaluation: { evaluation, _ in
            if evaluation.variableKey == "missing" { missingReads.mutate { $0 += 1 } }
            guard evaluation.type == .flag, evaluation.featureKey == "broken" else { return evaluation }
            brokenReads.mutate { $0 += 1 }
            var failed = evaluation
            failed.reason = .error
            failed.enabled = nil
            return failed
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables, features: features), logLevel: .fatal, modules: [module]))
        XCTAssertEqual(sdk.evaluateFlag("gate").reason, .error)
        XCTAssertEqual(sdk.evaluateVariable("source").reason, .error)
        XCTAssertTrue(sdk.isEnabled("disabledGate"))
        XCTAssertEqual(sdk.getVariableInteger("nilGate"), 1)
        XCTAssertEqual(brokenReads.value, 1)
        XCTAssertEqual(missingReads.value, 1)
    }

    func testReentrantPublicCallsAndChildStickyUseSeparateSessions() throws {
        let variables = [
            "leaf": variable(),
            "root": variable([requirement("leaf"), requirement("leaf")]),
        ]
        let sdkBox = ConcurrencyBox<Featurevisor?>(nil)
        let nested = ConcurrencyBox(false)
        let reads = ConcurrencyBox(0)
        let roots = ConcurrencyBox<[DependencyOf?]>([])
        let module = FeaturevisorModule(name: "reentrant", beforeEvaluation: { options in
            if options.variableKey == "root" { roots.mutate { $0.append(options.dependencyOf) } }
            if options.variableKey == "leaf" {
                reads.mutate { $0 += 1 }
                if !nested.value {
                    nested.value = true
                    _ = sdkBox.value?.getVariableInteger("root")
                    nested.value = false
                }
            }
            return options
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), stickyVariables: ["leaf": .int(0)], modules: [module]))
        sdkBox.value = sdk
        let child = sdk.spawn(options: SpawnOptions(stickyVariables: ["leaf": .int(1)]))
        XCTAssertEqual(child.getVariableInteger("root"), 1)
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(roots.value.count, 2)
        XCTAssertTrue(roots.value.allSatisfy { $0 == nil })
        XCTAssertEqual(sdk.getVariableInteger("root"), nil)
        child.setStickyVariables(["leaf": .int(0)])
        XCTAssertNil(child.getVariableInteger("root"))
        child.setStickyVariables(["leaf": .int(1)])
        XCTAssertEqual(child.getVariableInteger("root"), 1)
    }

    func testModuleRegistrationAndRestorationCannotReuseEarlierMemo() throws {
        let variables = [
            "leaf": variable(),
            "mutator": variable(),
            "root": variable([requirement("leaf"), requirement("mutator"), requirement("leaf")]),
        ]
        let sdkBox = ConcurrencyBox<Featurevisor?>(nil)
        let reads = ConcurrencyBox(0)
        let module = FeaturevisorModule(name: "mutate-registration", afterEvaluation: { evaluation, _ in
            if evaluation.variableKey == "leaf" { reads.mutate { $0 += 1 } }
            if evaluation.variableKey == "mutator" {
                let remove = sdkBox.value?.addModule(FeaturevisorModule(name: "temporary"))
                remove?()
            }
            return evaluation
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), logLevel: .fatal, modules: [module]))
        sdkBox.value = sdk
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(reads.value, 2)
    }

    func testRootAndChildStickySetterRefreshPrerequisitesIncludingRestoration() throws {
        for childMode in [false, true] {
            let variables = [
                "leaf": variable(),
                "mutator": variable(),
                "root": variable([requirement("leaf", value: 1), requirement("mutator"), requirement("leaf", value: 2)]),
            ]
            let sdkBox = ConcurrencyBox<Featurevisor?>(nil)
            let childBox = ConcurrencyBox<FeaturevisorChildInstance?>(nil)
            let reads = ConcurrencyBox(0)
            let module = FeaturevisorModule(name: "sticky-transition", afterEvaluation: { evaluation, _ in
                if evaluation.variableKey == "leaf" { reads.mutate { $0 += 1 } }
                if evaluation.variableKey == "mutator" {
                    if childMode { childBox.value?.setStickyVariables(["leaf": .int(2)]) }
                    else { sdkBox.value?.setStickyVariables(["leaf": .int(2)]) }
                }
                return evaluation
            })
            let sdk = createFeaturevisor(FeaturevisorOptions(
                datafile: try datafile(variables), logLevel: .fatal,
                stickyVariables: ["leaf": .int(1)], modules: [module]
            ))
            sdkBox.value = sdk
            let child = sdk.spawn(options: SpawnOptions(stickyVariables: ["leaf": .int(1)]))
            childBox.value = child
            XCTAssertEqual(childMode ? child.getVariableInteger("root") : sdk.getVariableInteger("root"), 1)
            XCTAssertEqual(reads.value, 2)
        }

        let variables = [
            "leaf": variable(), "mutator": variable(),
            "root": variable([requirement("leaf"), requirement("mutator"), requirement("leaf")]),
        ]
        let sdkBox = ConcurrencyBox<Featurevisor?>(nil)
        let reads = ConcurrencyBox(0)
        let module = FeaturevisorModule(name: "restore", afterEvaluation: { evaluation, _ in
            if evaluation.variableKey == "leaf" { reads.mutate { $0 += 1 } }
            if evaluation.variableKey == "mutator" {
                sdkBox.value?.setStickyVariables(["leaf": .int(2)])
                sdkBox.value?.setStickyVariables(["leaf": .int(1)])
            }
            return evaluation
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), logLevel: .fatal, stickyVariables: ["leaf": .int(1)], modules: [module]))
        sdkBox.value = sdk
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(reads.value, 2)
    }

    func testGlobalStickySetterInBeforeHookIsVisibleToGetter() throws {
        let sdkBox = ConcurrencyBox<Featurevisor?>(nil)
        let module = FeaturevisorModule(name: "before-sticky", beforeEvaluation: { options in
            if options.variableKey == "root" { sdkBox.value?.setStickyVariables(["root": .int(2)]) }
            return options
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(["root": variable()]), logLevel: .fatal, modules: [module]))
        sdkBox.value = sdk
        XCTAssertEqual(sdk.getVariableInteger("root"), 2)
    }

    func testStickySetterRefreshesEveryDependencyKindForRootAndChild() throws {
        let enabled: [String: Any] = [
            "bucketBy": "userId",
            "traffic": [["key": "all", "segments": "*", "percentage": 100000]],
        ]
        for kind in ["flag", "variation", "featureVariable", "globalVariable"] {
            for childMode in [false, true] {
                var features: [String: [String: Any]] = [:]
                var variables: [String: [String: Any]] = [:]
                let first: Any
                let last: Any
                if kind == "flag" || kind == "variation" {
                    var leaf = enabled
                    leaf["variations"] = [["value": "beta"], ["value": "gamma"]]
                    features["leaf"] = leaf
                    features["mutator"] = enabled
                    if kind == "flag" {
                        first = ["feature": "leaf", "enabled": true]
                        last = ["feature": "leaf", "enabled": false]
                    } else {
                        first = ["feature": "leaf", "variation": "beta"]
                        last = ["feature": "leaf", "variation": "gamma"]
                    }
                    var root = enabled
                    root["requiredFeatures"] = [first, "mutator", last]
                    features["root"] = root
                } else {
                    variables["mutator"] = variable()
                    if kind == "featureVariable" {
                        var leaf = enabled
                        leaf["variablesSchema"] = ["count": ["type": "integer", "defaultValue": 0]]
                        features["leaf"] = leaf
                        first = ["feature": "leaf", "variable": "count", "operator": "equals", "value": 1]
                        last = ["feature": "leaf", "variable": "count", "operator": "equals", "value": 2]
                    } else {
                        variables["leaf"] = variable(value: 0)
                        first = requirement("leaf", value: 1)
                        last = requirement("leaf", value: 2)
                    }
                    variables["root"] = [
                        "type": "integer", "defaultValue": 1,
                        "conditions": [first, requirement("mutator"), last],
                    ]
                }
                let initialFeature = EvaluatedFeature(enabled: true, variation: "beta", variables: ["count": .int(1)])
                let changedFeature = EvaluatedFeature(enabled: kind != "flag", variation: "gamma", variables: ["count": .int(2)])
                let sdkBox = ConcurrencyBox<Featurevisor?>(nil)
                let childBox = ConcurrencyBox<FeaturevisorChildInstance?>(nil)
                let reads = ConcurrencyBox(0)
                let module = FeaturevisorModule(name: "kind-transition", afterEvaluation: { evaluation, _ in
                    if evaluation.featureKey == "leaf" || (kind == "globalVariable" && evaluation.variableKey == "leaf") {
                        if (kind == "flag" && evaluation.type == .flag)
                            || (kind == "variation" && evaluation.type == .variation)
                            || ((kind == "featureVariable" || kind == "globalVariable") && evaluation.type == .variable) {
                            reads.mutate { $0 += 1 }
                        }
                    }
                    if evaluation.featureKey == "mutator" || evaluation.variableKey == "mutator" {
                        if childMode {
                            childBox.value?.setStickyFeatures(["leaf": changedFeature])
                            childBox.value?.setStickyVariables(["leaf": .int(2)])
                        } else {
                            sdkBox.value?.setStickyFeatures(["leaf": changedFeature])
                            sdkBox.value?.setStickyVariables(["leaf": .int(2)])
                        }
                    }
                    return evaluation
                })
                let sdk = createFeaturevisor(FeaturevisorOptions(
                    datafile: try datafile(variables, features: features), logLevel: .fatal,
                    stickyFeatures: ["leaf": initialFeature], stickyVariables: ["leaf": .int(1)], modules: [module]
                ))
                sdkBox.value = sdk
                let child = sdk.spawn(options: SpawnOptions(
                    stickyFeatures: ["leaf": initialFeature], stickyVariables: ["leaf": .int(1)]
                ))
                childBox.value = child
                if kind == "flag" || kind == "variation" {
                    XCTAssertTrue(childMode ? child.isEnabled("root") : sdk.isEnabled("root"), "\(kind), child=\(childMode)")
                } else {
                    XCTAssertEqual(childMode ? child.getVariableInteger("root") : sdk.getVariableInteger("root"), 1, "\(kind), child=\(childMode)")
                }
                XCTAssertEqual(reads.value, 2, "\(kind), child=\(childMode)")
            }
        }
    }

    func testRedirectedDependencyMayEqualAncestorWithoutAnotherRead() throws {
        let variables = ["root": variable([requirement("leaf")]), "leaf": variable()]
        let module = FeaturevisorModule(name: "redirect-to-sticky", beforeEvaluation: { options in
            guard options.variableKey == "leaf" else { return options }
            var redirected = options
            redirected.variableKey = "root"
            redirected.dependencies.stickyVariables = ["root": .int(1)]
            return redirected
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try datafile(variables), logLevel: .fatal, modules: [module]))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
    }

    func testRetainedModuleOptionsDoNotKeepStickySourceOrActiveRequest() throws {
        let retained = ConcurrencyBox<EvaluateOptions?>(nil)
        let module = FeaturevisorModule(name: "retain", beforeEvaluation: { options in
            if options.variableKey == "leaf" { retained.value = options }
            return options
        })
        let sdk = createFeaturevisor(FeaturevisorOptions(
            datafile: try datafile(["root": variable([requirement("leaf")]), "leaf": variable()]),
            logLevel: .fatal, modules: [module]
        ))
        XCTAssertEqual(sdk.getVariableInteger("root"), 1)
        XCTAssertEqual(retained.value?.dependencyOf, DependencyOf(type: .variable, variableKey: "root"))
        XCTAssertNil(retained.value?.dependencies.stickySource?.current())
        XCTAssertNil(retained.value?.dependencies.session.current())
    }
}
