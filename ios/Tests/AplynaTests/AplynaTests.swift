import XCTest
@testable import Aplyna

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: @Sendable (URLRequest) -> (Int, Data) = { _ in (202, Data("{}".utf8)) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class AplynaTests: XCTestCase, @unchecked Sendable {
    private func session() -> URLSession { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]; return URLSession(configuration: config) }
    func testConsentAndDurableQueue() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = AplynaClient(baseURL: URL(string: "https://example.test")!, apiKey: "test", installationID: "anon", cacheDirectory: dir, session: session())
        do { try await client.track(name: "app_opened"); XCTFail("Consent must be required") } catch AplynaError.consentRequired {}
        try await client.setConsent(true); try await client.track(name: "app_opened")
        let pending = await client.pendingEventCount; XCTAssertEqual(pending, 1)
        let restored = AplynaClient(baseURL: URL(string: "https://example.test")!, apiKey: "test", installationID: "anon", cacheDirectory: dir, session: session())
        let count = await restored.pendingEventCount; XCTAssertEqual(count, 1)
        try await restored.setConsent(false)
        let cleared = await restored.pendingEventCount; XCTAssertEqual(cleared, 0)
    }
    func testFlushAndAssignmentDoNotExpose() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        StubProtocol.respond = { request in
            if request.url!.path.hasSuffix("assignment") { return (200, Data("{\"variant\":\"B\",\"experiment_id\":\"exp_1\",\"flow_id\":\"flow_1\"}".utf8)) }
            return (202, Data("{\"accepted\":1}".utf8))
        }
        let client = AplynaClient(baseURL: URL(string: "https://example.test")!, apiKey: "test", installationID: "anon", cacheDirectory: dir, session: session())
        try await client.setConsent(true)
        let assignment = try await client.assignment(flowID: "flow_1")
        XCTAssertEqual(assignment.variant, "B")
        let before = await client.pendingEventCount; XCTAssertEqual(before, 0)
        try await client.expose(assignment)
        let after = await client.pendingEventCount; XCTAssertEqual(after, 1)
        try await client.flush()
        let flushed = await client.pendingEventCount; XCTAssertEqual(flushed, 0)
    }
    func testRejectedDeliveryKeepsEventForRetry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        StubProtocol.respond = { _ in (401, Data("{}".utf8)) }
        let client = AplynaClient(baseURL: URL(string: "https://example.test")!, apiKey: "test", installationID: "anon", cacheDirectory: dir, session: session())
        try await client.setConsent(true); try await client.track(name: "app_opened")
        do { try await client.flush(); XCTFail("Must fail on revoked key") } catch AplynaError.server(401, _) {}
        let count = await client.pendingEventCount; XCTAssertEqual(count, 1)
    }
    func testDesignConfigurationDecodesAndRoundTripsAlongsideLegacyContent() throws {
        let legacy = ##"{"schema_version":1,"flow_id":"flow_1","version":1,"mode":"visual","steps":[{"id":"welcome","title":"Hello","body":"Welcome","button":"Continue","accent":"#DCE8DD","symbol":"leaf"}]}"##
        let decoder = JSONDecoder()
        let old = try decoder.decode(AplynaConfiguration.self, from: Data(legacy.utf8))
        XCTAssertNil(old.steps[0].design)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any])
        var steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        steps[0]["design"] = ["padding": ["top": 20, "right": 24, "bottom": 32, "left": 24], "showProgress": false, "layers": ["title": ["width": 280, "height": "fit", "fontFamily": "serif", "fontWeight": 700, "fontSize": 40, "lineHeight": 1.3, "padding": ["top": 8, "right": 12, "bottom": 8, "left": 12], "margin": ["top": 12, "right": 0, "bottom": 20, "left": -4]]]]
        json["steps"] = steps
        let config = try decoder.decode(AplynaConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        let title = try XCTUnwrap(config.steps[0].design?.layers?.title)
        XCTAssertEqual(title.width, .fixed(280))
        XCTAssertEqual(title.height, .fit)
        XCTAssertEqual(title.fontFamily, "serif")
        XCTAssertEqual(title.fontSize, 40)
        XCTAssertEqual(title.padding?.left, 12)
        XCTAssertEqual(title.margin?.left, -4)
        XCTAssertEqual(config.steps[0].design?.showProgress, false)
        let restored = try decoder.decode(AplynaConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.steps[0].design?.layers?.title?.width, .fixed(280))
        XCTAssertNil(restored.steps[0].design?.layers?.body)
    }

    func testNestedStackLayoutDecodesAndPreservesAlphaColors() throws {
        let fixture = ##"{"schema_version":2,"flow_id":"flow_2","version":1,"mode":"visual","steps":[{"id":"welcome","title":"Hello","body":"Welcome","button":"Continue","accent":"#DCE8DD","symbol":"leaf","layout":{"id":"root","name":"Screen content","type":"stack","direction":"vertical","gap":12,"align":"stretch","justify":"start","design":{"height":"fill"},"children":[{"id":"row","name":"Row","type":"stack","direction":"horizontal","gap":8,"align":"center","justify":"space-between","children":[{"id":"text","name":"Text","type":"text","role":"body","text":"Hello","design":{"color":"#345CFF80"}},{"id":"button","name":"Button","type":"button","text":"Next"}]}]}}]}"##
        let decoder = JSONDecoder()
        let config = try decoder.decode(AplynaConfiguration.self, from: Data(fixture.utf8))
        XCTAssertEqual(config.schemaVersion, 2)
        let root = try XCTUnwrap(config.steps[0].layout)
        XCTAssertEqual(root.design?.height, .fill)
        XCTAssertEqual(root.children?[0].direction, "horizontal")
        XCTAssertEqual(root.children?[0].children?[0].design?.color, "#345CFF80")
        let restored = try decoder.decode(AplynaConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.steps[0].layout?.children?[0].children?[1].text, "Next")
    }

}
