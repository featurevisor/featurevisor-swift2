import XCTest
@testable import Featurevisor

private let acceptedDatafileJSON = #"{"schemaVersion":"2","revision":"accepted","segments":{},"features":{"flag":{"key":"flag","hash":"stable","bucketBy":"userId","traffic":[{"key":"all","segments":"*","percentage":100000,"enabled":true}]}},"variables":{"colour":{"key":"colour","hash":"stable","type":"string","defaultValue":"blue"}}}"#

final class SetDatafileResultTests: XCTestCase {
    func testAcceptanceAcrossOverloadsAndModes() throws {
        let typed = try DatafileContent.fromJSON(acceptedDatafileJSON)
        let initial = try DatafileContent.fromJSON(acceptedDatafileJSON
            .replacingOccurrences(of: "flag", with: "retainedFlag")
            .replacingOccurrences(of: "colour", with: "retainedColour")
            .replacingOccurrences(of: "accepted", with: "initial"))
        for jsonInput in [false, true] {
            for replace: Bool? in [nil, false, true] {
                let diagnostics = ConcurrencyBox<[String]>([])
                let sdk = createFeaturevisor(FeaturevisorOptions(
                    datafile: initial,
                    onDiagnostic: { d in diagnostics.mutate { $0.append(d.code) } }
                ))
                defer { sdk.close() }
                let events = ConcurrencyBox<[EventPayload]>([])
                sdk.on(.datafileSet) { event in events.mutate { $0.append(event) } }
                let set: () -> Bool = {
                    if let replace {
                        return jsonInput
                            ? sdk.setDatafile(json: acceptedDatafileJSON, replace: replace)
                            : sdk.setDatafile(typed, replace: replace)
                    }
                    return jsonInput ? sdk.setDatafile(json: acceptedDatafileJSON) : sdk.setDatafile(typed)
                }
                XCTAssertTrue(set())
                XCTAssertTrue(set(), "Unchanged datafiles are still accepted")
                XCTAssertEqual(events.value.count, 2)
                let unchanged = try XCTUnwrap(events.value.last).params
                XCTAssertEqual(unchanged["revisionChanged"], .bool(false))
                XCTAssertEqual(unchanged["replaced"], .bool(replace ?? false))
                XCTAssertEqual(unchanged["features"], .array([]))
                XCTAssertEqual(unchanged["variables"], .array([]))
                XCTAssertEqual(diagnostics.value.last, "datafile_set")
                XCTAssertTrue(sdk.isEnabled("flag"))
                XCTAssertEqual(sdk.getVariableString("colour"), "blue")
                XCTAssertEqual(sdk.getFeature("retainedFlag") != nil, replace != true)
                XCTAssertEqual(sdk.getVariableString("retainedColour") != nil, replace != true)

                sdk.close()
                let before = diagnostics.value
                XCTAssertFalse(set())
                XCTAssertFalse(sdk.setDatafile(json: "{", replace: replace ?? false))
                XCTAssertEqual(diagnostics.value, before)
                XCTAssertEqual(events.value.count, 2)
                XCTAssertEqual(sdk.getRevision(), "accepted")
            }
        }
    }

    func testRejectionPreservesStateDiagnosticsAndEventBaseline() throws {
        for input in ["{", "null", "[]", "{}", #"{"schemaVersion":"2","revision":"bad","segments":{},"features":null}"#] {
            for replace in [false, true] {
                let diagnostics = ConcurrencyBox<[FeaturevisorDiagnostic]>([])
                let sdk = createFeaturevisor(FeaturevisorOptions(
                    datafile: try DatafileContent.fromJSON(acceptedDatafileJSON),
                    onDiagnostic: { d in diagnostics.mutate { $0.append(d) } }
                ))
                defer { sdk.close() }
                diagnostics.value = []
                let events = ConcurrencyBox<[EventPayload]>([])
                let errors = ConcurrencyBox(0)
                sdk.on(.datafileSet) { event in events.mutate { $0.append(event) } }
                sdk.on(.error) { _ in errors.mutate { $0 += 1 } }
                XCTAssertFalse(sdk.setDatafile(json: input, replace: replace))
                XCTAssertEqual(diagnostics.value.map(\.code), ["invalid_datafile"])
                XCTAssertNotNil(diagnostics.value.first?.originalError)
                XCTAssertEqual(errors.value, 1)
                XCTAssertTrue(events.value.isEmpty)
                XCTAssertEqual(sdk.getRevision(), "accepted")
                XCTAssertTrue(sdk.isEnabled("flag"))
                XCTAssertEqual(sdk.getVariableString("colour"), "blue")

                XCTAssertTrue(sdk.setDatafile(json: acceptedDatafileJSON, replace: replace))
                XCTAssertEqual(events.value.count, 1)
                let event = try XCTUnwrap(events.value.first).params
                XCTAssertEqual(event["previousRevision"], .string("accepted"))
                XCTAssertEqual(event["revisionChanged"], .bool(false))
                XCTAssertEqual(event["features"], .array([]))
                XCTAssertEqual(event["variables"], .array([]))
            }
        }
    }

    func testResultBelongsToItsOwnCallWhenListenersReenterOrClose() {
        let sdk = createFeaturevisor(FeaturevisorOptions(logLevel: .fatal))
        sdk.on(.datafileSet) { _ in
            XCTAssertFalse(sdk.setDatafile(json: "{"))
            sdk.close()
        }
        XCTAssertTrue(sdk.setDatafile(json: acceptedDatafileJSON))
        XCTAssertFalse(sdk.setDatafile(json: acceptedDatafileJSON))

        let recovered = createFeaturevisor(FeaturevisorOptions(logLevel: .fatal))
        defer { recovered.close() }
        recovered.on(.error) { _ in
            XCTAssertTrue(recovered.setDatafile(json: acceptedDatafileJSON))
        }
        XCTAssertFalse(recovered.setDatafile(json: "{"))
        XCTAssertEqual(recovered.getRevision(), "accepted")
    }

    func testDiagnosticCallbackCanCloseWithoutChangingAcceptance() {
        let reference = ConcurrencyBox<Featurevisor?>(nil)
        let sdk = createFeaturevisor(FeaturevisorOptions(onDiagnostic: { diagnostic in
            if diagnostic.code == "datafile_set" { reference.value?.close() }
        }))
        reference.value = sdk
        XCTAssertTrue(sdk.setDatafile(json: acceptedDatafileJSON))
        XCTAssertFalse(sdk.setDatafile(json: acceptedDatafileJSON))
        XCTAssertEqual(sdk.getRevision(), "accepted")
    }
}
