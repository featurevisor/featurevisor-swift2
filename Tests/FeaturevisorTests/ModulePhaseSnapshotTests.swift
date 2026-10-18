import Foundation
import XCTest

@testable import Featurevisor

final class ModulePhaseSnapshotTests: XCTestCase {
    func testMembershipSnapshotsShareStorageUntilMutationIncludingWhenEmpty() {
        let manager = ModulesManager(
            modules: [], reportDiagnostic: { _, _ in },
            getModuleApi: { _ in
                FeaturevisorModuleApi(getRevision: { "phase" }, onDiagnostic: { _, _ in {} }, reportDiagnostic: { _ in })
            }, clearModuleDiagnosticSubscriptions: { _ in })
        for installed in [false, true] {
            if installed { _ = manager.add(FeaturevisorModule(name: "first")) }
            let first = manager.getAll()
            let second = manager.getAll()
            first.withUnsafeBufferPointer { lhs in
                second.withUnsafeBufferPointer { rhs in
                    XCTAssertEqual(lhs.baseAddress, rhs.baseAddress)
                }
            }
            _ = manager.add(FeaturevisorModule(name: "next"))
            XCTAssertEqual(first.compactMap(\.name), installed ? ["first"] : [])
            manager.remove("next")
            manager.remove("first")
            XCTAssertTrue(manager.getAll().isEmpty)
        }
    }

    private func module(
        _ name: String, trace: ConcurrencyBox<[String]>,
        action: @escaping @Sendable (String) -> Void = { _ in },
        close: (@Sendable () throws -> Void)? = nil
    ) -> FeaturevisorModule {
        FeaturevisorModule(
            name: name,
            beforeEvaluation: { options in
                trace.mutate { $0.append("\(name):before") }
                action("before")
                return options
            },
            bucketKey: { options in
                trace.mutate { $0.append("\(name):key") }
                action("key")
                return options.bucketKey
            },
            bucketValue: { options in
                trace.mutate { $0.append("\(name):value") }
                action("value")
                return options.bucketValue
            },
            afterEvaluation: { evaluation, _ in
                trace.mutate { $0.append("\(name):after") }
                action("after")
                return evaluation
            }, close: close)
    }

    func testEveryPhaseUsesStartingMembershipForFeatureAndGlobalEvaluations() throws {
        let raw = try DatafileContent.fromData(JSONSerialization.data(withJSONObject: [
            "schemaVersion": "4", "revision": "phase", "segments": [:],
            "features": ["subject": ["bucketBy": "userId", "traffic": [
                ["key": "all", "conditions": "*", "percentage": 100000]
            ]]],
            "variables": ["subject": ["type": "string", "defaultValue": "ok"]],
        ]))
        for global in [false, true] {
            let phases = global ? ["before", "after"] : ["before", "key", "value", "after"]
            for (targetIndex, target) in phases.enumerated() {
                for mode in ["add", "removeAdd", "remove"] {
                    let trace = ConcurrencyBox<[String]>([])
                    let owner = ConcurrencyBox<Featurevisor?>(nil)
                    let changed = ConcurrencyBox(false)
                    let closed = ConcurrencyBox(0)
                    let late = module("late", trace: trace)
                    let actor = module("actor", trace: trace, action: { phase in
                        guard phase == target, !changed.value else { return }
                        changed.value = true
                        if mode != "add" { owner.value?.removeModule("other") }
                        if mode != "remove" { _ = owner.value?.addModule(late) }
                    })
                    let other = module("other", trace: trace, close: { closed.mutate { $0 += 1 } })
                    let sdk = createFeaturevisor(FeaturevisorOptions(datafile: raw, logLevel: .fatal, modules: [actor, other]))
                    owner.value = sdk
                    var expected: [String] = []
                    for (index, phase) in phases.enumerated() {
                        expected.append("actor:\(phase)")
                        if index <= targetIndex || mode == "add" { expected.append("other:\(phase)") }
                        if index > targetIndex && mode != "remove" { expected.append("late:\(phase)") }
                    }
                    for pass in 0..<2 {
                        let result = global ? sdk.evaluateVariable("subject") : sdk.evaluateFlag("subject", context: ["userId": .string("u")])
                        if global { XCTAssertEqual(result.variableValue, .string("ok")) }
                        else { XCTAssertEqual(result.enabled, true) }
                        XCTAssertEqual(trace.value, expected, "\(global)/\(target)/\(mode)/\(pass)")
                        XCTAssertEqual(closed.value, mode == "add" ? 0 : 1)
                        trace.value = []
                        expected = []
                        for phase in phases {
                            expected.append("actor:\(phase)")
                            if mode == "add" { expected.append("other:\(phase)") }
                            if mode != "remove" { expected.append("late:\(phase)") }
                        }
                    }
                    sdk.close()
                    XCTAssertEqual(closed.value, 1)
                    owner.value = nil
                }
            }
        }
    }
}
