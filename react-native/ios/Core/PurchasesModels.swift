import Foundation
import StoreKit

// Aplyna's purchase API uses the same names and shapes as RevenueCat's public SDK so an app
// can switch by changing its import and API key. This is an independent implementation on top
// of AplynaBillingClient; it talks only to the Aplyna billing gateway.

// MARK: - Errors

/// Same cases and numeric values as RevenueCat's `ErrorCode`.
@objc public enum ErrorCode: Int, Error, Sendable {
    case unknownError = 0
    case purchaseCancelledError = 1
    case storeProblemError = 2
    case purchaseNotAllowedError = 3
    case purchaseInvalidError = 4
    case productNotAvailableForPurchaseError = 5
    case productAlreadyPurchasedError = 6
    case receiptAlreadyInUseError = 7
    case invalidReceiptError = 8
    case missingReceiptFileError = 9
    case networkError = 10
    case invalidCredentialsError = 11
    case unexpectedBackendResponseError = 12
    case invalidAppUserIdError = 14
    case operationAlreadyInProgressForProductError = 15
    case unknownBackendError = 16
    case invalidAppleSubscriptionKeyError = 17
    case ineligibleError = 18
    case insufficientPermissionsError = 19
    case paymentPendingError = 20
    case invalidSubscriberAttributesError = 21
    case logOutAnonymousUserError = 22
    case configurationError = 23
    case unsupportedError = 24
    case emptySubscriberAttributes = 25
    case customerInfoError = 29
    case productRequestTimedOut = 32
    case invalidPromotionalOfferError = 34
    case offlineConnectionError = 35

    /// Stable text code, as exposed by the hybrid SDKs (`readableErrorCode`).
    public var readableCode: String {
        switch self {
        case .unknownError: return "UNKNOWN"
        case .purchaseCancelledError: return "PURCHASE_CANCELLED"
        case .storeProblemError: return "STORE_PROBLEM"
        case .purchaseNotAllowedError: return "PURCHASE_NOT_ALLOWED"
        case .purchaseInvalidError: return "PURCHASE_INVALID"
        case .productNotAvailableForPurchaseError: return "PRODUCT_NOT_AVAILABLE_FOR_PURCHASE"
        case .productAlreadyPurchasedError: return "PRODUCT_ALREADY_PURCHASED"
        case .receiptAlreadyInUseError: return "RECEIPT_ALREADY_IN_USE"
        case .invalidReceiptError: return "INVALID_RECEIPT"
        case .missingReceiptFileError: return "MISSING_RECEIPT_FILE"
        case .networkError: return "NETWORK_ERROR"
        case .invalidCredentialsError: return "INVALID_CREDENTIALS"
        case .unexpectedBackendResponseError: return "UNEXPECTED_BACKEND_RESPONSE_ERROR"
        case .invalidAppUserIdError: return "INVALID_APP_USER_ID"
        case .operationAlreadyInProgressForProductError: return "OPERATION_ALREADY_IN_PROGRESS"
        case .unknownBackendError: return "UNKNOWN_BACKEND_ERROR"
        case .invalidAppleSubscriptionKeyError: return "INVALID_APPLE_SUBSCRIPTION_KEY"
        case .ineligibleError: return "INELIGIBLE_ERROR"
        case .insufficientPermissionsError: return "INSUFFICIENT_PERMISSIONS_ERROR"
        case .paymentPendingError: return "PAYMENT_PENDING_ERROR"
        case .invalidSubscriberAttributesError: return "INVALID_SUBSCRIBER_ATTRIBUTES"
        case .logOutAnonymousUserError: return "LOGOUT_CALLED_WITH_ANONYMOUS_USER"
        case .configurationError: return "CONFIGURATION_ERROR"
        case .unsupportedError: return "UNSUPPORTED_ERROR"
        case .emptySubscriberAttributes: return "EMPTY_SUBSCRIBER_ATTRIBUTES"
        case .customerInfoError: return "CUSTOMER_INFO_ERROR"
        case .productRequestTimedOut: return "PRODUCT_REQUEST_TIMED_OUT_ERROR"
        case .invalidPromotionalOfferError: return "INVALID_PROMOTIONAL_OFFER_ERROR"
        case .offlineConnectionError: return "OFFLINE_CONNECTION_ERROR"
        }
    }
}

/// Errors thrown by `Purchases` are `NSError`s that also cast to `ErrorCode`.
public typealias PublicError = NSError

public enum PurchasesErrors {
    public static let domain = (ErrorCode.unknownError as NSError).domain
    public static let readableErrorCodeKey = "readable_error_code"

