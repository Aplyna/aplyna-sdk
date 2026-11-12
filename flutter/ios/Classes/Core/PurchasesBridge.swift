import Foundation
import StoreKit

/// JSON bridge for the Flutter and React Native `Purchases` APIs. Shapes follow the
/// RevenueCat hybrid SDKs so Dart and TypeScript models keep the same fields.
public actor PurchasesBridge {
    public init() {}

    public func invoke(method: String, argumentsJSON: String) async throws -> String {
        guard argumentsJSON.utf8.count <= 262144, let data = argumentsJSON.data(using: .utf8),
              let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PurchasesErrors.make(.purchaseInvalidError, "Arguments must be a JSON object within 256 KB.")
        }
        if method == "purchases.configure" {
            guard let key = args["apiKey"] as? String, key.hasPrefix("aplyna_ios_") else {
                throw PurchasesErrors.make(.invalidCredentialsError, "Configure Purchases with this app's Aplyna iOS SDK key.")
            }
            let builder = Configuration.builder(withAPIKey: key).with(appUserID: args["appUserID"] as? String).with(projectID: args["projectId"] as? String)
            if let raw = args["gatewayUrl"] as? String, let url = URL(string: raw) { builder.with(gatewayURL: url) }
            Purchases.configure(with: builder.build())
            return "null"
        }
        if method == "purchases.isConfigured" { return Purchases.isConfigured ? "true" : "false" }
        guard Purchases.isConfigured else { throw PurchasesErrors.make(.configurationError, "Purchases has not been configured. Call Purchases.configure first.") }
        let purchases = Purchases.shared
        switch method {
        case "purchases.getOfferings": return try encode(Self.json(try await purchases.getOfferings()))
        case "purchases.getCustomerInfo": return try encode(Self.json(try await purchases.getCustomerInfo()))
        case "purchases.restorePurchases": return try encode(Self.json(try await purchases.restorePurchases()))
        case "purchases.syncPurchases": return try encode(Self.json(try await purchases.syncPurchases()))
        case "purchases.getAppUserID": return try encode(["appUserID": purchases.appUserID, "isAnonymous": purchases.isAnonymous])
        case "purchases.canMakePayments": return Purchases.canMakePayments() ? "true" : "false"
        case "purchases.invalidateCustomerInfoCache": purchases.invalidateCustomerInfoCache(); return "null"
        case "purchases.logIn":
            guard let id = args["appUserID"] as? String else { throw PurchasesErrors.make(.invalidAppUserIdError) }
            let result = try await purchases.logIn(id)
            return try encode(["customerInfo": Self.json(result.customerInfo), "created": result.created])
        case "purchases.logOut": return try encode(Self.json(try await purchases.logOut()))
        case "purchases.setAttributes":
            guard let raw = args["attributes"] as? [String: Any] else { throw PurchasesErrors.make(.invalidSubscriberAttributesError) }
            await purchases.core.setAttributes(raw.mapValues { $0 as? String })
            return "null"
        case "purchases.purchaseProduct":
            guard let identifier = args["productIdentifier"] as? String, let product = await purchases.products([identifier]).first else {
                throw PurchasesErrors.make(.productNotAvailableForPurchaseError)
            }
            let result = try await purchases.purchase(product: product)
            // Hybrid SDKs report a cancelled purchase as an error carrying userCancelled.
            if result.userCancelled { throw PurchasesErrors.make(.purchaseCancelledError) }
            var body: [String: Any] = ["customerInfo": Self.json(result.customerInfo), "productIdentifier": identifier]
            if let transaction = result.transaction {
                body["transaction"] = ["transactionIdentifier": transaction.transactionIdentifier, "productIdentifier": transaction.productIdentifier, "purchaseDate": Self.iso(transaction.purchaseDate)]
            }
            return try encode(body)
        default: throw PurchasesErrors.make(.unsupportedError, "Unsupported Purchases method.")
        }
    }

    /// Error fields for the hybrid layers: numeric code as text, message, readable code, userCancelled.
    public static func errorPayload(_ error: Error) -> (code: String, message: String, details: [String: Any]) {
        let mapped = (error as NSError).domain == PurchasesErrors.domain ? error as NSError : PurchasesErrors.map(error)
        let readable = mapped.userInfo[PurchasesErrors.readableErrorCodeKey] as? String ?? "UNKNOWN"
        return (String(mapped.code), mapped.localizedDescription, ["code": mapped.code, "readableErrorCode": readable, "readable_error_code": readable,
                                                                  "userCancelled": mapped.code == ErrorCode.purchaseCancelledError.rawValue, "message": mapped.localizedDescription])
    }

    private func encode(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private static func optional(_ date: Date?) -> Any { date.map { iso($0) as Any } ?? NSNull() }

    static func json(_ entitlement: EntitlementInfo) -> [String: Any] {
        ["identifier": entitlement.identifier, "isActive": entitlement.isActive, "willRenew": entitlement.willRenew,
         "periodType": ["NORMAL", "INTRO", "TRIAL", "PREPAID"][entitlement.periodType.rawValue],
         "latestPurchaseDate": optional(entitlement.latestPurchaseDate), "originalPurchaseDate": optional(entitlement.originalPurchaseDate),
         "expirationDate": optional(entitlement.expirationDate),
         "store": entitlement.store == .playStore ? "PLAY_STORE" : entitlement.store == .appStore ? "APP_STORE" : "UNKNOWN_STORE",
         "productIdentifier": entitlement.productIdentifier, "isSandbox": entitlement.isSandbox,
         "unsubscribeDetectedAt": optional(entitlement.unsubscribeDetectedAt), "billingIssueDetectedAt": optional(entitlement.billingIssueDetectedAt),
         "ownershipType": "PURCHASED"]
    }

    static func json(_ info: CustomerInfo) -> [String: Any] {
        ["entitlements": ["all": info.entitlements.all.mapValues { json($0) }, "active": info.entitlements.active.mapValues { json($0) }],
         "activeSubscriptions": info.activeSubscriptions.sorted(), "allPurchasedProductIdentifiers": info.allPurchasedProductIdentifiers.sorted(),
         "latestExpirationDate": optional(info.latestExpirationDate), "originalAppUserId": info.originalAppUserId,
         "requestDate": iso(info.requestDate), "managementURL": info.managementURL?.absoluteString as Any? ?? NSNull(),
         "allExpirationDates": info.expirations.mapValues { iso($0) }]
    }

    static func period(_ period: SubscriptionPeriod) -> String { "P\(period.value)" + ["D", "W", "M", "Y"][period.unit.rawValue] }

    static func json(_ product: StoreProduct) -> [String: Any] {
        var intro: Any = NSNull()
        if let discount = product.introductoryDiscount {
            intro = ["price": NSDecimalNumber(decimal: discount.price).doubleValue, "priceString": discount.localizedPriceString,
                     "period": period(discount.subscriptionPeriod), "cycles": discount.numberOfPeriods,
                     "periodUnit": ["DAY", "WEEK", "MONTH", "YEAR"][discount.subscriptionPeriod.unit.rawValue],
                     "periodNumberOfUnits": discount.subscriptionPeriod.value] as [String: Any]
        }
        return ["identifier": product.productIdentifier, "title": product.localizedTitle, "description": product.localizedDescription,
                "price": NSDecimalNumber(decimal: product.price).doubleValue, "priceString": product.localizedPriceString,
                "currencyCode": product.currencyCode as Any? ?? NSNull(),
                "productCategory": product.productCategory == .subscription ? "SUBSCRIPTION" : "NON_SUBSCRIPTION",
                "subscriptionPeriod": product.subscriptionPeriod.map { period($0) as Any } ?? NSNull(), "introPrice": intro,
                "subscriptionGroupIdentifier": product.subscriptionGroupIdentifier as Any? ?? NSNull()]
    }

    static func name(_ type: PackageType) -> String {
        switch type {
        case .lifetime: return "LIFETIME"; case .annual: return "ANNUAL"; case .sixMonth: return "SIX_MONTH"; case .threeMonth: return "THREE_MONTH"
        case .twoMonth: return "TWO_MONTH"; case .monthly: return "MONTHLY"; case .weekly: return "WEEKLY"; case .custom: return "CUSTOM"; case .unknown: return "UNKNOWN"
        }
    }

    static func json(_ package: Package) -> [String: Any] {
        ["identifier": package.identifier, "packageType": name(package.packageType), "product": json(package.storeProduct),
         "offeringIdentifier": package.offeringIdentifier, "presentedOfferingContext": ["offeringIdentifier": package.offeringIdentifier]]
    }

    static func json(_ offering: Offering) -> [String: Any] {
        var value: [String: Any] = ["identifier": offering.identifier, "serverDescription": offering.serverDescription, "metadata": offering.metadata,
                                    "availablePackages": offering.availablePackages.map { json($0) }]
        let named: [(String, Package?)] = [("lifetime", offering.lifetime), ("annual", offering.annual), ("sixMonth", offering.sixMonth), ("threeMonth", offering.threeMonth),
                                           ("twoMonth", offering.twoMonth), ("monthly", offering.monthly), ("weekly", offering.weekly)]
        for (key, package) in named { if let package { value[key] = json(package) } }
        return value
    }

    static func json(_ offerings: Offerings) -> [String: Any] {
        ["all": offerings.all.mapValues { json($0) }, "current": offerings.current.map { json($0) as Any } ?? NSNull()]
    }
}
