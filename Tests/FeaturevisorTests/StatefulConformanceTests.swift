import Foundation
import XCTest
@testable import Featurevisor

final class StatefulConformanceTests: XCTestCase {
    private struct ObservedEvent: Equatable, Sendable {
        let target: String
        let name: String
        let details: [String: AnyValue]
    }

    private enum RuntimeTarget {
        case root(Featurevisor)
        case child(FeaturevisorChildInstance)

        func on(_ name: EventName, callback: @escaping EventCallback) -> FeaturevisorUnsubscribe {
            switch self {
            case .root(let value): return value.on(name, callback: callback)
            case .child(let value): return value.on(name, callback: callback)
            }
        }

        func isEnabled(_ key: String) -> Bool {
            switch self {
            case .root(let value): return value.isEnabled(key)
            case .child(let value): return value.isEnabled(key)
            }
        }

        func getVariable(_ arguments: [String]) -> AnyValue? {
            switch (self, arguments.count) {
            case (.root(let value), 1): return value.getVariable(arguments[0])
            case (.root(let value), 2): return value.getVariable(arguments[0], arguments[1])
            case (.child(let value), 1): return value.getVariable(arguments[0])
            case (.child(let value), 2): return value.getVariable(arguments[0], arguments[1])
            default: return nil
            }
        }

        func setStickyFeatures(_ values: StickyFeatures, replace: Bool) {
            switch self {
            case .root(let value): value.setStickyFeatures(values, replace: replace)
            case .child(let value): value.setStickyFeatures(values, replace: replace)
            }
        }

        func setStickyVariables(_ values: StickyVariables, replace: Bool) {
            switch self {
            case .root(let value): value.setStickyVariables(values, replace: replace)
            case .child(let value): value.setStickyVariables(values, replace: replace)
            }
        }
    }

