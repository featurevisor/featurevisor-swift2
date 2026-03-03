import XCTest
@testable import Featurevisor

final class DatafileReaderTests: XCTestCase {
    func testGetters() {
        let logger = createLogger(level: .fatal)
        let reader = DatafileReader(datafile: TestFixtures.basicDatafile(), logger: logger)

        XCTAssertEqual(reader.getRevision(), "1")
        XCTAssertEqual(reader.getSchemaVersion(), "2")
        XCTAssertNotNil(reader.getFeature("test"))
        XCTAssertNotNil(reader.getSegment("nl"))
    }

    func testMatchedTrafficAndForce() {
        let logger = createLogger(level: .fatal)
        let reader = DatafileReader(datafile: TestFixtures.basicDatafile(), logger: logger)
        let feature = reader.getFeature("test")!

        let traffic = reader.getMatchedTraffic(feature.traffic, context: ["userId": .string("123")])
        XCTAssertEqual(traffic?.key, "1")

        let force = reader.getMatchedForce(feature, context: ["userId": .string("forced")])
        XCTAssertEqual(force.force?.variation, "control")
        XCTAssertEqual(force.index, 0)
    }
}
