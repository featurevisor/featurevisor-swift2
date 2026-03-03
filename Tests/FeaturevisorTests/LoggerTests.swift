import XCTest
@testable import Featurevisor

final class LoggerTests: XCTestCase {
    func testLogLevelFiltering() {
        let captured = ConcurrencyBox<[String]>([])
        let logger = createLogger(level: .warn) { level, message, _ in
            captured.value.append("\(level):\(message)")
        }

        logger.info("info")
        logger.warn("warn")
        logger.error("error")

        XCTAssertEqual(captured.value.count, 2)
        XCTAssertTrue(captured.value.contains("warn:warn"))
        XCTAssertTrue(captured.value.contains("error:error"))
    }

    func testDefaultLevelIsInfo() {
        XCTAssertEqual(Logger.defaultLevel, .info)
    }
}
