import XCTest
@testable import Featurevisor

final class DeprecationDiagnosticsTests: XCTestCase {
    func testReportsDeprecatedFeaturesAndVariablesWithOneCodePerKind() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"4","revision":"1","segments":{},"features":{"legacy":{"deprecated":true,"bucketBy":"userId","variablesSchema":{"old":{"type":"string","defaultValue":"x","deprecated":true}},"traffic":[{"key":"all","conditions":"*","percentage":100000,"allocation":[]}]}},"variables":{"oldGlobal":{"type":"string","defaultValue":"y","deprecated":true}}}"#)
        let captured = ConcurrencyBox<[String]>([])
        let sdk = createFeaturevisor(FeaturevisorOptions(datafile: datafile, logLevel: .warn, onDiagnostic: { diagnostic in
            if diagnostic.code.contains("deprecated") { captured.mutate { $0.append(diagnostic.code) } }
        }))
        defer { sdk.close() }

        _ = sdk.isEnabled("legacy")
        XCTAssertEqual(Array(Set(captured.value)), ["deprecated_feature"])

        captured.value = []
        _ = sdk.getVariable("legacy", "old")
        XCTAssertEqual(Set(captured.value), ["deprecated_feature", "deprecated_variable"])

        captured.value = []
        _ = sdk.getVariable("oldGlobal")
        XCTAssertEqual(captured.value, ["deprecated_variable"])
    }
}
