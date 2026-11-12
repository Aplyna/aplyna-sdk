import Foundation
import CryptoKit
#if os(iOS) && canImport(AdServices)
import AdServices
#endif
func appleAdsAttributionToken() throws -> String? {
    #if os(iOS) && canImport(AdServices)
    return try AAAttribution.attributionToken()
    #else
    return nil
    #endif
}
#if os(iOS) && canImport(AppTrackingTransparency)
import AppTrackingTransparency
import UIKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AplynaAssignment: Codable, Sendable, Equatable {
    public let variant: String
    public let experimentID: String?
    public let flowID: String
    enum CodingKeys: String, CodingKey { case variant; case experimentID = "experiment_id"; case flowID = "flow_id" }
}
public struct AplynaStep: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let button: String
    public let accent: String
    public let symbol: String
    public let design: AplynaScreenDesign?
    public let layout: AplynaLayoutNode?
}
/// Recursive declarative layout. Available in configuration schema version 2.
public struct AplynaLayoutNode: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let type: String
    public let design: AplynaElementDesign?
    public let direction: String?
    public let gap: Double?
    public let align: String?
    public let justify: String?
    public let children: [AplynaLayoutNode]?
    public let text: String?
    public let role: String?
    public let symbol: String?
    public let grow: Bool?
    public let size: Double?
}
public struct AplynaInsets: Codable, Sendable, Equatable {
    public let top: Double
    public let right: Double
    public let bottom: Double
    public let left: Double
}
public enum AplynaDimension: Codable, Sendable, Equatable {
    case fill, fit, fixed(Double)
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) { self = .fixed(number); return }
        switch try container.decode(String.self) {
        case "fill": self = .fill
        case "fit": self = .fit
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported element dimension")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .fill: try container.encode("fill")
        case .fit: try container.encode("fit")
        case .fixed(let number): try container.encode(number)
        }
    }
}
public struct AplynaGradient: Codable, Sendable {
    public let start: String
    public let end: String
    public let angle: Double
}
public struct AplynaBorder: Codable, Sendable {
    public let width: Double
    public let color: String
}
public struct AplynaShadow: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let blur: Double
    public let color: String
}
public struct AplynaBadge: Codable, Sendable {
    public let text: String
    public let position: String
    public let color: String
    public let background: String
}
public struct AplynaElementDesign: Codable, Sendable {
    public let width: AplynaDimension?
    public let height: AplynaDimension?
    public let align: String?
    public let margin: AplynaInsets?
    public let padding: AplynaInsets?
    public let fontFamily: String?
    public let fontSize: Double?
    public let fontWeight: Int?
    public let lineHeight: Double?
    public let textAlign: String?
    public let color: String?
    public let background: String?
    public let radius: Double?
    public let opacity: Double?
    public let minWidth: Double?
    public let maxWidth: Double?
    public let minHeight: Double?
    public let maxHeight: Double?
    public let fontStyle: String?
    public let underline: Bool?
    public let strikethrough: Bool?
    public let letterSpacing: Double?
    public let shape: String?
    public let gradient: AplynaGradient?
    public let border: AplynaBorder?
    public let shadow: AplynaShadow?
    public let badge: AplynaBadge?

}
public struct AplynaDesignLayers: Codable, Sendable {
    public let art: AplynaElementDesign?
    public let title: AplynaElementDesign?
    public let body: AplynaElementDesign?
    public let button: AplynaElementDesign?
}
public struct AplynaScreenDesign: Codable, Sendable {
    public let padding: AplynaInsets?
    public let gap: Double?
    public let background: String?
    public let gradient: AplynaGradient?
    public let showProgress: Bool?
    public let layers: AplynaDesignLayers?
}
public struct AplynaConfiguration: Codable, Sendable {
    public let schemaVersion: Int
    public let flowID: String
    public let version: Int
    public let mode: String
    public let steps: [AplynaStep]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version"; case flowID = "flow_id"; case version, mode, steps }
}
public enum AplynaError: Error, Sendable { case consentRequired, queueFull, insecureTransport, unsupportedSchema, invalidResponse, server(Int, String) }
private struct Event: Codable, Sendable {
    var eventID: String; var installationID: String; var sessionID: String
    var name: String; var occurredAt: String; var flowID: String?; var stepID: String?
    var experimentID: String?; var variant: String?; var properties: [String: String]
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id", installationID = "installation_id", sessionID = "session_id"
        case name, occurredAt = "occurred_at", flowID = "flow_id", stepID = "step_id"
        case experimentID = "experiment_id", variant, properties
    }
}
enum AplynaATTStatus: String, Codable, Sendable {
    case authorized, denied, restricted
    case notDetermined = "not_determined"
    static var current: Self? {
        #if os(iOS) && canImport(AppTrackingTransparency)
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return nil
        }
        #else
        return nil
        #endif
    }
}
enum AplynaDeviceMetadata {
    static var current: [String: String]? {
        #if os(iOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var result = ["device_locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"), "os_version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", "sdk_version": "1.0.0"]
        result["app_language"] = Bundle.main.preferredLocalizations.first
        result["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return result.filter { !$0.value.isEmpty && $0.value.count <= 80 }
        #else
        return nil
        #endif
    }
}
private struct CustomerAttributes: Codable, Sendable {
    let observationID: String
    let installationID: String
    let platform: String
    let attConsent: AplynaATTStatus?
    let device: [String: String]?
    let observedAt: String
    enum CodingKeys: String, CodingKey {
        case observationID = "observation_id", installationID = "installation_id"
        case platform, device, attConsent = "att_consent", observedAt = "observed_at"
    }
}
private final class ATTActivationObserver: @unchecked Sendable {
    private var token: NSObjectProtocol?
    init(refresh: @escaping @Sendable () -> Void) {
        #if os(iOS) && canImport(AppTrackingTransparency)
        token = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in refresh() }
        #endif
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
private struct Batch: Encodable {
    let consent = true
    let events: [Event]
    let customerAttributes: [CustomerAttributes]?
    enum CodingKeys: String, CodingKey { case consent, events, customerAttributes = "customer_attributes" }
}
private struct CachedConfiguration: Codable { let etag: String?; let configuration: AplynaConfiguration }

/// Native, code-first pilot client. All event delivery requires explicit consent.
/// Call `flush()` on app backgrounding and at meaningful journey boundaries.
public actor AplynaClient {
    private let baseURL: URL
    private let apiKey: String
    private let installationID: String
    private let sessionID = UUID().uuidString
    private let directory: URL
    private let session: URLSession
    private var consent = false
    private var queue: [Event]
    private var flushing = false
    private var consentGeneration = 0
    private var pendingAttributes: CustomerAttributes?
    private var lastObservedATT: AplynaATTStatus?
    private var lastObservedDevice: [String: String]?
    private let deviceMetadataProvider: @Sendable () -> [String: String]?
    private var appLanguageOverride: String?
    private let authorizationStatusProvider: @Sendable () -> AplynaATTStatus?
    private var collectingAppleAds = false
    private let appleAdsTokenProvider: @Sendable () throws -> String?
    private var authorizationObserver: ATTActivationObserver?

    public init(baseURL: URL, apiKey: String, installationID: String, cacheDirectory: URL? = nil, session: URLSession = .shared) {
        self.init(baseURL: baseURL, apiKey: apiKey, installationID: installationID, cacheDirectory: cacheDirectory, session: session, authorizationStatusProvider: { AplynaATTStatus.current }, deviceMetadataProvider: { AplynaDeviceMetadata.current })
    }
    init(baseURL: URL, apiKey: String, installationID: String, cacheDirectory: URL? = nil, session: URLSession = .shared, authorizationStatusProvider: @escaping @Sendable () -> AplynaATTStatus?, appleAdsTokenProvider: @escaping @Sendable () throws -> String? = { try appleAdsAttributionToken() }, deviceMetadataProvider: @escaping @Sendable () -> [String: String]? = { nil }) {
        self.deviceMetadataProvider = deviceMetadataProvider
        self.appleAdsTokenProvider = appleAdsTokenProvider
        self.authorizationStatusProvider = authorizationStatusProvider
        self.baseURL = baseURL; self.apiKey = apiKey; self.installationID = installationID; self.session = session
        let scope = SHA256.hash(data: Data((baseURL.absoluteString + apiKey + installationID).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let root = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aplyna")
        directory = root.appendingPathComponent(scope)
        queue = (try? Data(contentsOf: directory.appendingPathComponent("queue.json"))).flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
        pendingAttributes = (try? Data(contentsOf: directory.appendingPathComponent("customer-attributes.json"))).flatMap { try? JSONDecoder().decode(CustomerAttributes.self, from: $0) }
    }
    public func setConsent(_ granted: Bool) throws {
        consent = granted; consentGeneration += 1
        if !granted {
            authorizationObserver = nil
            queue.removeAll(); pendingAttributes = nil; lastObservedATT = nil; lastObservedDevice = nil
            try persist(); try persistAttributes()
        } else {
            if authorizationObserver == nil {
                authorizationObserver = ATTActivationObserver { [weak self] in
                    Task { try? await self?.refreshTrackingAuthorizationStatus() }
                }
            }
            try refreshTrackingAuthorizationStatus()
        }
    }
    /// Reads iOS ATT without requesting permission or accessing an advertising ID.
    /// Call after the host app's ATT completion callback, then flush for delivery.
    /// Consent remains separate; no collection occurs while it is disabled.
    public func refreshTrackingAuthorizationStatus() throws {
        guard consent else { return }
        let status = authorizationStatusProvider()
        var device = deviceMetadataProvider()
        if let appLanguageOverride { device = (device ?? [:]).merging(["app_language": appLanguageOverride]) { _, new in new } }
        guard status != nil || device != nil else { return }
        let previous = pendingAttributes?.attConsent ?? lastObservedATT
        let previousDevice = pendingAttributes?.device ?? lastObservedDevice
        lastObservedATT = status
        lastObservedDevice = device
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expired = pendingAttributes.map { formatter.date(from: $0.observedAt).map { $0 < Date().addingTimeInterval(-89 * 86400) } ?? true } ?? false
        guard status != previous || device != previousDevice || expired else { return }
        pendingAttributes = CustomerAttributes(observationID: "obs_" + UUID().uuidString, installationID: installationID, platform: "ios", attConsent: status, device: device, observedAt: formatter.string(from: Date()))
        try persistAttributes()
    }
    /// Set the actual runtime language when the host uses its own localization system.
    public func setAppLanguage(_ language: String?) throws {
        if let language, language.range(of: "^[a-zA-Z]{2,8}([-_][a-zA-Z0-9]{1,8})*$", options: .regularExpression) == nil || language.count > 80 { throw AplynaError.invalidResponse }
        appLanguageOverride = language?.replacingOccurrences(of: "_", with: "-")
        try refreshTrackingAuthorizationStatus()
    }
    private func persistAttributes() throws {
        let file = directory.appendingPathComponent("customer-attributes.json")
        if let pendingAttributes {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(pendingAttributes).write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
    /// Collect Apple Ads attribution once for this installation, after analytics consent.
    /// Call on app launch; failed delivery can be retried on a later launch.
    /// Standard AdServices attribution does not request ATT or read IDFA.
    public func collectAppleAdsAttribution() async throws {
        guard consent else { throw AplynaError.consentRequired }
        guard !collectingAppleAds else { return }
        let marker = directory.appendingPathComponent("apple-ads-collected")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        // Do not collect native tokens with legacy, Android or Test Store credentials.
        guard apiKey.hasPrefix("aplyna_ios_") else { return }
        collectingAppleAds = true; defer { collectingAppleAds = false }
        let generation = consentGeneration
        guard let token = try appleAdsTokenProvider() else { return }
        guard consent && generation == consentGeneration else { return }
        var request = try makeRequest(path: "api/v1/attribution/apple-ads")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["consent": true, "installation_id": installationID, "token": token])
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        guard (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["accepted"] as? Bool == true else { throw AplynaError.invalidResponse }
        guard consent && generation == consentGeneration else { return }
        // Only a delivery marker is persisted; the Apple token is never written to disk.
        try write(Data("accepted".utf8), to: marker)
    }
    public var pendingEventCount: Int { queue.count }
    public func track(name: String, flowID: String? = nil, stepID: String? = nil, assignment: AplynaAssignment? = nil, properties: [String: String] = [:]) throws {
        guard consent else { throw AplynaError.consentRequired }
        guard queue.count < 1000 else { throw AplynaError.queueFull }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        queue.append(Event(eventID: "evt_" + UUID().uuidString, installationID: installationID, sessionID: sessionID, name: name, occurredAt: formatter.string(from: Date()), flowID: flowID ?? assignment?.flowID, stepID: stepID, experimentID: assignment?.experimentID, variant: assignment?.experimentID == nil ? nil : assignment?.variant, properties: properties))
        try persist()
    }
    public func expose(_ assignment: AplynaAssignment) throws {
        guard assignment.experimentID != nil else { return }
        try track(name: "experiment_exposed", assignment: assignment)
    }
    public func flush() async throws {
        guard consent else { throw AplynaError.consentRequired }
        guard !flushing else { return }
        try refreshTrackingAuthorizationStatus()
        flushing = true; defer { flushing = false }
        let generation = consentGeneration
        while (!queue.isEmpty || pendingAttributes != nil) && consent && generation == consentGeneration {
            let events = Array(queue.prefix(100)), ids = Set(events.map(\.eventID))
            let attributes = pendingAttributes
            var request = try makeRequest(path: "api/v1/events")
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(Batch(events: events, customerAttributes: attributes.map { [$0] }))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var attempt = 0
            while true {
                guard consent && generation == consentGeneration else { return }
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AplynaError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else { throw AplynaError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
                    break
                } catch {
                    if let sdkError = error as? AplynaError, case .server(let status, _) = sdkError, status < 500 && status != 429 { throw error }
                    guard attempt < 2 else { throw error }
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(250 * (1 << attempt)))
                }
            }
            guard consent && generation == consentGeneration else { return }
            queue.removeAll { ids.contains($0.eventID) }; try persist()
            if let attributes, pendingAttributes?.observationID == attributes.observationID {
                pendingAttributes = nil; try persistAttributes()
            }
        }
    }
    public func assignment(flowID: String) async throws -> AplynaAssignment {
        guard consent else { throw AplynaError.consentRequired }
        let request = try makeRequest(path: "api/v1/assignment", query: ["flow_id": flowID, "installation_id": installationID])
        let cache = cacheFile("assignment-" + flowID)
        do {
            let (data, response) = try await session.data(for: request)
            try check(response, data)
            let assignment = try JSONDecoder().decode(AplynaAssignment.self, from: data)
            try write(data, to: cache)
            return assignment
        } catch {
            if let cached = try? Data(contentsOf: cache), let assignment = try? JSONDecoder().decode(AplynaAssignment.self, from: cached) { return assignment }
            // Offline clients with no previous assignment keep the bundled control.
            return AplynaAssignment(variant: "A", experimentID: nil, flowID: flowID)
        }
    }
    public func configuration(flowID: String) async throws -> AplynaConfiguration {
        let file = cacheFile("config-" + flowID)
        let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CachedConfiguration.self, from: $0) }
        do {
            var request = try makeRequest(path: "api/v1/config", query: ["flow_id": flowID, "schema_version": "2"])
            request.setValue(cached?.etag, forHTTPHeaderField: "If-None-Match")
            let (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 304, let cached { return cached.configuration }
            try check(response, data)
            let configuration = try JSONDecoder().decode(AplynaConfiguration.self, from: data)
            guard [1, 2].contains(configuration.schemaVersion), !configuration.steps.isEmpty else { throw AplynaError.unsupportedSchema }
            try write(JSONEncoder().encode(CachedConfiguration(etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"), configuration: configuration)), to: file)
            return configuration
        } catch {
            if let cached, [1, 2].contains(cached.configuration.schemaVersion) { return cached.configuration }
            throw error
        }
    }
    private func makeRequest(path: String, query: [String: String] = [:]) throws -> URLRequest {
        let local = ["localhost", "127.0.0.1", "::1"].contains(baseURL.host ?? "")
        guard baseURL.scheme == "https" || (baseURL.scheme == "http" && local) else { throw AplynaError.insecureTransport }
        var url = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!, timeoutInterval: 10)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        return request
    }
    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AplynaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AplynaError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
    }
    private func cacheFile(_ name: String) -> URL { directory.appendingPathComponent(SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined() + ".json") }
    private func persist() throws { try write(JSONEncoder().encode(queue), to: directory.appendingPathComponent("queue.json")) }
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