    public static func make(_ code: ErrorCode, _ message: String? = nil, underlying: Error? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message ?? defaultMessage(code), readableErrorCodeKey: code.readableCode]
        if let underlying { info[NSUnderlyingErrorKey] = underlying as NSError }
        return NSError(domain: domain, code: code.rawValue, userInfo: info)
    }

    /// Translates store, transport and gateway failures into the RevenueCat error codes.
    public static func map(_ error: Error) -> NSError {
        if let known = error as? ErrorCode { return make(known, (error as NSError).localizedDescription) }
        if let billing = error as? AplynaBillingError { return make(code(for: billing), billing.errorDescription, underlying: billing) }
        if let store = error as? StoreKitError {
            switch store {
            case .userCancelled: return make(.purchaseCancelledError, underlying: store)
            case .networkError: return make(.networkError, underlying: store)
            case .notAvailableInStorefront: return make(.productNotAvailableForPurchaseError, underlying: store)
            case .notEntitled: return make(.purchaseNotAllowedError, underlying: store)
            default: return make(.storeProblemError, store.localizedDescription, underlying: store)
            }
        }
        if let purchase = error as? Product.PurchaseError {
            switch purchase {
            case .purchaseNotAllowed: return make(.purchaseNotAllowedError, underlying: purchase)
            case .productUnavailable: return make(.productNotAvailableForPurchaseError, underlying: purchase)
            case .ineligibleForOffer: return make(.ineligibleError, underlying: purchase)
            case .invalidQuantity: return make(.purchaseInvalidError, underlying: purchase)
            default: return make(.invalidPromotionalOfferError, underlying: purchase)
            }
        }
        if let url = error as? URLError {
            let offline = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(url.code)
            return make(offline ? .offlineConnectionError : .networkError, underlying: url)
        }
        return make(.unknownError, error.localizedDescription, underlying: error)
    }

    static func code(for error: AplynaBillingError) -> ErrorCode {
        switch error {
        case .cancelled: return .purchaseCancelledError
        case .pending: return .paymentPendingError
        case .busy: return .operationAlreadyInProgressForProductError
        case .unmappedProduct: return .productNotAvailableForPurchaseError
        case .unverifiedPurchase: return .invalidReceiptError
        case .customerConflict: return .receiptAlreadyInUseError
        case .environmentMismatch, .insecureTransport: return .configurationError
        case .unsupportedPlatform: return .unsupportedError
        case .invalidResponse: return .unexpectedBackendResponseError
        case .invalidIdentity, .keychain: return .customerInfoError
        case .network(_, let offline): return offline ? .offlineConnectionError : .networkError
        case .server(let status, _):
            switch status {
            case 401, 403: return .invalidCredentialsError
            case 409: return .receiptAlreadyInUseError
            case 400, 422: return .purchaseInvalidError
            case 404: return .unexpectedBackendResponseError
            default: return .unknownBackendError
            }
        }
    }

    static func defaultMessage(_ code: ErrorCode) -> String {
        switch code {
        case .purchaseCancelledError: return "Purchase was cancelled."
        case .storeProblemError: return "There was a problem with the App Store."
        case .purchaseNotAllowedError: return "The device or user is not allowed to make the purchase."
        case .purchaseInvalidError: return "One or more of the arguments provided are invalid."
        case .productNotAvailableForPurchaseError: return "The product is not available for purchase."
        case .productAlreadyPurchasedError: return "This product is already active for the user."
        case .receiptAlreadyInUseError: return "There is already another active subscriber using the same receipt."
        case .invalidReceiptError: return "The receipt is not valid."
        case .networkError: return "Error performing request."
        case .offlineConnectionError: return "Error performing request because the internet connection appears to be offline."
        case .invalidCredentialsError: return "There was a credentials issue. Check the underlying error for more details."
        case .unexpectedBackendResponseError: return "Received unexpected response from the backend."
        case .invalidAppUserIdError: return "The app user id is not valid."
        case .operationAlreadyInProgressForProductError: return "The operation is already in progress for this product."
        case .unknownBackendError: return "There was an unknown backend error."
        case .paymentPendingError: return "The payment is pending."
        case .invalidSubscriberAttributesError: return "One or more of the attributes sent could not be saved."
        case .logOutAnonymousUserError: return "Called logOut but the current user is anonymous."
        case .configurationError: return "There is an issue with your configuration. Check the underlying error for more details."
        case .emptySubscriberAttributes: return "A request for subscriber attributes returned none."
        case .customerInfoError: return "There was a problem related to the customer info."
        default: return "Unknown error."
        }
    }
}

