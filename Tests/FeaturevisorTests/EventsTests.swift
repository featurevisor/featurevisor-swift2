import XCTest
@testable import Featurevisor

final class EventsTests: XCTestCase {
    func testStickyEventParams() {
        let params = getParamsForStickySetEvent(
            previousStickyFeatures: ["a": EvaluatedFeature(enabled: true)],
            newStickyFeatures: ["b": EvaluatedFeature(enabled: true)],
            replace: false
        )

        XCTAssertEqual(params["replaced"], .bool(false))
        XCTAssertEqual(params["features"], .array([.string("a"), .string("b")]))
    }

    func testDatafileEventParams() {
        let d1 = TestFixtures.basicDatafile()
        var d2 = TestFixtures.basicDatafile()
        d2.revision = "2"
        d2.features["test"]?.hash = "h2"

        let p = InstanceEvaluationDataProvider(datafile: d1, reportDiagnostic: { _ in })
        let n = InstanceEvaluationDataProvider(datafile: d2, reportDiagnostic: { _ in })

        let params = getParamsForDatafileSetEvent(previousInstanceEvaluationDataProvider: p, newInstanceEvaluationDataProvider: n, replace: true)
        XCTAssertEqual(params["revision"], .string("2"))
        XCTAssertEqual(params["previousRevision"], .string("1"))
        XCTAssertEqual(params["revisionChanged"], .bool(true))
        XCTAssertEqual(params["features"], .array([.string("test")]))
        XCTAssertEqual(params["replaced"], .bool(true))
    }
}
