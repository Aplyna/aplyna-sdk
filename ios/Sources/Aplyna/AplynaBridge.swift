import Foundation

public enum AplynaBridgeError: Error, LocalizedError, Sendable {
    case notConfigured, invalidArguments(String), unsupportedMethod
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Configure Aplyna before calling SDK methods."
        case .invalidArguments(let message): return message
        case .unsupportedMethod: return "Unsupported Aplyna SDK method."
        }
    }
}

/// Shared JSON boundary used by the React Native and Flutter adapters.
/// Only strings cross the actor boundary; tracking still requires explicit consent.
public actor AplynaBridge {
    private var client: AplynaClient?
    private let storageDirectory: URL
    private let session: URLSession

    public init(storageDirectory: URL? = nil, session: URLSession = .shared) {
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aplyna")
        self.session = session
    }

    public func invoke(method: String, argumentsJSON: String) async throws -> String {
        guard argumentsJSON.utf8.count <= 262144,
              let data = argumentsJSON.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AplynaBridgeError.invalidArguments("SDK arguments must be a JSON object within 256 KB.")
        }
        if method == "configure" {
            let base = try text(arguments, "baseUrl")
            guard let url = URL(string: base), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.scheme == "https" || url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") else {
                throw AplynaBridgeError.invalidArguments("Use HTTPS, or HTTP on a local development host.")
            }
            let key = try text(arguments, "apiKey")
            let installationID: String
            if let supplied = try optionalText(arguments, "installationId") { installationID = try identifier(supplied) }
            else {
                let file = storageDirectory.appendingPathComponent("installation-id")
                if let saved = try? String(contentsOf: file, encoding: .utf8) { installationID = try identifier(saved) }
                else {
                    installationID = UUID().uuidString
                    try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
                    try Data(installationID.utf8).write(to: file, options: .atomic)
                }
            }
            client = AplynaClient(baseURL: url, apiKey: key, installationID: installationID, cacheDirectory: storageDirectory.appendingPathComponent("events"), session: session)
            return try json(["installationId": installationID])
        }
        guard let client else { throw AplynaBridgeError.notConfigured }
        switch method {
        case "setConsent":
            guard let value = arguments["granted"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw AplynaBridgeError.invalidArguments("granted must be a boolean.") }
            try await client.setConsent(value.boolValue)
        case "track":
            let name = try text(arguments, "name")
            guard name.range(of: "^[a-z][a-z0-9_]{0,79}$", options: .regularExpression) != nil else { throw AplynaBridgeError.invalidArguments("Use a lowercase event name of up to 80 characters.") }
            let properties: [String: String]
            if let raw = arguments["properties"] {
                guard let values = raw as? [String: String], values.allSatisfy({ $0.key.count <= 80 && $0.value.count <= 500 }) else { throw AplynaBridgeError.invalidArguments("Event properties must have string values within the event limits.") }
                properties = values
            } else { properties = [:] }
            let assignment = try arguments["assignment"].map { try assignmentValue($0) }
            let flowID = try optionalText(arguments, "flowId").map(identifier)
            let stepID = try optionalText(arguments, "stepId").map(identifier)
            try await client.track(name: name, flowID: flowID, stepID: stepID, assignment: assignment, properties: properties)
        case "expose": try await client.expose(assignmentValue(arguments["assignment"] as Any))
        case "flush": try await client.flush()
        case "collectAppleAdsAttribution": try await client.collectAppleAdsAttribution()
        case "refreshTrackingAuthorizationStatus": try await client.refreshTrackingAuthorizationStatus()
        case "setAppLanguage": try await client.setAppLanguage(optionalText(arguments, "language"))
        case "pendingEventCount": return String(await client.pendingEventCount)
        case "assignment":
            let value = try await client.assignment(flowID: identifier(text(arguments, "flowId")))
            return try json(["flowId": value.flowID, "experimentId": value.experimentID as Any? ?? NSNull(), "variant": value.variant])
        case "configuration":
            let value = try await client.configuration(flowID: identifier(text(arguments, "flowId")))
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        default: throw AplynaBridgeError.unsupportedMethod
        }
        return "null"
    }
    private func text(_ values: [String: Any], _ key: String) throws -> String {
        guard let value = values[key] as? String, !value.isEmpty else { throw AplynaBridgeError.invalidArguments("\(key) must be a nonempty string.") }
        return value
    }
    private func optionalText(_ values: [String: Any], _ key: String) throws -> String? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        guard let value = value as? String, !value.isEmpty else { throw AplynaBridgeError.invalidArguments("\(key) must be a nonempty string.") }
        return value
    }
    private func identifier(_ value: String) throws -> String {
        guard value.range(of: "^[a-zA-Z0-9_.:-]{1,120}$", options: .regularExpression) != nil else { throw AplynaBridgeError.invalidArguments("Invalid SDK identifier.") }
        return value
    }
    private func assignmentValue(_ raw: Any) throws -> AplynaAssignment {
        guard let value = raw as? [String: Any], let variant = value["variant"] as? String, ["A", "B"].contains(variant) else { throw AplynaBridgeError.invalidArguments("Use a valid Aplyna assignment.") }
        return try AplynaAssignment(variant: variant, experimentID: optionalText(value, "experimentId").map(identifier), flowID: identifier(text(value, "flowId")))
    }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
}