// MARK: - Customer info

public enum PeriodType: Int, Sendable { case normal = 0, intro = 1, trial = 2, prepaid = 3 }
public enum Store: Int, Sendable { case appStore = 0, macAppStore = 1, playStore = 2, stripe = 3, promotional = 4, unknownStore = 5, amazon = 6 }
public enum PurchaseOwnershipType: Int, Sendable { case purchased = 0, familyShared = 1, unknown = 2 }

public struct EntitlementInfo: Sendable, Equatable {
    public let identifier: String
    public let isActive: Bool
    public let willRenew: Bool
    public let periodType: PeriodType
    public let latestPurchaseDate: Date?
    public let originalPurchaseDate: Date?
    public let expirationDate: Date?
    public let store: Store
    public let productIdentifier: String
    public let isSandbox: Bool
    /// When renewal was turned off; the verification time of the answer that reported it.
    public let unsubscribeDetectedAt: Date?
    /// When a billing problem was reported; the verification time of the answer that reported it.
    public let billingIssueDetectedAt: Date?
    public let ownershipType: PurchaseOwnershipType
}

public struct EntitlementInfos: Sendable, Equatable {
    public let all: [String: EntitlementInfo]
    public var active: [String: EntitlementInfo] { all.filter { $0.value.isActive } }
    public subscript(key: String) -> EntitlementInfo? { all[key] }
}

public struct CustomerInfo: Sendable, Equatable {
    public let entitlements: EntitlementInfos
    public let activeSubscriptions: Set<String>
    public let allPurchasedProductIdentifiers: Set<String>
    public let latestExpirationDate: Date?
    public let originalAppUserId: String
    public let requestDate: Date
    public let managementURL: URL?
    let expirations: [String: Date]

    public func expirationDate(forProductIdentifier identifier: String) -> Date? { expirations[identifier] }
    public func expirationDate(forEntitlement identifier: String) -> Date? { entitlements[identifier]?.expirationDate }

    /// Builds the RevenueCat-shaped view of a server-verified answer. `now` only decides
    /// whether an already verified expiry has passed; it never grants access.
    public init(_ info: AplynaCustomerInfo, appUserID: String, now: Date = Date()) {
        let checked = Self.date(info.checkedAt) ?? now
        let sandbox = info.environment == "sandbox"
        let subscriptions = info.subscriptions ?? []
        var all: [String: EntitlementInfo] = [:]
        for entitlement in info.entitlements {
            let subscription = subscriptions.first { $0.productId == entitlement.productId }
            let expiry = entitlement.expiresAt.flatMap(Self.date)
            let retry = subscription?.billingRetry == true
            let renews = subscription?.autoRenew == true
            all[entitlement.identifier] = EntitlementInfo(
                identifier: entitlement.identifier,
                isActive: entitlement.active && (expiry == nil || expiry! > now),
                willRenew: renews && !retry,
                periodType: subscription?.isTrial == true ? .trial : .normal,
                latestPurchaseDate: nil, originalPurchaseDate: nil, expirationDate: expiry,
                store: subscription?.provider == "google" ? .playStore : .appStore,
                productIdentifier: entitlement.productId, isSandbox: sandbox,
                unsubscribeDetectedAt: subscription?.autoRenew == false ? checked : nil,
                billingIssueDetectedAt: retry ? checked : nil, ownershipType: .purchased)
        }
        var expirations: [String: Date] = [:]
        for subscription in subscriptions { if let date = subscription.expiresAt.flatMap(Self.date) { expirations[subscription.productId] = max(date, expirations[subscription.productId] ?? .distantPast) } }
        entitlements = EntitlementInfos(all: all)
        activeSubscriptions = Set(subscriptions.filter { $0.active && (expirations[$0.productId] ?? .distantFuture) > now }.map(\.productId))
        allPurchasedProductIdentifiers = Set(subscriptions.map(\.productId))
        latestExpirationDate = expirations.values.max()
        originalAppUserId = appUserID
        requestDate = checked
        managementURL = subscriptions.contains { $0.provider == "apple" } ? URL(string: "https://apps.apple.com/account/subscriptions")
            : subscriptions.contains { $0.provider == "google" } ? URL(string: "https://play.google.com/store/account/subscriptions") : nil
        self.expirations = expirations
    }

    static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

// MARK: - Offerings

public enum PackageType: Int, Sendable {
    case unknown = -2, custom = -1, lifetime = 0, annual = 1, sixMonth = 2, threeMonth = 3, twoMonth = 4, monthly = 5, weekly = 6

