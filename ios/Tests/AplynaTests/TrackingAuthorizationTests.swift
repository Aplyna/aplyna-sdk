import XCTest
@testable import Aplyna

private final class ATTState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AplynaATTStatus?
    private var reads = 0
    init(_ value: AplynaATTStatus?) { self.value = value }
    func read() -> AplynaATTStatus? { lock.lock(); defer { lock.unlock() }; reads += 1; return value }
    func set(_ next: AplynaATTStatus?) { lock.lock(); defer { lock.unlock() }; value = next }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
}
private final class ATTRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func record(_ request: URLRequest) {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        lock.lock(); defer { lock.unlock() }; values.append(data)
    }
    var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return values }
}
final class TrackingAuthorizationTests: XCTestCase, @unchecked Sendable {
    func testDeviceMetadataAndRuntimeLanguageAreConsentedSeparateFromATT() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let requests = ATTRequests()
        let sdk = AplynaClient(baseURL: URL(string: "https://example.test")!, apiKey: "test", installationID: "device_customer", cacheDirectory: directory, session: URLSession(configuration: configuration), authorizationStatusProvider: { nil }, deviceMetadataProvider: { ["app_language":"en", "device_locale":"en-GB", "os_version":"26.1", "app_version":"1.2.8"] })
        StubProtocol.respond = { request in requests.record(request); return (202, Data("{}".utf8)) }
        try await sdk.setAppLanguage("fr")
        XCTAssertTrue(requests.bodies.isEmpty)
        try await sdk.setConsent(true); try await sdk.flush()
        let first = try attributes(XCTUnwrap(requests.bodies.last))
        XCTAssertNil(first["att_consent"])
        let device = try XCTUnwrap(first["device"] as? [String:String])
        XCTAssertEqual(device["app_language"], "fr")
        XCTAssertEqual(device["device_locale"], "en-GB")
        XCTAssertEqual(device["os_version"], "26.1")
        try await sdk.flush(); XCTAssertEqual(requests.bodies.count, 1)
        try await sdk.setAppLanguage("de"); try await sdk.flush()
        XCTAssertEqual(try (attributes(XCTUnwrap(requests.bodies.last))["device"] as? [String:String])?["app_language"], "de")
        try await sdk.setConsent(false); try await sdk.setAppLanguage("es")
        XCTAssertEqual(requests.bodies.count, 2)
    }
    private func client(_ directory: URL, _ state: ATTState) -> AplynaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return AplynaClient(baseURL: URL(string: "https://example.test")!, apiKey: "test", installationID: "install_att", cacheDirectory: directory, session: URLSession(configuration: configuration), authorizationStatusProvider: { state.read() })
    }
    private func attributes(_ data: Data) throws -> [String: Any] {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((body["customer_attributes"] as? [[String: Any]])?.first)
    }
    private func attributesFile(_ directory: URL) throws -> URL {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL]
        return try XCTUnwrap(files?.first { $0.lastPathComponent == "customer-attributes.json" })
    }
    func testATTIsSeparateFromAnalyticsConsentAndAllFourStatesUseMetadataWithoutFakeEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = ATTState(.notDetermined), requests = ATTRequests(), sdk = client(directory, state)
        StubProtocol.respond = { request in requests.record(request); return (202, Data("{}".utf8)) }
        try await sdk.refreshTrackingAuthorizationStatus()
        XCTAssertEqual(state.count, 0)
        do { try await sdk.flush(); XCTFail("Analytics consent is required even for authorized ATT") } catch AplynaError.consentRequired {}
        XCTAssertTrue(requests.bodies.isEmpty)
        try await sdk.setConsent(true)
        let count = await sdk.pendingEventCount; XCTAssertEqual(count, 0)
        for status in [AplynaATTStatus.notDetermined, .authorized, .denied, .restricted] {
            state.set(status)
            try await sdk.refreshTrackingAuthorizationStatus()
            try await sdk.flush()
            let data = try XCTUnwrap(requests.bodies.last)
            let values = try attributes(data)
            XCTAssertEqual(values["att_consent"] as? String, status.rawValue)
            XCTAssertEqual(values["installation_id"] as? String, "install_att")
            XCTAssertEqual(values["platform"] as? String, "ios")
            XCTAssertEqual(Set(values.keys), ["att_consent", "installation_id", "platform", "observed_at", "observation_id"])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((body["events"] as? [Any])?.count, 0)
        }
        try await sdk.flush()
        XCTAssertEqual(requests.bodies.count, 4, "Unchanged status does not repeatedly send")
    }
    func testAttributeRetrySurvivesRestartAndRevocationClearsDurableMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = ATTState(.denied), requests = ATTRequests(), sdk = client(directory, state)
        StubProtocol.respond = { request in requests.record(request); return (401, Data("{}".utf8)) }
        try await sdk.setConsent(true)
        do { try await sdk.flush(); XCTFail("Failed delivery must remain queued") } catch AplynaError.server(401, _) {}
        let first = try attributes(XCTUnwrap(requests.bodies.first))
        let restored = client(directory, state)
        try await restored.setConsent(true)
        StubProtocol.respond = { request in requests.record(request); return (202, Data("{}".utf8)) }
        try await restored.flush()
        let second = try attributes(XCTUnwrap(requests.bodies.last))
        XCTAssertEqual(first["observation_id"] as? String, second["observation_id"] as? String)
        state.set(.authorized); try await restored.refreshTrackingAuthorizationStatus()
        let pendingFile = try attributesFile(directory)
        try await restored.setConsent(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFile.path))
        let reads = state.count
        try await restored.refreshTrackingAuthorizationStatus()
        XCTAssertEqual(state.count, reads, "Revoked consent stops collection")
    }
    func testRevokedInFlightDeliveryCannotClearANewConsentGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = ATTState(.authorized), requests = ATTRequests(), sdk = client(directory, state)
        let started = expectation(description: "First attribute request started")
        let release = DispatchSemaphore(value: 0)
        StubProtocol.respond = { request in
            requests.record(request); started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (202, Data("{}".utf8))
        }
        try await sdk.setConsent(true)
        let sending = Task { try await sdk.flush() }
        await fulfillment(of: [started], timeout: 3)
        try await sdk.setConsent(false)
        state.set(.denied)
        try await sdk.setConsent(true)
        release.signal()
        try await sending.value
        StubProtocol.respond = { request in requests.record(request); return (202, Data("{}".utf8)) }
        try await sdk.flush()
        XCTAssertEqual(requests.bodies.count, 2)
        let first = try attributes(requests.bodies[0]), second = try attributes(requests.bodies[1])
        XCTAssertNotEqual(first["observation_id"] as? String, second["observation_id"] as? String)
        XCTAssertEqual(second["att_consent"] as? String, "denied")
    }
    func testUnsupportedPlatformDoesNotReportNotDeterminedAsAFakeATTValue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = ATTRequests(), sdk = client(directory, ATTState(nil))
        StubProtocol.respond = { request in requests.record(request); return (202, Data("{}".utf8)) }
        try await sdk.setConsent(true); try await sdk.flush()
        XCTAssertTrue(requests.bodies.isEmpty)
    }
    func testExpiredOfflineAttributeIsReadAgainInsteadOfBlockingNewDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = ATTState(.denied), requests = ATTRequests(), sdk = client(directory, state)
        try await sdk.setConsent(true)
        let file = try attributesFile(directory)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let oldID = saved["observation_id"] as? String
        saved["observed_at"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-91 * 86400))
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        let restored = client(directory, state)
        StubProtocol.respond = { request in requests.record(request); return (202, Data("{}".utf8)) }
        try await restored.setConsent(true); try await restored.flush()
        let values = try attributes(XCTUnwrap(requests.bodies.last))
        XCTAssertNotEqual(values["observation_id"] as? String, oldID)
        XCTAssertEqual(values["att_consent"] as? String, "denied")
    }
}