    private func fixture() throws -> [String: Any] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("conformance/sdk-stateful.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func decode<T: Decodable>(_ value: Any, as: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(
            [T].self,
            from: JSONSerialization.data(withJSONObject: [value])
        )[0]
    }

    private static func normalized(_ details: [String: AnyValue]) -> [String: AnyValue] {
        var result = details
        for key in ["features", "variables"] {
            guard case .array(let values)? = result[key] else { continue }
            result[key] = .array(values.sorted {
                ($0.asString() ?? "") < ($1.asString() ?? "")
            })
        }
        return result
    }

    private func observe(
        _ targetName: String,
        target: RuntimeTarget,
        event: EventName,
        fixtureName: String,
        events: ConcurrencyBox<[ObservedEvent]>,
        unsubscribers: inout [FeaturevisorUnsubscribe]
    ) {
        unsubscribers.append(target.on(event) { payload in
            events.mutate {
                $0.append(ObservedEvent(
                    target: targetName,
                    name: fixtureName,
                    details: Self.normalized(payload.params)
                ))
            }
        })
    }

    func testExecutesCanonicalStatefulFixture() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture["kind"] as? String, "featurevisor.sdk-stateful")
        XCTAssertEqual(fixture["schemaVersion"] as? Int, 1)
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)

        for testCase in cases {
            let caseName = try XCTUnwrap(testCase["name"] as? String)
            let initial = try XCTUnwrap(testCase["initial"] as? [String: Any])
            let initialDatafile = try decode(
                XCTUnwrap(initial["datafile"]),
                as: DatafileContent.self
            )
            let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
            let root = createFeaturevisor(FeaturevisorOptions(
                datafile: initialDatafile,
                context: try decode(initial["context"] ?? [:], as: Context.self),
                logLevel: .error,
                onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }
            ))
            let events = ConcurrencyBox<[ObservedEvent]>([])
            var targets: [String: RuntimeTarget] = ["root": .root(root)]
            var children: [FeaturevisorChildInstance] = []
            var unsubscribers: [FeaturevisorUnsubscribe] = []
            observe("root", target: .root(root), event: .datafileSet, fixtureName: "datafile_set", events: events, unsubscribers: &unsubscribers)
            observe("root", target: .root(root), event: .stickyFeaturesSet, fixtureName: "sticky_features_set", events: events, unsubscribers: &unsubscribers)
            observe("root", target: .root(root), event: .stickyVariablesSet, fixtureName: "sticky_variables_set", events: events, unsubscribers: &unsubscribers)

            defer {
                unsubscribers.forEach { $0() }
                children.forEach { $0.close() }
                root.close()
            }

            for operation in try XCTUnwrap(testCase["operations"] as? [[String: Any]]) {
                let action = try XCTUnwrap(operation["action"] as? String)
                let label = "\(caseName): \(action)"
                events.value = []
                diagnostics.value = []

                switch action {
                case "setDatafile":
                    XCTAssertEqual(operation["target"] as? String, "root", label)
                    let replace = operation["replace"] as? Bool ?? false
                    if let json = operation["datafile"] as? String {
                        root.setDatafile(json: json, replace: replace)
                    } else {
                        root.setDatafile(
                            try decode(XCTUnwrap(operation["datafile"]), as: DatafileContent.self),
                            replace: replace
                        )
                    }
                case "spawn":
                    let parentName = try XCTUnwrap(operation["parent"] as? String)
                    XCTAssertEqual(parentName, "root", label)
                    let targetName = try XCTUnwrap(operation["target"] as? String)
                    let context = try decode(operation["context"] ?? [:], as: Context.self)
                    let options = operation["options"] as? [String: Any] ?? [:]
                    let child = root.spawn(context, options: SpawnOptions(
                        stickyFeatures: try options["stickyFeatures"].map { try decode($0, as: StickyFeatures.self) },
                        stickyVariables: try options["stickyVariables"].map { try decode($0, as: StickyVariables.self) }
                    ))
                    children.append(child)
                    targets[targetName] = .child(child)
                    observe(targetName, target: .child(child), event: .stickyFeaturesSet, fixtureName: "sticky_features_set", events: events, unsubscribers: &unsubscribers)
                    observe(targetName, target: .child(child), event: .stickyVariablesSet, fixtureName: "sticky_variables_set", events: events, unsubscribers: &unsubscribers)
                case "setStickyFeatures":
                    let target = try XCTUnwrap(targets[XCTUnwrap(operation["target"] as? String)])
                    target.setStickyFeatures(
                        try decode(XCTUnwrap(operation["stickyFeatures"]), as: StickyFeatures.self),
                        replace: operation["replace"] as? Bool ?? false
                    )
                case "setStickyVariables":
                    let target = try XCTUnwrap(targets[XCTUnwrap(operation["target"] as? String)])
                    target.setStickyVariables(
                        try decode(XCTUnwrap(operation["stickyVariables"]), as: StickyVariables.self),
                        replace: operation["replace"] as? Bool ?? false
                    )
                default:
                    XCTFail("\(label): unsupported fixture action")
                }

                let expectation = try XCTUnwrap(operation["expect"] as? [String: Any])
                for result in expectation["results"] as? [[String: Any]] ?? [] {
                    let targetName = try XCTUnwrap(result["target"] as? String)
                    let target = try XCTUnwrap(targets[targetName])
                    let method = try XCTUnwrap(result["method"] as? String)
                    let arguments = result["args"] as? [String] ?? []
                    let expected = try decode(XCTUnwrap(result["value"]), as: AnyValue.self)
                    let actual: AnyValue?
                    switch method {
                    case "isEnabled": actual = .bool(target.isEnabled(try XCTUnwrap(arguments.first)))
                    case "getRevision": actual = .string(root.getRevision())
                    case "getVariable": actual = target.getVariable(arguments)
                    default:
                        XCTFail("\(label): unsupported result method \(method)")
                        actual = nil
                    }
                    XCTAssertEqual(actual, expected, "\(label): \(targetName).\(method)")
                }

                let expectedEvents = try (expectation["events"] as? [[String: Any]] ?? []).map { item in
                    ObservedEvent(
                        target: try XCTUnwrap(item["target"] as? String),
                        name: try XCTUnwrap(item["name"] as? String),
                        details: Self.normalized(try decode(XCTUnwrap(item["details"]), as: [String: AnyValue].self))
                    )
                }
                XCTAssertEqual(events.value, expectedEvents, "\(label): events")

                if let expectedError = expectation["error"] as? [String: Any] {
                    let code = try XCTUnwrap(expectedError["code"] as? String)
                    XCTAssertTrue(diagnostics.value.contains { $0.code == code }, "\(label): diagnostic \(code)")
                } else {
                    XCTAssertFalse(diagnostics.value.contains { $0.level == .error }, "\(label): unexpected diagnostic")
                }
            }
        }
    }
}
