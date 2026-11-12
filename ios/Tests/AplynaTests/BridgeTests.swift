import XCTest
@testable import Aplyna

private final class BridgeRequests: @unchecked Sendable {
    let lock = NSLock()
    var bodies: [Data] = []
    func record(_ request: URLRequest) -> Int {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        lock.lock(); defer { lock.unlock() }; bodies.append(data); return bodies.count
    }
}
final class BridgeTests: XCTestCase, @unchecked Sendable {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
    func testBridgeIdentityConsentDurableQueueAndInvalidArguments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = AplynaBridge(storageDirectory: directory, session: session())
        let options = #"{"apiKey":"test-public-key","baseUrl":"https://example.test"}"#
        let identity = try await bridge.invoke(method: "configure", argumentsJSON: options)
        _ = try await bridge.invoke(method: "refreshTrackingAuthorizationStatus", argumentsJSON: "{}")
        do { _ = try await bridge.invoke(method: "track", argumentsJSON: #"{"name":"app_opened"}"#); XCTFail("Tracking needs consent") } catch AplynaError.consentRequired {}
        _ = try await bridge.invoke(method: "setConsent", argumentsJSON: #"{"granted":true}"#)
        _ = try await bridge.invoke(method: "track", argumentsJSON: #"{"name":"app_opened","properties":{"screen":"welcome"}}"#)
        let restored = AplynaBridge(storageDirectory: directory, session: session())
        let nextIdentity = try await restored.invoke(method: "configure", argumentsJSON: options)
        XCTAssertEqual(nextIdentity, identity)
        let pending = try await restored.invoke(method: "pendingEventCount", argumentsJSON: "{}")
        XCTAssertEqual(pending, "1")
        for (method, args) in [("setConsent", #"{"granted":1}"#), ("track", #"{"name":"Invalid Event"}"#), ("track", #"{"name":"app_opened","properties":{"bad":1}}"#), ("configure", #"{"baseUrl":"http://example.test","apiKey":"test"}"#)] {
            do { _ = try await restored.invoke(method: method, argumentsJSON: args); XCTFail("Invalid arguments must fail") } catch is AplynaBridgeError {}
        }
        _ = try await restored.invoke(method: "setConsent", argumentsJSON: #"{"granted":false}"#)
        let cleared = try await restored.invoke(method: "pendingEventCount", argumentsJSON: "{}")
        XCTAssertEqual(cleared, "0")
    }
    func testBridgeRetryPreservesIDsAndAssignmentDoesNotExpose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = BridgeRequests()
        StubProtocol.respond = { request in
            if request.url!.path.hasSuffix("assignment") { return (200, Data(#"{"flow_id":"flow_1","experiment_id":"exp_1","variant":"B"}"#.utf8)) }
            let count = records.record(request)
            return (count == 1 ? 500 : 202, Data("{}".utf8))
        }
        let bridge = AplynaBridge(storageDirectory: directory, session: session())
        _ = try await bridge.invoke(method: "configure", argumentsJSON: #"{"apiKey":"test","baseUrl":"https://example.test","installationId":"customer_1"}"#)
        _ = try await bridge.invoke(method: "setConsent", argumentsJSON: #"{"granted":true}"#)
        let assignment = try await bridge.invoke(method: "assignment", argumentsJSON: #"{"flowId":"flow_1"}"#)
        let before = try await bridge.invoke(method: "pendingEventCount", argumentsJSON: "{}")
        XCTAssertEqual(before, "0")
        _ = try await bridge.invoke(method: "expose", argumentsJSON: "{\"assignment\":\(assignment)}")
        _ = try await bridge.invoke(method: "flush", argumentsJSON: "{}")
        XCTAssertEqual(records.bodies.count, 2)
        XCTAssertEqual(records.bodies[0], records.bodies[1])
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: records.bodies[1]) as? [String: Any])
        let event = try XCTUnwrap((body["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["installation_id"] as? String, "customer_1")
        XCTAssertEqual(event["name"] as? String, "experiment_exposed")
        let remaining = try await bridge.invoke(method: "pendingEventCount", argumentsJSON: "{}")
        XCTAssertEqual(remaining, "0")
    }
}
