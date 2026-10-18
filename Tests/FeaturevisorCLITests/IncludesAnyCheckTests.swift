import XCTest
import Featurevisor
@testable import FeaturevisorCLI

private final class IncludesAnyResolver: CheckVariableResolver {
    let actual: AnyValue
    let candidates: AnyValue
    init(_ actual: AnyValue, _ candidates: AnyValue) { self.actual = actual; self.candidates = candidates }
    func checkGlobalVariable(_ key: String) throws -> AnyValue? {
        key == "subject" ? .object(["items": actual]) : candidates
    }
    func checkFeatureVariable(_: String, _: String) throws -> AnyValue? { .object(["items": actual]) }
    func checkFeatureEnabled(_: String) throws -> Bool { false }
    func checkFeatureVariation(_: String) throws -> String? { nil }
}

final class IncludesAnyCheckTests: XCTestCase {
    func testLiteralCompareToAndStructuredErrors() throws {
        let rows = try JSONSerialization.jsonObject(with: Data(#"[{"name":"mixed","actual":["red",1,true,null],"candidates":["absent",1],"valid":true,"found":true},{"name":"null","actual":[null],"candidates":[null],"valid":true,"found":true},{"name":"boolean","actual":[false],"candidates":[false],"valid":true,"found":true},{"name":"number not bool","actual":[1],"candidates":[true],"valid":true,"found":false},{"name":"bool not number","actual":[true],"candidates":[1],"valid":true,"found":false},{"name":"string not number","actual":["1"],"candidates":[1],"valid":true,"found":false},{"name":"string not bool","actual":["true"],"candidates":[true],"valid":true,"found":false},{"name":"duplicates","actual":["red","red"],"candidates":["blue","red","red"],"valid":true,"found":true},{"name":"empty actual","actual":[],"candidates":[null],"valid":true,"found":false},{"name":"empty candidate","actual":[1],"candidates":[],"valid":true,"found":false},{"name":"both empty","actual":[],"candidates":[],"valid":true,"found":false},{"name":"structured actual","actual":[{},[1],"red"],"candidates":["red"],"valid":true,"found":true},{"name":"structured ignored","actual":[{},[1]],"candidates":[null,1],"valid":true,"found":false},{"name":"object after match","actual":[1],"candidates":[1,{}],"valid":false,"found":false},{"name":"array after match","actual":[1],"candidates":[1,[]],"valid":false,"found":false},{"name":"object first","actual":[1],"candidates":[{},1],"valid":false,"found":false},{"name":"null actual","actual":null,"candidates":[],"valid":false,"found":false},{"name":"object actual","actual":{},"candidates":[],"valid":false,"found":false},{"name":"scalar actual","actual":"red","candidates":["red"],"valid":false,"found":false},{"name":"null candidates","actual":[],"candidates":null,"valid":false,"found":false},{"name":"scalar candidates","actual":["red"],"candidates":"red","valid":false,"found":false},{"name":"object candidates","actual":[],"candidates":{},"valid":false,"found":false}]"#.utf8)) as! [[String: Any]]
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"checks","segments":{},"features":{},"variables":{"subject":{"type":"object","defaultValue":{}},"other":{"type":"array","defaultValue":[]}}}"#)
        for row in rows {
            let actual = try JSONDecoder().decode(AnyValue.self, from: JSONSerialization.data(withJSONObject: row["actual"]!, options: [.fragmentsAllowed]))
            let candidates = try JSONDecoder().decode(AnyValue.self, from: JSONSerialization.data(withJSONObject: row["candidates"]!, options: [.fragmentsAllowed]))
            let resolver = IncludesAnyResolver(actual, candidates)
            let valid = row["valid"] as! Bool
            let found = row["found"] as! Bool
            for op in ["includesAny", "notIncludesAny"] {
                for compareTo in [false, true] {
                    var leaf: [String: Any] = ["variable": "subject", "path": "items", "operator": op]
                    if compareTo { leaf["compareTo"] = ["variable": "other"] }
                    else { leaf["value"] = row["candidates"] }
                    let result = evaluateAssertionChecksDetailed(["checks": [leaf]], ownerVariable: nil, resolver: resolver, datafile: datafile)
                    let want = valid && (found == (op == "includesAny"))
                    let label = "\(row["name"]!) \(op) compareTo=\(compareTo)"
                    XCTAssertEqual(result.hadError, !valid, label)
                    XCTAssertEqual(result.failures.isEmpty, want, label)
                    if !valid {
                        XCTAssertFalse(result.reportErrors.isEmpty, label)
                        for group in ["not", "or"] {
                            let result = evaluateAssertionChecksDetailed(["checks": [[group: [leaf]]]], ownerVariable: nil, resolver: resolver, datafile: datafile)
                            XCTAssertTrue(result.hadError, label + group)
                            XCTAssertFalse(result.failures.isEmpty, label + group)
                        }
                    }
                }
            }
        }
    }

    func testMissingPathsAndSkippedOperands() throws {
        let datafile = try DatafileContent.fromJSON(#"{"schemaVersion":"2","revision":"checks","segments":{},"features":{},"variables":{"subject":{"type":"object","defaultValue":{}},"other":{"type":"object","defaultValue":{}}}}"#)
        let resolver = IncludesAnyResolver(.object([:]), .object([:]))
        for op in ["includesAny", "notIncludesAny"] {
            let missing: [String: Any] = ["variable": "subject", "path": "missing", "operator": op, "value": [] as [Any]]
            let result = evaluateAssertionChecksDetailed(["checks": [missing]], ownerVariable: nil, resolver: resolver, datafile: datafile)
            XCTAssertFalse(result.hadError)
            XCTAssertFalse(result.failures.isEmpty)
            let skipped: [String: Any] = ["or": [
                ["variable": "subject", "operator": "exists"],
                ["variable": "subject", "operator": op, "compareTo": ["variable": "other"]],
            ]]
            let skipResult = evaluateAssertionChecksDetailed(["checks": [skipped]], ownerVariable: nil, resolver: resolver, datafile: datafile)
            XCTAssertFalse(skipResult.hadError)
            XCTAssertTrue(skipResult.failures.isEmpty)
        }
    }
}
