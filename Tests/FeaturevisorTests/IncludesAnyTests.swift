import XCTest
@testable import Featurevisor

final class IncludesAnyTests: XCTestCase {
    func testPrimitiveArrays() {
        let cases: [(String, AnyValue, AnyValue, Bool, Bool)] = [
            ("mixed", .array([.string("red"), .int(1), .bool(true), .null]), .array([.string("absent"), .double(1)]), true, true),
            ("null", .array([.null]), .array([.null]), true, true),
            ("boolean", .array([.bool(false)]), .array([.bool(false)]), true, true),
            ("number not boolean", .array([.int(1)]), .array([.bool(true)]), true, false),
            ("boolean not number", .array([.bool(true)]), .array([.int(1)]), true, false),
            ("string not number", .array([.string("1")]), .array([.int(1)]), true, false),
            ("string not boolean", .array([.string("true")]), .array([.bool(true)]), true, false),
            ("duplicates", .array([.string("red"), .string("red")]), .array([.string("blue"), .string("red"), .string("red")]), true, true),
            ("empty actual", .array([]), .array([.null]), true, false),
            ("empty candidates", .array([.int(1)]), .array([]), true, false),
            ("both empty", .array([]), .array([]), true, false),
            ("structured actual", .array([.object([:]), .array([.int(1)]), .string("red")]), .array([.string("red")]), true, true),
            ("structured ignored", .array([.object([:]), .array([.int(1)])]), .array([.null, .int(1)]), true, false),
            ("object after match", .array([.int(1)]), .array([.int(1), .object([:])]), false, false),
            ("array after match", .array([.int(1)]), .array([.int(1), .array([])]), false, false),
            ("object first", .array([.int(1)]), .array([.object([:]), .int(1)]), false, false),
            ("null actual", .null, .array([]), false, false),
            ("object actual", .object([:]), .array([]), false, false),
            ("scalar actual", .string("red"), .array([.string("red")]), false, false),
            ("null candidates", .array([]), .null, false, false),
            ("scalar candidates", .array([.string("red")]), .string("red"), false, false),
            ("object candidates", .array([]), .object([:]), false, false),
        ]
        for (name, actual, candidates, valid, found) in cases {
            for op in ["includesAny", "notIncludesAny"] {
                let predicate = ConditionPredicate(attribute: "nested.items", operator: op, value: candidates)
                let want = valid && (found == (op == "includesAny"))
                XCTAssertEqual(conditionIsMatched(predicate, context: ["nested": .object(["items": actual])]), want, name + op)
                XCTAssertFalse(conditionIsMatched(predicate, context: [:]), name + "missing")
                if !valid {
                    XCTAssertTrue(allConditionsAreMatched(.not([.predicate(predicate)]), context: ["nested": .object(["items": actual])]))
                    XCTAssertFalse(allConditionsAreMatched(.or([.predicate(predicate)]), context: ["nested": .object(["items": actual])]))
                }
            }
        }
    }

    func testRequirementsShareComparison() throws {
        for (op, candidates, want) in [
            ("includesAny", "[1.0]", true), ("notIncludesAny", "[false]", true),
            ("includesAny", "[true]", false), ("notIncludesAny", "[1]", false),
            ("includesAny", "[]", false), ("notIncludesAny", "[]", true),
            ("includesAny", "[1,{}]", false), ("notIncludesAny", "[1,[]]", false),
        ] {
            let raw = #"""
            {"schemaVersion":"2","revision":"any","segments":{},
             "features":{"gate":{"bucketBy":"userId","conditions":[{"variable":"source","path":["items"],"operator":"OP","value":CANDIDATES}],"traffic":[{"key":"all","segments":"*","percentage":100000,"enabled":true}]}},
             "variables":{"source":{"type":"object","defaultValue":{"items":[1,null,{"x":1}]}},
             "gate":{"type":"boolean","defaultValue":true,"disabledValue":false,"conditions":[{"variable":"source","path":["items"],"operator":"OP","value":CANDIDATES}]}}}
            """#.replacingOccurrences(of: "OP", with: op).replacingOccurrences(of: "CANDIDATES", with: candidates)
            let sdk = createFeaturevisor(FeaturevisorOptions(datafile: try DatafileContent.fromJSON(raw), logLevel: .fatal))
            defer { sdk.close() }
            XCTAssertEqual(sdk.isEnabled("gate", ["userId": .string("user")]), want, op + candidates)
            XCTAssertEqual(sdk.getVariableBoolean("gate"), want, op + candidates)
        }
    }
}
