import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// Separate from analytics consent and identity. Billing must be configured explicitly.
public actor AplynaBillingBridge {
    private var client: AplynaBillingClient?
    private var updates: Task<Void, Never>?
    private var updateError: String?
    public init() {}
    deinit { updates?.cancel() }

    public func invoke(method: String, argumentsJSON: String) async throws -> String {
        guard argumentsJSON.utf8.count <= 262144, let data = argumentsJSON.data(using: .utf8),
              let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AplynaBridgeError.invalidArguments("Billing arguments must be a JSON object within 256 KB.")
        }
        if method == "billing.configure" {
            guard let raw = args["environment"] as? String, let environment = AplynaBillingEnvironment(rawValue: raw),
                  let key = args["apiKey"] as? String, key.hasPrefix("aplyna_ios_"),
                  let base = args["gatewayUrl"] as? String, let url = URL(string: base),
                  let sandboxOnly = args["sandboxOnly"] as? Bool else {
                throw AplynaBridgeError.invalidArguments("Configure billing with an iOS app SDK key, gateway URL, environment and sandboxOnly boolean.")
            }
            updates?.cancel()
            client = nil
            let configured = try AplynaBillingClient(gatewayURL: url, sdkKey: key, environment: environment, sandboxOnly: sandboxOnly)
            // Fail closed before customer creation or Store purchase UI.
            let actual = try await configured.storeEnvironment()
            guard actual == environment.rawValue, !sandboxOnly || actual == "sandbox" else { throw AplynaBillingError.environmentMismatch }
            client = configured
            updateError = nil
            updates = Task { [weak self] in
                for await result in Transaction.updates {
                    if Task.isCancelled { return }
                    do {
                        _ = try await configured.handleTransactionUpdate(result)
                        await self?.recordUpdateError(nil)
                    } catch AplynaBillingError.customerConflict {
                        // Another billing identity may own an old installed-client purchase.
                        // Never finish it or transfer it into this pilot customer.
                    } catch { await self?.recordUpdateError(error.localizedDescription) }
                }
            }
            return try encode(["environment": actual])
        }
        guard let client else { throw AplynaBridgeError.notConfigured }
        switch method {
        case "billing.customerInfo": return try encodeValue(await client.customerInfo())
        case "billing.sync": return try encodeValue(await client.syncPendingPurchases())
        case "billing.restore": return try encodeValue(await client.restorePurchases())
        case "billing.diagnostics": return try encode(["updateError": updateError as Any? ?? NSNull()])
        case "billing.products":
            let products = try await client.mappedProducts()
            return try encode(products.map { product in
                ["id": product.id, "name": product.displayName, "price": product.displayPrice,
                 "subscriptionGroupId": product.subscription?.subscriptionGroupID as Any? ?? NSNull()] as [String: Any]
            })
        case "billing.purchase":
            guard ["basePlanId", "offerToken", "replacedProductId", "replacementMode"].allSatisfy({ args[$0] == nil }) else {
                throw AplynaBridgeError.invalidArguments("Google Play offer and replacement options are Android-only.")
            }
            guard let identifier = args["productId"] as? String,
                  let product = try await client.mappedProducts().first(where: { $0.id == identifier }) else { throw AplynaBillingError.unmappedProduct }
            return try encodeValue(await client.purchase(product))
        case "billing.manageSubscriptions":
            #if canImport(UIKit)
            try await Self.manageSubscriptions()
            return "null"
            #else
            throw AplynaBillingError.unsupportedPlatform
            #endif
        case "billing.requestRefund":
            #if canImport(UIKit)
            guard let raw = args["transactionId"] as? String, let identifier = UInt64(raw),
                  let result = await Transaction.latest(for: try productIdentifier(args)),
                  case .verified(let transaction) = result, transaction.id == identifier,
                  transaction.environment == .sandbox else { throw AplynaBillingError.unverifiedPurchase }
            guard try await client.owns(transaction) else { throw AplynaBillingError.customerConflict }
            // The bridge's refund pilot is sandbox-only, independently of JS flags.
            let status = try await Self.requestRefund(identifier)
            return try encode(["status": status])
            #else
            throw AplynaBillingError.unsupportedPlatform
            #endif
        case "billing.storeStatuses":
            var groups = Set<String>()
            var rows: [[String: Any]] = []
            for product in try await client.mappedProducts() {
                guard let subscription = product.subscription, groups.insert(subscription.subscriptionGroupID).inserted else { continue }
                for status in try await subscription.status {
                    guard case .verified(let transaction) = status.transaction,
                          case .verified(let renewal) = status.renewalInfo else { throw AplynaBillingError.unverifiedPurchase }
                    guard transaction.environment.rawValue.lowercased() == (try await client.storeEnvironment()) else { continue }
                    rows.append([
                        "productId": transaction.productID, "transactionId": String(transaction.id),
                        "state": Self.stateName(status.state), "willAutoRenew": renewal.willAutoRenew,
                        "ownedByCurrentCustomer": try await client.owns(transaction),
                        "billingRetry": renewal.isInBillingRetry, "environment": transaction.environment.rawValue.lowercased(),
                        "expiresAt": transaction.expirationDate.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                        "gracePeriodExpiresAt": renewal.gracePeriodExpirationDate.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()
                    ])
                }
            }
            return try encode(rows)
        default: throw AplynaBridgeError.unsupportedMethod
        }
    }
    private func recordUpdateError(_ message: String?) { updateError = message }
    private func productIdentifier(_ args: [String: Any]) throws -> String {
        guard let id = args["productId"] as? String, !id.isEmpty, id.count <= 200 else { throw AplynaBillingError.unmappedProduct }
        return id
    }
    private static func stateName(_ state: Product.SubscriptionInfo.RenewalState) -> String {
        switch state {
        case .subscribed: return "active"
        case .inGracePeriod: return "grace_period"
        case .inBillingRetryPeriod: return "billing_retry"
        case .expired: return "expired"
        case .revoked: return "revoked"
        default: return "unknown"
        }
    }
    private func encodeValue<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private func encode(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    #if canImport(UIKit)
    @MainActor private static func scene() throws -> UIWindowScene {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { throw AplynaBillingError.invalidResponse }
        return scene
    }
    @MainActor private static func manageSubscriptions() async throws { try await AppStore.showManageSubscriptions(in: scene()) }
    @MainActor private static func requestRefund(_ identifier: UInt64) async throws -> String {
        switch try await Transaction.beginRefundRequest(for: identifier, in: scene()) {
        case .success: return "requested"
        case .userCancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }
    #endif
}
