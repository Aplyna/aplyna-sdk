import Foundation
import CryptoKit
import Security
import StoreKit

public enum AplynaBillingEnvironment: String, Codable, Sendable { case sandbox, production }
public struct AplynaEntitlement: Codable, Sendable {
    public let identifier: String
    public let active: Bool
    public let productId: String
    public let expiresAt: String?
}
public struct AplynaSubscription: Codable, Sendable {
    public let provider: String
    public let productId: String
    public let originalTransactionId: String
    public let active: Bool
    public let status: String
    public let expiresAt: String?
    public let autoRenew: Bool?
    public let billingRetry: Bool?
    public let gracePeriodExpiresAt: String?
    public let isTrial: Bool?
}
public struct AplynaCustomerInfo: Codable, Sendable {
    public let customerId: String
    public let environment: String
    public let entitlements: [AplynaEntitlement]
    public let checkedAt: String
    public let subscriptions: [AplynaSubscription]?
    public func hasAccess(to identifier: String) -> Bool {
        entitlements.contains { entitlement in
            guard entitlement.identifier == identifier && entitlement.active else { return false }
            guard let expiry = entitlement.expiresAt else { return true }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (formatter.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry) ?? .distantPast) > Date()
        }
    }
}
public enum AplynaBillingError: Error, LocalizedError, Sendable {
    case insecureTransport, invalidResponse, invalidIdentity, keychain(Int32), unverifiedPurchase, pending, cancelled, unmappedProduct
    case environmentMismatch, customerConflict, busy, unsupportedPlatform
    /// Transport failure before any server answer. `offline` is true when the device has no connection.
    case network(code: Int, offline: Bool)
    case server(Int, String)
    public var code: String {
        switch self {
        case .pending: return "APLYNA_BILLING_PENDING"
        case .cancelled: return "APLYNA_BILLING_CANCELLED"
        case .environmentMismatch: return "APLYNA_BILLING_ENVIRONMENT"
        case .customerConflict: return "APLYNA_BILLING_CUSTOMER_CONFLICT"
        case .unmappedProduct: return "APLYNA_BILLING_UNMAPPED_PRODUCT"
        case .unverifiedPurchase: return "APLYNA_BILLING_UNVERIFIED"
        case .busy: return "APLYNA_BILLING_BUSY"
        case .unsupportedPlatform: return "APLYNA_BILLING_UNSUPPORTED"
        case .network(_, let offline): return offline ? "APLYNA_BILLING_OFFLINE" : "APLYNA_BILLING_NETWORK"
        case .server(let status, _): return "APLYNA_BILLING_HTTP_\(status)"
        default: return "APLYNA_BILLING_ERROR"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .pending: return "The purchase is pending approval or payment."
        case .cancelled: return "The purchase was cancelled."
        case .environmentMismatch: return "This billing client requires the matching verified App Store environment. Sandbox tests cannot use production purchases."
        case .customerConflict: return "This purchase belongs to another customer. Restore the original identity; no transfer was performed."
        case .unmappedProduct: return "This product has no Aplyna entitlement mapping."
        case .unverifiedPurchase: return "The App Store signature could not be verified."
        case .insecureTransport: return "Billing requires a secure gateway URL."
        case .busy: return "Another purchase is already in progress."
        case .unsupportedPlatform: return "This billing action is available only on iOS."
        case .network(_, let offline): return offline ? "The device is offline. Check the connection and try again." : "The billing service could not be reached. Try again."
        case .server(_, let message): return message
        default: return "The billing operation could not complete."
        }
    }
}
private struct BillingIdentity: Codable, Sendable {
    let id: UUID
    let customerToken: String
    let appAccountToken: UUID
}
private struct BillingProducts: Decodable {
    struct Entry: Decodable { let identifier: String; let provider: String; let type: String; let entitlements: [String] }
    let products: [Entry]
}
/// Offerings configured in the Aplyna product catalog, before store products are attached.
public struct AplynaOfferingsCatalog: Decodable, Sendable {
    public struct Item: Decodable, Sendable { public let identifier: String; public let store: String; public let duration: String?; public let entitlements: [String] }
    public struct Package: Decodable, Sendable { public let identifier: String; public let description: String?; public let products: [Item] }
    public struct Offering: Decodable, Sendable { public let identifier: String; public let description: String?; public let packages: [Package] }
    public let current: String?
    public let offerings: [Offering]
}
/// Pilot purchase client. Point gatewayURL at https://your-saas/api/billing.
/// Preserve the Keychain identity; cross-device login/migration is separate.
public actor AplynaBillingClient {
    private let gatewayURL: URL
    private let sdkKey: String
    private let environment: AplynaBillingEnvironment
    private let keychainAccount: String
    private let session: URLSession
    private let sandboxOnly: Bool
    private var purchasing = false
    private var identity: BillingIdentity?
    private var creatingIdentity: Task<BillingIdentity, Error>?
    private var revocationIterator: Transaction.Transactions.AsyncIterator?
    private var pendingRevocation: VerificationResult<Transaction>?
    private var reconcilingRevocations = false
    private var acknowledgedRevocations = Set<String>()
    private var cached: AplynaCustomerInfo?
    private var revocationAcknowledgementOrder: [String] = []
    public init(gatewayURL: URL, sdkKey: String, environment: AplynaBillingEnvironment, sandboxOnly: Bool = false, session: URLSession = .shared) throws {
        guard gatewayURL.host != nil, gatewayURL.user == nil, gatewayURL.password == nil, gatewayURL.query == nil, gatewayURL.fragment == nil,
              gatewayURL.scheme == "https" || gatewayURL.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(gatewayURL.host ?? "") else { throw AplynaBillingError.insecureTransport }
        guard !sandboxOnly || environment == .sandbox else { throw AplynaBillingError.environmentMismatch }
        self.gatewayURL = gatewayURL; self.sdkKey = sdkKey; self.environment = environment; self.session = session
        self.sandboxOnly = sandboxOnly
        self.keychainAccount = "\(gatewayURL.absoluteString)|\(Bundle.main.bundleIdentifier ?? "app")|\(environment.rawValue)"
    }
    public func customerInfo() async throws -> AplynaCustomerInfo {
        let customer = try await customerIdentity()
        let info: AplynaCustomerInfo = try await request(path: "v1/customers/\(customer.id.uuidString.lowercased())", customer: customer)
        remember(info)
        return info
    }
    /// Last server-verified answer, kept for offline display. Expiry is still checked locally
    /// by `hasAccess(to:)`; a cached answer never extends access past its verified bound.
    public func cachedCustomerInfo() -> AplynaCustomerInfo? {
        if let cached { return cached }
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        cached = try? JSONDecoder().decode(AplynaCustomerInfo.self, from: data)
        return cached
    }
    private func remember(_ info: AplynaCustomerInfo) {
        cached = info
        if let data = try? JSONEncoder().encode(info) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }
    private var cacheKey: String { "com.aplyna.billing.customerInfo." + SHA256.hash(data: Data(keychainAccount.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
    /// Stable billing customer for this install.
    public func customerID() async throws -> String { try await customerIdentity().id.uuidString.lowercased() }
    /// Offerings and packages from the product catalog. `projectID` is only needed for legacy app-wide keys.
    public func offeringsCatalog(projectID: String? = nil) async throws -> AplynaOfferingsCatalog {
        var components = URLComponents(url: gatewayURL.deletingLastPathComponent().appendingPathComponent("v1/offerings"), resolvingAgainstBaseURL: false)
        if let projectID, !projectID.isEmpty { components?.queryItems = [URLQueryItem(name: "project_id", value: projectID)] }
        guard let url = components?.url else { throw AplynaBillingError.invalidResponse }
        return try await request(url: url)
    }
    /// Store products for catalog identifiers; unknown identifiers are simply absent.
    public func storeProducts(for identifiers: [String]) async throws -> [Product] {
        guard identifiers.count <= 100 else { throw AplynaBillingError.invalidResponse }
        return try await Product.products(for: Set(identifiers))
    }
    /// Sends customer attributes. A nil value deletes the attribute on the server.
    public func sendAttributes(_ attributes: [String: (value: String?, updatedAt: Date)], appUserID: String?) async throws {
        let customer = try await customerIdentity()
        var rows: [String: Any] = [:]
        for (key, entry) in attributes { rows[key] = ["value": entry.value as Any? ?? NSNull(), "updatedAtMs": Int(entry.updatedAt.timeIntervalSince1970 * 1000)] }
        var body: [String: Any] = ["attributes": rows]
        if let appUserID { body["appUserId"] = appUserID }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let _: [String: Int] = try await request(path: "v1/customers/\(customer.id.uuidString.lowercased())/attributes", method: "POST", body: payload, customer: customer)
    }
    /// Checks StoreKit's verified app transaction before any purchase UI opens.
    public func storeEnvironment() async throws -> String {
        guard case .verified(let app) = try await AppTransaction.shared else { throw AplynaBillingError.unverifiedPurchase }
        return app.environment.rawValue.lowercased()
    }
    public func owns(_ transaction: Transaction) async throws -> Bool {
        let customer = try await customerIdentity()
        return transaction.environment.rawValue.lowercased() == environment.rawValue && transaction.appAccountToken == customer.appAccountToken
    }
    private func requireStoreEnvironment() async throws {
        let actual = try await storeEnvironment()
        guard actual == environment.rawValue, !sandboxOnly || actual == "sandbox" else { throw AplynaBillingError.environmentMismatch }
    }
    public func mappedProducts() async throws -> [Product] {
        let customer = try await customerIdentity()
        let catalog: BillingProducts = try await request(path: "v1/customers/\(customer.id.uuidString.lowercased())/products", customer: customer)
        let identifiers = catalog.products.filter { $0.provider == "apple" && $0.type != "consumable" && !$0.entitlements.isEmpty }.map(\.identifier)
        guard identifiers.count <= 100 else { throw AplynaBillingError.invalidResponse }
        return try await Product.products(for: identifiers).sorted { $0.id < $1.id }
    }
    public func purchase(_ product: Product) async throws -> AplynaCustomerInfo {
        guard !purchasing else { throw AplynaBillingError.busy }
        purchasing = true
        defer { purchasing = false }
        try await requireStoreEnvironment()
        let customer = try await customerIdentity()
        let catalog: BillingProducts = try await request(path: "v1/customers/\(customer.id.uuidString.lowercased())/products", customer: customer)
        guard catalog.products.contains(where: { $0.provider == "apple" && $0.identifier == product.id && $0.type != "consumable" && !$0.entitlements.isEmpty }) else { throw AplynaBillingError.unmappedProduct }
        switch try await product.purchase(options: [.appAccountToken(customer.appAccountToken)]) {
        case .success(let result): return try await submit(result, customer: customer)
        case .pending: throw AplynaBillingError.pending
        case .userCancelled: throw AplynaBillingError.cancelled
        @unknown default: throw AplynaBillingError.invalidResponse
        }
    }
    /// Call on launch and when Transaction.updates produces a result.
    /// StoreKit keeps unfinished transactions available when the network fails.
    public func syncPendingPurchases() async throws -> AplynaCustomerInfo {
        try await requireStoreEnvironment()
        let customer = try await customerIdentity()
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result, transaction.appAccountToken == customer.appAccountToken { _ = try await submit(result, customer: customer) }
        }
        try await reconcileRevocations(customer: customer)
        // Status includes expired/revoked transactions, so a foreground refresh
        // can reconcile access even if no new purchase is delivered on device.
        var groups = Set<String>()
        for product in try await mappedProducts() {
            if let subscription = product.subscription, groups.insert(subscription.subscriptionGroupID).inserted {
                for status in try await subscription.status {
                    if case .verified(let transaction) = status.transaction, transaction.appAccountToken == customer.appAccountToken {
                        _ = try await submit(status.transaction, customer: customer, renewal: status.renewalInfo)
                    }
                }
            }
        }
        return try await customerInfo()
    }
    /// A finished refund may predate this launch and is absent from unfinished
    /// purchases and the latest subscription status. Continue the history scan
    /// across calls, with bounded work and an unacknowledged proof retained for retry.
    private func reconcileRevocations(customer: BillingIdentity) async throws {
        guard !reconcilingRevocations else { return }
        reconcilingRevocations = true
        // The legacy StoreKit iterator is not Sendable. This task is its only
        // consumer: the actor guard above excludes concurrent scans, and the
        // stored reference is removed until this task returns it in defer.
        nonisolated(unsafe) var iterator = revocationIterator ?? Transaction.all.makeAsyncIterator()
        revocationIterator = nil
        var complete = false
        defer {
            revocationIterator = complete ? nil : iterator
            reconcilingRevocations = false
        }
        var inspected = 0
        var submitted = 0
        while inspected < 100 && submitted < 20 {
            let result: VerificationResult<Transaction>
            if let pendingRevocation { result = pendingRevocation }
            else if let next = await iterator.next() { result = next }
            else { complete = true; break }
            inspected += 1
            guard case .verified(let transaction) = result,
                  transaction.revocationDate != nil,
                  transaction.appAccountToken == customer.appAccountToken,
                  transaction.environment.rawValue.lowercased() == environment.rawValue else {
                pendingRevocation = nil
                continue
            }
            guard !acknowledgedRevocations.contains(revocationFingerprint(result)) else {
                pendingRevocation = nil
                continue
            }
            pendingRevocation = result
            _ = try await submit(result, customer: customer)
            pendingRevocation = nil
            submitted += 1
        }
    }
    private func revocationFingerprint(_ result: VerificationResult<Transaction>) -> String {
        SHA256.hash(data: Data(result.jwsRepresentation.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async throws -> AplynaCustomerInfo {
        try await submit(result, customer: try await customerIdentity())
    }
    /// Invoke only from a user-requested Restore purchases action.
    public func restorePurchases() async throws -> AplynaCustomerInfo {
        try await requireStoreEnvironment()
        try await AppStore.sync()
        return try await syncPendingPurchases()
    }
    private func submit(_ result: VerificationResult<Transaction>, customer: BillingIdentity, renewal: VerificationResult<Product.SubscriptionInfo.RenewalInfo>? = nil) async throws -> AplynaCustomerInfo {
        guard case .verified(let transaction) = result else { throw AplynaBillingError.unverifiedPurchase }
        guard transaction.environment.rawValue.lowercased() == environment.rawValue else { throw AplynaBillingError.environmentMismatch }
        guard transaction.appAccountToken == customer.appAccountToken else { throw AplynaBillingError.customerConflict }
        // Signature and environment are verified again by the server. Xcode
        // local StoreKit signatures are intentionally not accepted in cloud.
        var body: [String: Any] = ["environment": environment.rawValue, "signedTransaction": result.jwsRepresentation]
        if let renewal {
            guard case .verified(let value) = renewal, value.originalTransactionID == transaction.originalID else { throw AplynaBillingError.unverifiedPurchase }
            body["signedRenewalInfo"] = renewal.jwsRepresentation
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let info: AplynaCustomerInfo = try await request(path: "v1/customers/\(customer.id.uuidString.lowercased())/purchases/apple", method: "POST", body: payload, customer: customer)
        remember(info)
        await transaction.finish()
        if transaction.revocationDate != nil {
            let fingerprint = revocationFingerprint(result)
            if acknowledgedRevocations.insert(fingerprint).inserted {
                revocationAcknowledgementOrder.append(fingerprint)
                if revocationAcknowledgementOrder.count > 128 {
                    acknowledgedRevocations.remove(revocationAcknowledgementOrder.removeFirst())
                }
            }
        }
        return info
    }
    private func customerIdentity() async throws -> BillingIdentity {
        if let identity { return identity }
        if let creatingIdentity { return try await creatingIdentity.value }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.aplyna.billing", kSecAttrAccount as String: keychainAccount, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, let saved = try? JSONDecoder().decode(BillingIdentity.self, from: data) else { throw AplynaBillingError.invalidIdentity }
            identity = saved; return saved
        }
        guard status == errSecItemNotFound else { throw AplynaBillingError.keychain(status) }
        let task = Task { () throws -> BillingIdentity in
            let payload = try JSONSerialization.data(withJSONObject: ["environment": environment.rawValue])
            let created: BillingIdentity = try await request(path: "v1/customers", method: "POST", body: payload)
            let values: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.aplyna.billing", kSecAttrAccount as String: keychainAccount, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecValueData as String: try JSONEncoder().encode(created)]
            let saved = SecItemAdd(values as CFDictionary, nil)
            guard saved == errSecSuccess else { throw AplynaBillingError.keychain(saved) }
            return created
        }
        creatingIdentity = task
        defer { creatingIdentity = nil }
        let created = try await task.value; identity = created; return created
    }
    private func request<T: Decodable>(path: String = "", url: URL? = nil, method: String = "GET", body: Data? = nil, customer: BillingIdentity? = nil) async throws -> T {
        var request = URLRequest(url: url ?? gatewayURL.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 55
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sdkKey)", forHTTPHeaderField: "Authorization")
        if let customer { request.setValue(customer.customerToken, forHTTPHeaderField: "X-Aplyna-Customer-Token") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            // Report transport failures as such instead of a raw NSURLErrorDomain code.
            let offline = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
            throw AplynaBillingError.network(code: error.code.rawValue, offline: offline)
        }
        guard let http = response as? HTTPURLResponse else { throw AplynaBillingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data)["error"]) ?? "Could not verify this purchase."
            throw AplynaBillingError.server(http.statusCode, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
