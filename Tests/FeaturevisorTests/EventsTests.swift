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
        let logger = createLogger(level: .fatal)

        let d1 = TestFixtures.basicDatafile()
        var d2 = TestFixtures.basicDatafile()
        d2.revision = "2"
        d2.features["test"]?.hash = "h2"

        let p = DatafileReader(datafile: d1, logger: logger)
        let n = DatafileReader(datafile: d2, logger: logger)

        let params = getParamsForDatafileSetEvent(previousDatafileReader: p, newDatafileReader: n)
        XCTAssertEqual(params["revision"], .string("2"))
        XCTAssertEqual(params["previousRevision"], .string("1"))
        XCTAssertEqual(params["revisionChanged"], .bool(true))
        XCTAssertEqual(params["features"], .array([.string("test")]))
    }
}
