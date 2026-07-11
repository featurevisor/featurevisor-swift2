import XCTest
@testable import Featurevisor

final class DatafileReaderTests: XCTestCase {
    func testSharedV3ConformanceFixture() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "conformance/sdk-v3.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(fixture["version"] as? Int, 1)

        let bucketing = fixture["bucketing"] as! [String: Any]
        let expected = bucketing["allocationExpectations"] as! [String: String]
        let reader = DatafileReader(datafile: TestFixtures.basicDatafile(), logger: createLogger(level: .fatal))
        let traffic = Traffic(
            key: "all",
            segments: .all,
            percentage: 100000,
            enabled: nil,
            variation: nil,
            variables: nil,
            variationWeights: nil,
            variableOverrides: nil,
            allocation: [
                Allocation(variation: "control", range: [0, 50000]),
                Allocation(variation: "treatment", range: [50000, 100000]),
            ]
        )

        for (bucket, variation) in expected {
            XCTAssertEqual(reader.getMatchedAllocation(traffic, bucketValue: Int(bucket)!)?.variation, variation)
        }
    }

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

    func testNotSegmentsNegateImplicitAnd() {
        let logger = createLogger(level: .fatal)
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [
                "mobile": Segment(key: "mobile", conditions: .tree(.predicate(.init(attribute: "device", operator: "equals", value: .string("mobile"))))),
                "desktop": Segment(key: "desktop", conditions: .tree(.predicate(.init(attribute: "device", operator: "equals", value: .string("desktop"))))),
                "nl": Segment(key: "nl", conditions: .tree(.predicate(.init(attribute: "country", operator: "equals", value: .string("nl"))))),
            ],
            features: [:]
        )
        let reader = DatafileReader(datafile: datafile, logger: logger)

        let notAll = GroupSegment.not([.key("mobile"), .key("nl")])
        XCTAssertFalse(reader.allSegmentsAreMatched(notAll, context: ["device": .string("mobile"), "country": .string("nl")]))
        XCTAssertTrue(reader.allSegmentsAreMatched(notAll, context: ["device": .string("desktop"), "country": .string("nl")]))
        XCTAssertFalse(reader.allSegmentsAreMatched(.not([]), context: [:]))
    }

    func testNotSegmentsWithNestedOrMeanNoneMatch() {
        let logger = createLogger(level: .fatal)
        let datafile = DatafileContent(
            schemaVersion: "2",
            revision: "1",
            segments: [
                "mobile": Segment(key: "mobile", conditions: .tree(.predicate(.init(attribute: "device", operator: "equals", value: .string("mobile"))))),
                "desktop": Segment(key: "desktop", conditions: .tree(.predicate(.init(attribute: "device", operator: "equals", value: .string("desktop"))))),
            ],
            features: [:]
        )
        let reader = DatafileReader(datafile: datafile, logger: logger)

        let noneOfDevices = GroupSegment.not([.or([.key("mobile"), .key("desktop")])])
        XCTAssertFalse(reader.allSegmentsAreMatched(noneOfDevices, context: ["device": .string("mobile")]))
        XCTAssertTrue(reader.allSegmentsAreMatched(noneOfDevices, context: ["device": .string("tv")]))
    }
}
