import XCTest
@testable import Aplyna

private final class AppleAdsProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var requests = 0
    func token() -> String { lock.lock(); defer { lock.unlock() }; reads += 1; return String(repeating: "a", count: 100) }
    func record() { lock.lock(); defer { lock.unlock() }; requests += 1 }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (reads, requests) }
}
final class AppleAdsTests: XCTestCase, @unchecked Sendable {
    private func client(_ directory: URL, _ probe: AppleAdsProbe, key: String = "aplyna_ios_test") -> AplynaClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AplynaClient(baseURL: URL(string: "https://example.test")!, apiKey: key, installationID: "ads_install", cacheDirectory: directory, session: URLSession(configuration: configuration), authorizationStatusProvider: { nil }, appleAdsTokenProvider: { probe.token() })
    }
    func testConsentNativeKeyAndDurableOncePerInstallationDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = AppleAdsProbe(), sdk = client(directory, probe)
        StubProtocol.respond = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/attribution/apple-ads")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer aplyna_ios_test")
            probe.record(); return (202, Data("{\"accepted\":true}".utf8))
        }
        do { try await sdk.collectAppleAdsAttribution(); XCTFail("Consent required") } catch AplynaError.consentRequired {}
        XCTAssertEqual(probe.counts.0, 0)
        let sandbox = client(directory, probe, key: "aplyna_test_example")
        try await sandbox.setConsent(true); try await sandbox.collectAppleAdsAttribution()
        XCTAssertEqual(probe.counts.0, 0)
        try await sdk.setConsent(true); try await sdk.collectAppleAdsAttribution(); try await sdk.collectAppleAdsAttribution()
        let restored = client(directory, probe); try await restored.setConsent(true); try await restored.collectAppleAdsAttribution()
        XCTAssertEqual(probe.counts.0, 1); XCTAssertEqual(probe.counts.1, 1)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        for file in files {
            if let data = try? Data(contentsOf: file) { XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(String(repeating: "a", count: 100))) }
        }
    }
    func testFailedLookupCanRetryWithFreshTokenAndDoesNotMarkDelivered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = AppleAdsProbe(), sdk = client(directory, probe)
        try await sdk.setConsent(true)
        StubProtocol.respond = { _ in probe.record(); return (503, Data("{}".utf8)) }
        do { try await sdk.collectAppleAdsAttribution(); XCTFail("Failure must surface") } catch AplynaError.server(503, _) {}
        StubProtocol.respond = { _ in probe.record(); return (202, Data("{\"accepted\":true}".utf8)) }
        try await sdk.collectAppleAdsAttribution(); XCTAssertEqual(probe.counts.0, 2)
        try await sdk.setConsent(false)
        do { try await sdk.collectAppleAdsAttribution(); XCTFail("Revoked consent") } catch AplynaError.consentRequired {}
        XCTAssertEqual(probe.counts.1, 2)
    }
}
