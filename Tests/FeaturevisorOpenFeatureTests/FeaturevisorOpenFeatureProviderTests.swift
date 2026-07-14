import XCTest
import Featurevisor
import FeaturevisorOpenFeature
import OpenFeature

final class FeaturevisorOpenFeatureProviderTests: XCTestCase {
    private final class CloseState: @unchecked Sendable {
        var closed = false
    }

    private let datafileJSON = #"{"schemaVersion":"2","revision":"openfeature-test","segments":{},"features":{"checkout":{"bucketBy":"userId","variations":[{"value":"on","variables":{"title":"Hello","count":3,"ratio":1.5,"visible":true,"items":["a"],"config":{"color":"blue"},"json":"{\"nested\":true}"}}],"variablesSchema":{"title":{"type":"string","defaultValue":"Default"},"count":{"type":"integer","defaultValue":0},"ratio":{"type":"double","defaultValue":0},"visible":{"type":"boolean","defaultValue":false},"items":{"type":"array","defaultValue":[]},"config":{"type":"object","defaultValue":{}},"json":{"type":"json","defaultValue":"{}"}},"force":[{"conditions":{"attribute":"userId","operator":"equals","value":"forced-user"},"enabled":true,"variation":"on"}],"traffic":[{"key":"all","segments":"*","percentage":100000,"variation":"on"}]}}}"#

    private func provider(
        keySeparator: String = ":",
        variationKey: String = "variation",
        onTrack: ((String, (any EvaluationContext)?, (any TrackingEventDetails)?) -> Void)? = nil
    ) throws -> FeaturevisorOpenFeatureProvider {
        FeaturevisorOpenFeatureProvider(
            options: FeaturevisorOptions(datafile: try DatafileContent.fromJSON(datafileJSON), logLevel: .fatal),
            keySeparator: keySeparator,
            variationKey: variationKey,
            onTrack: onTrack
        )
    }

    func testResolvesEveryTypeAndMapsTargetingKey() throws {
        let provider = try provider()
        let context = ImmutableContext(targetingKey: "forced-user")
        XCTAssertTrue(try provider.getBooleanEvaluation(key: "checkout", defaultValue: false, context: context).value)
        XCTAssertEqual(try provider.getStringEvaluation(key: "checkout:variation", defaultValue: "fallback", context: context).value, "on")
        XCTAssertEqual(try provider.getStringEvaluation(key: "checkout:title", defaultValue: "fallback", context: context).value, "Hello")
        XCTAssertEqual(try provider.getIntegerEvaluation(key: "checkout:count", defaultValue: 0, context: context).value, 3)
        XCTAssertEqual(try provider.getDoubleEvaluation(key: "checkout:ratio", defaultValue: 0, context: context).value, 1.5)
        XCTAssertTrue(try provider.getBooleanEvaluation(key: "checkout:visible", defaultValue: false, context: context).value)
        XCTAssertEqual(try provider.getObjectEvaluation(key: "checkout:items", defaultValue: .list([]), context: context).value, .list([.string("a")]))
        XCTAssertEqual(try provider.getObjectEvaluation(key: "checkout:config", defaultValue: .structure([:]), context: context).value, .structure(["color": .string("blue")]))
        XCTAssertEqual(try provider.getObjectEvaluation(key: "checkout:json", defaultValue: .structure([:]), context: context).value, .structure(["nested": .boolean(true)]))
    }

    func testErrorsCustomGrammarTrackingAndClose() throws {
        var tracked: [String] = []
        let provider = try provider(keySeparator: "/", variationKey: "$variation") { name, _, _ in tracked.append(name) }
        XCTAssertEqual(try provider.getStringEvaluation(key: "checkout/$variation", defaultValue: "fallback", context: nil).value, "on")
        XCTAssertEqual(try provider.getStringEvaluation(key: "missing", defaultValue: "fallback", context: nil).errorCode, .typeMismatch)
        let missing = try provider.getBooleanEvaluation(key: "missing", defaultValue: true, context: nil)
        XCTAssertTrue(missing.value)
        XCTAssertEqual(missing.errorCode, .flagNotFound)
        try provider.track(key: "purchase", context: nil, details: nil)
        XCTAssertEqual(tracked, ["purchase"])
        provider.close()
    }

    func testWorksThroughOpenFeatureAPI() async throws {
        let provider = try provider()
        await OpenFeatureAPI.shared.setProviderAndWait(
            provider: provider,
            initialContext: ImmutableContext(targetingKey: "forced-user")
        )
        let client = OpenFeatureAPI.shared.getClient()
        let value = client.getBooleanValue(
            key: "checkout",
            defaultValue: false
        )
        XCTAssertTrue(value)
    }

    func testProviderBorrowsExistingFeaturevisor() throws {
        let state = CloseState()
        let featurevisor = createFeaturevisor(FeaturevisorOptions(
            datafile: try DatafileContent.fromJSON(datafileJSON),
            logLevel: .fatal,
            modules: [FeaturevisorModule(name: "owner", close: { state.closed = true })]
        ))
        let provider = FeaturevisorOpenFeatureProvider(featurevisor: featurevisor)

        XCTAssertTrue(provider.featurevisor === featurevisor)
        provider.close()
        XCTAssertFalse(state.closed)

        featurevisor.close()
        XCTAssertTrue(state.closed)
    }
}