    /// RevenueCat's reserved `$rc_` package identifiers keep their meaning; plain names work too.
    public static func from(identifier: String) -> PackageType {
        switch identifier.lowercased().replacingOccurrences(of: "$rc_", with: "").replacingOccurrences(of: "$aplyna_", with: "") {
        case "lifetime": return .lifetime
        case "annual", "yearly": return .annual
        case "six_month", "sixmonth": return .sixMonth
        case "three_month", "threemonth", "quarterly": return .threeMonth
        case "two_month", "twomonth": return .twoMonth
        case "monthly": return .monthly
        case "weekly": return .weekly
        default: return .custom
        }
    }
}

public struct SubscriptionPeriod: Sendable, Equatable {
    public enum Unit: Int, Sendable { case day = 0, week = 1, month = 2, year = 3 }
    public let value: Int
    public let unit: Unit
}

public struct StoreProductDiscount: Sendable, Equatable {
    public enum PaymentMode: Int, Sendable { case payAsYouGo = 0, payUpFront = 1, freeTrial = 2 }
    public let offerIdentifier: String?
    public let price: Decimal
    public let localizedPriceString: String
    public let paymentMode: PaymentMode
    public let subscriptionPeriod: SubscriptionPeriod
    public let numberOfPeriods: Int
}

public struct StoreProduct: Sendable {
    public enum ProductCategory: Int, Sendable { case subscription = 0, nonSubscription = 1 }
    public let productIdentifier: String
    public let localizedTitle: String
    public let localizedDescription: String
    public let price: Decimal
    public let localizedPriceString: String
    public let currencyCode: String?
    public let productCategory: ProductCategory
    public let subscriptionPeriod: SubscriptionPeriod?
    public let introductoryDiscount: StoreProductDiscount?
    public let subscriptionGroupIdentifier: String?
    /// The underlying StoreKit 2 product.
    public let sk2Product: Product?

    init(productIdentifier: String, localizedTitle: String = "", localizedDescription: String = "", price: Decimal = 0, localizedPriceString: String = "",
         currencyCode: String? = nil, productCategory: ProductCategory = .subscription, subscriptionPeriod: SubscriptionPeriod? = nil,
         introductoryDiscount: StoreProductDiscount? = nil, subscriptionGroupIdentifier: String? = nil, sk2Product: Product? = nil) {
        self.productIdentifier = productIdentifier; self.localizedTitle = localizedTitle; self.localizedDescription = localizedDescription
        self.price = price; self.localizedPriceString = localizedPriceString; self.currencyCode = currencyCode; self.productCategory = productCategory
        self.subscriptionPeriod = subscriptionPeriod; self.introductoryDiscount = introductoryDiscount
        self.subscriptionGroupIdentifier = subscriptionGroupIdentifier; self.sk2Product = sk2Product
    }

    public init(sk2Product product: Product) {
        func period(_ value: Product.SubscriptionPeriod) -> SubscriptionPeriod {
            let unit: SubscriptionPeriod.Unit
            switch value.unit { case .day: unit = .day; case .week: unit = .week; case .month: unit = .month; case .year: unit = .year; @unknown default: unit = .month }
            return SubscriptionPeriod(value: value.value, unit: unit)
        }
        let intro = product.subscription?.introductoryOffer.map { offer in
            StoreProductDiscount(offerIdentifier: offer.id, price: offer.price, localizedPriceString: offer.displayPrice,
                                 paymentMode: offer.paymentMode == .freeTrial ? .freeTrial : offer.paymentMode == .payUpFront ? .payUpFront : .payAsYouGo,
                                 subscriptionPeriod: period(offer.period), numberOfPeriods: offer.periodCount)
        }
        self.init(productIdentifier: product.id, localizedTitle: product.displayName, localizedDescription: product.description, price: product.price,
                  localizedPriceString: product.displayPrice, currencyCode: product.priceFormatStyle.currencyCode,
                  productCategory: product.subscription == nil ? .nonSubscription : .subscription,
                  subscriptionPeriod: product.subscription.map { period($0.subscriptionPeriod) }, introductoryDiscount: intro,
                  subscriptionGroupIdentifier: product.subscription?.subscriptionGroupID, sk2Product: product)
    }
}

public struct Package: Sendable {
    public let identifier: String
    public let packageType: PackageType
    public let storeProduct: StoreProduct
    public let offeringIdentifier: String
    public var localizedPriceString: String { storeProduct.localizedPriceString }
    public var localizedIntroductoryPriceString: String? { storeProduct.introductoryDiscount?.localizedPriceString }
}

public struct Offering: Sendable {
    public let identifier: String
    public let serverDescription: String
    public let metadata: [String: String]
    public let availablePackages: [Package]
    public var lifetime: Package? { first(.lifetime) }
    public var annual: Package? { first(.annual) }
    public var sixMonth: Package? { first(.sixMonth) }
    public var threeMonth: Package? { first(.threeMonth) }
    public var twoMonth: Package? { first(.twoMonth) }
    public var monthly: Package? { first(.monthly) }
    public var weekly: Package? { first(.weekly) }
    public func package(identifier: String?) -> Package? { availablePackages.first { $0.identifier == identifier } }
    public subscript(key: String) -> Package? { package(identifier: key) }
    private func first(_ type: PackageType) -> Package? { availablePackages.first { $0.packageType == type } }
}

public struct Offerings: Sendable {
    public let all: [String: Offering]
    public let current: Offering?
    public func offering(identifier: String?) -> Offering? { identifier.flatMap { all[$0] } }
    public subscript(key: String) -> Offering? { all[key] }

    /// Attaches store products to the catalog. A package whose product the store did not return
    /// is left out; an offering with no purchasable package is left out too.
    public static func assemble(catalog: AplynaOfferingsCatalog, products: [String: StoreProduct], store: String = "apple") -> Offerings {
        var all: [String: Offering] = [:]
        for offering in catalog.offerings {
            let packages = offering.packages.compactMap { package -> Package? in
                guard let item = package.products.first(where: { $0.store == store && products[$0.identifier] != nil }), let product = products[item.identifier] else { return nil }
                return Package(identifier: package.identifier, packageType: .from(identifier: package.identifier), storeProduct: product, offeringIdentifier: offering.identifier)
            }
            if !packages.isEmpty { all[offering.identifier] = Offering(identifier: offering.identifier, serverDescription: offering.description ?? "", metadata: [:], availablePackages: packages) }
        }
        return Offerings(all: all, current: catalog.current.flatMap { all[$0] })
    }
}

public struct StoreTransaction: Sendable, Equatable {
    public let transactionIdentifier: String
    public let productIdentifier: String
    public let purchaseDate: Date
}

public typealias PurchaseResultData = (transaction: StoreTransaction?, customerInfo: CustomerInfo, userCancelled: Bool)

public enum CacheFetchPolicy: Int, Sendable {
    case fromCacheOnly = 0, fetchCurrent = 1, notStaleCachedOrFetched = 2, cachedOrFetched = 3
    public static let `default`: CacheFetchPolicy = .notStaleCachedOrFetched
}

public enum LogLevel: Int, Sendable { case verbose = 0, debug = 1, info = 2, warn = 3, error = 4 }

// MARK: - Attributes

/// Customer attributes with RevenueCat's reserved keys and limits.
public enum SubscriberAttributes {
    public static let email = "$email", displayName = "$displayName", phoneNumber = "$phoneNumber"
    public static let apnsTokens = "$apnsTokens", fcmTokens = "$fcmTokens"
    public static let reserved: Set<String> = [email, displayName, phoneNumber, apnsTokens, fcmTokens, "$idfa", "$idfv", "$gpsAdId", "$ip", "$attConsentStatus",
        "$mediaSource", "$campaign", "$adGroup", "$ad", "$keyword", "$creative", "$adjustId", "$appsflyerId", "$fbAnonId", "$mparticleId", "$onesignalId",
        "$airshipChannelId", "$cleverTapId", "$mixpanelDistinctId", "$firebaseAppInstanceId", "$posthogUserId", "$amplitudeUserId", "$amplitudeDeviceId"]

    /// Keys: letters, digits and underscores, at most 40 characters, `$` only for reserved keys.
    public static func isValidKey(_ key: String) -> Bool {
        if reserved.contains(key) { return true }
        guard !key.isEmpty, key.count <= 40, let first = key.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" } && key.allSatisfy(\.isASCII)
    }
    /// Values are at most 500 characters; nil or empty deletes the attribute.
    public static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(500))
    }
}

public enum AppUserIDs {
    public static let anonymousPrefix = "$AplynaAnonymousID:"
    public static func anonymous() -> String { anonymousPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    public static func isAnonymous(_ id: String) -> Bool { id.hasPrefix(anonymousPrefix) || id.hasPrefix("$RCAnonymousID:") }
    /// Same rules as RevenueCat: not empty, at most 100 characters, no `/`, and not a placeholder value.
    public static func isValid(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && id.count <= 100 && !id.contains("/") && !["null", "nil", "none", "undefined", "(null)", "nan", "unidentified", "no_user"].contains(trimmed.lowercased())
    }
}
