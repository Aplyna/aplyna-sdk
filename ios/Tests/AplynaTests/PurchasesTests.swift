import XCTest
import StoreKit
@testable import Aplyna

final class PurchasesTests: XCTestCase {
    private func info(_ json: String) throws -> AplynaCustomerInfo { try JSONDecoder().decode(AplynaCustomerInfo.self, from: Data(json.utf8)) }
    private let now = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!

    // MARK: Errors

    func testThrownErrorsCastToErrorCodeLikeRevenueCat() {
        let error: Error = PurchasesErrors.make(.networkError)
        XCTAssertEqual(error as? ErrorCode, .networkError)
        XCTAssertEqual((error as NSError).code, 10)
        XCTAssertEqual((error as NSError).userInfo[PurchasesErrors.readableErrorCodeKey] as? String, "NETWORK_ERROR")
    }

    func testErrorCodeNumbersMatchRevenueCat() {
        let expected: [(ErrorCode, Int, String)] = [
            (.purchaseCancelledError, 1, "PURCHASE_CANCELLED"), (.storeProblemError, 2, "STORE_PROBLEM"), (.purchaseNotAllowedError, 3, "PURCHASE_NOT_ALLOWED"),
            (.productNotAvailableForPurchaseError, 5, "PRODUCT_NOT_AVAILABLE_FOR_PURCHASE"), (.receiptAlreadyInUseError, 7, "RECEIPT_ALREADY_IN_USE"),
            (.invalidReceiptError, 8, "INVALID_RECEIPT"), (.networkError, 10, "NETWORK_ERROR"), (.invalidCredentialsError, 11, "INVALID_CREDENTIALS"),
            (.invalidAppUserIdError, 14, "INVALID_APP_USER_ID"), (.operationAlreadyInProgressForProductError, 15, "OPERATION_ALREADY_IN_PROGRESS"),
            (.paymentPendingError, 20, "PAYMENT_PENDING_ERROR"), (.logOutAnonymousUserError, 22, "LOGOUT_CALLED_WITH_ANONYMOUS_USER"),
            (.configurationError, 23, "CONFIGURATION_ERROR"), (.offlineConnectionError, 35, "OFFLINE_CONNECTION_ERROR"),
        ]
        for (code, number, readable) in expected { XCTAssertEqual(code.rawValue, number); XCTAssertEqual(code.readableCode, readable) }
    }

    func testBillingFailuresMapToRevenueCatCodes() {
        let cases: [(AplynaBillingError, ErrorCode)] = [
            (.cancelled, .purchaseCancelledError), (.pending, .paymentPendingError), (.busy, .operationAlreadyInProgressForProductError),
            (.unmappedProduct, .productNotAvailableForPurchaseError), (.unverifiedPurchase, .invalidReceiptError),
            (.customerConflict, .receiptAlreadyInUseError), (.environmentMismatch, .configurationError), (.invalidResponse, .unexpectedBackendResponseError),
            (.network(code: -1004, offline: false), .networkError), (.network(code: -1009, offline: true), .offlineConnectionError),
            (.server(401, "x"), .invalidCredentialsError), (.server(403, "x"), .invalidCredentialsError), (.server(409, "x"), .receiptAlreadyInUseError),
            (.server(422, "x"), .purchaseInvalidError), (.server(503, "x"), .unknownBackendError),
        ]
        for (source, expected) in cases { XCTAssertEqual(PurchasesErrors.map(source) as Error as? ErrorCode, expected, "\(source)") }
        XCTAssertEqual(PurchasesErrors.map(URLError(.notConnectedToInternet)) as Error as? ErrorCode, .offlineConnectionError)
        XCTAssertEqual(PurchasesErrors.map(URLError(.timedOut)) as Error as? ErrorCode, .networkError)
        XCTAssertEqual(PurchasesErrors.map(StoreKitError.userCancelled) as Error as? ErrorCode, .purchaseCancelledError)
        XCTAssertEqual(PurchasesErrors.map(StoreKitError.notAvailableInStorefront) as Error as? ErrorCode, .productNotAvailableForPurchaseError)
        XCTAssertEqual(PurchasesErrors.map(Product.PurchaseError.purchaseNotAllowed) as Error as? ErrorCode, .purchaseNotAllowedError)
        XCTAssertEqual(PurchasesErrors.map(Product.PurchaseError.ineligibleForOffer) as Error as? ErrorCode, .ineligibleError)
    }

    func testOfflineTransportErrorNoLongerLeaksRawURLErrorCode() {
        let error = AplynaBillingError.network(code: -1004, offline: false)
        XCTAssertEqual(error.code, "APLYNA_BILLING_NETWORK")
        XCTAssertEqual(AplynaBillingError.network(code: -1009, offline: true).code, "APLYNA_BILLING_OFFLINE")
        XCTAssertFalse(error.localizedDescription.contains("NSURLErrorDomain"))
    }

    // MARK: Customer info

    func testActivePaidSubscriptionMapsToEntitlementInfo() throws {
        let source = try info(#"{"customerId":"c","environment":"sandbox","checkedAt":"2026-11-12T11:59:00Z","entitlements":[{"identifier":"premium","active":true,"productId":"monthly","expiresAt":"2026-11-12T12:05:00Z"}],"subscriptions":[{"provider":"apple","productId":"monthly","originalTransactionId":"1","active":true,"status":"active","expiresAt":"2026-11-12T12:05:00Z","autoRenew":true,"billingRetry":false,"gracePeriodExpiresAt":null,"isTrial":false}]}"#)
        let value = CustomerInfo(source, appUserID: "user_1", now: now)
        let premium = try XCTUnwrap(value.entitlements["premium"])
        XCTAssertTrue(premium.isActive); XCTAssertTrue(premium.willRenew)
        XCTAssertEqual(premium.periodType, .normal); XCTAssertEqual(premium.store, .appStore); XCTAssertTrue(premium.isSandbox)
        XCTAssertNil(premium.billingIssueDetectedAt); XCTAssertNil(premium.unsubscribeDetectedAt)
        XCTAssertEqual(value.entitlements.active.keys.sorted(), ["premium"])
        XCTAssertEqual(value.activeSubscriptions, ["monthly"]); XCTAssertEqual(value.allPurchasedProductIdentifiers, ["monthly"])
        XCTAssertEqual(value.originalAppUserId, "user_1")
        XCTAssertEqual(value.latestExpirationDate, ISO8601DateFormatter().date(from: "2026-11-12T12:05:00Z"))
        XCTAssertEqual(value.expirationDate(forEntitlement: "premium"), value.expirationDate(forProductIdentifier: "monthly"))
        XCTAssertEqual(value.managementURL?.host, "apps.apple.com")
    }

    func testTrialCancelledAndBillingIssueStates() throws {
        let trial = CustomerInfo(try info(#"{"customerId":"c","environment":"production","checkedAt":"2026-11-12T11:59:00Z","entitlements":[{"identifier":"premium","active":true,"productId":"annual","expiresAt":"2026-11-19T12:00:00Z"}],"subscriptions":[{"provider":"google","productId":"annual","originalTransactionId":"1","active":true,"status":"active","expiresAt":"2026-11-19T12:00:00Z","autoRenew":false,"billingRetry":false,"gracePeriodExpiresAt":null,"isTrial":true}]}"#), appUserID: "u", now: now)
        let first = try XCTUnwrap(trial.entitlements["premium"])
        XCTAssertEqual(first.periodType, .trial); XCTAssertEqual(first.store, .playStore); XCTAssertFalse(first.isSandbox)
        // Cancelling keeps access until the paid or trial period ends.
        XCTAssertTrue(first.isActive); XCTAssertFalse(first.willRenew); XCTAssertNotNil(first.unsubscribeDetectedAt)

        let grace = CustomerInfo(try info(#"{"customerId":"c","environment":"sandbox","checkedAt":"2026-11-12T11:59:00Z","entitlements":[{"identifier":"premium","active":true,"productId":"monthly","expiresAt":"2026-11-12T12:04:00Z"}],"subscriptions":[{"provider":"apple","productId":"monthly","originalTransactionId":"1","active":true,"status":"grace_period","expiresAt":"2026-11-12T12:04:00Z","autoRenew":true,"billingRetry":true,"gracePeriodExpiresAt":"2026-11-12T12:04:00Z"}]}"#), appUserID: "u", now: now)
        let second = try XCTUnwrap(grace.entitlements["premium"])
        // Grace keeps access, but a billing issue is reported and the subscription is not set to renew.
        XCTAssertTrue(second.isActive); XCTAssertFalse(second.willRenew); XCTAssertNotNil(second.billingIssueDetectedAt)
    }

    func testCachedAnswerNeverGrantsAccessPastItsVerifiedExpiry() throws {
        let source = try info(#"{"customerId":"c","environment":"sandbox","checkedAt":"2026-11-12T11:00:00Z","entitlements":[{"identifier":"premium","active":true,"productId":"monthly","expiresAt":"2026-11-12T11:30:00Z"}],"subscriptions":[{"provider":"apple","productId":"monthly","originalTransactionId":"1","active":true,"status":"active","expiresAt":"2026-11-12T11:30:00Z","autoRenew":true,"billingRetry":false,"gracePeriodExpiresAt":null}]}"#)
        let stale = CustomerInfo(source, appUserID: "u", now: now)
        XCTAssertEqual(stale.entitlements["premium"]?.isActive, false)
        XCTAssertTrue(stale.entitlements.active.isEmpty)
        XCTAssertTrue(stale.activeSubscriptions.isEmpty)
        XCTAssertEqual(stale.allPurchasedProductIdentifiers, ["monthly"])
    }

    func testNoPurchasesGivesEmptyCustomerInfoNotAnError() throws {
        let empty = CustomerInfo(try info(#"{"customerId":"c","environment":"sandbox","checkedAt":"2026-11-12T11:59:00Z","entitlements":[],"subscriptions":[]}"#), appUserID: "u", now: now)
        XCTAssertTrue(empty.entitlements.all.isEmpty); XCTAssertNil(empty.latestExpirationDate); XCTAssertNil(empty.managementURL)
    }

    // MARK: Offerings

    private func catalog(_ json: String) throws -> AplynaOfferingsCatalog { try JSONDecoder().decode(AplynaOfferingsCatalog.self, from: Data(json.utf8)) }

    func testOfferingsAttachStoreProductsAndKeepRevenueCatPackageNames() throws {
        let source = try catalog(#"{"project_id":"p","revision":3,"current":"default","offerings":[{"identifier":"default","description":"Standard","packages":[{"identifier":"$rc_monthly","description":"Monthly","products":[{"identifier":"g_monthly","store":"google","app_identifier":"x","duration":"Monthly","entitlements":["premium"]},{"identifier":"monthly","store":"apple","app_identifier":"x","duration":"Monthly","entitlements":["premium"]}]},{"identifier":"$rc_annual","description":"Annual","products":[{"identifier":"annual","store":"apple","app_identifier":"x","duration":"Annual","entitlements":["premium"]}]},{"identifier":"vip","description":"VIP","products":[{"identifier":"missing","store":"apple","app_identifier":"x","duration":"Monthly","entitlements":[]}]}]},{"identifier":"empty","description":"","packages":[]}]}"#)
        let products = ["monthly": StoreProduct(productIdentifier: "monthly", localizedPriceString: "9,99 €"), "annual": StoreProduct(productIdentifier: "annual", localizedPriceString: "44,99 €")]
        let offerings = Offerings.assemble(catalog: source, products: products)
        let current = try XCTUnwrap(offerings.current)
        XCTAssertEqual(current.identifier, "default"); XCTAssertEqual(current.serverDescription, "Standard")
        // The package whose product the store did not return is omitted; so is the empty offering.
        XCTAssertEqual(current.availablePackages.map(\.identifier), ["$rc_monthly", "$rc_annual"])
        XCTAssertEqual(current.monthly?.storeProduct.productIdentifier, "monthly")
        XCTAssertEqual(current.annual?.localizedPriceString, "44,99 €")
        XCTAssertEqual(current.monthly?.packageType, .monthly); XCTAssertEqual(current.monthly?.offeringIdentifier, "default")
        XCTAssertNil(current.weekly); XCTAssertNil(current["vip"])
        XCTAssertNil(offerings["empty"]); XCTAssertEqual(offerings.all.count, 1)
        XCTAssertEqual(offerings.offering(identifier: "default")?.identifier, "default")
    }

    func testNoConfiguredOfferingsGivesEmptyOfferingsWithNoCurrent() throws {
        let offerings = Offerings.assemble(catalog: try catalog(#"{"project_id":"p","revision":1,"current":null,"offerings":[]}"#), products: [:])
        XCTAssertNil(offerings.current); XCTAssertTrue(offerings.all.isEmpty)
    }

    func testPackageTypeFromIdentifier() {
        XCTAssertEqual(PackageType.from(identifier: "$rc_six_month"), .sixMonth)
        XCTAssertEqual(PackageType.from(identifier: "$rc_lifetime"), .lifetime)
        XCTAssertEqual(PackageType.from(identifier: "Weekly"), .weekly)
        XCTAssertEqual(PackageType.from(identifier: "launch_promo"), .custom)
    }

    // MARK: Identity and attributes

    func testAppUserIDRulesMatchRevenueCat() {
        XCTAssertTrue(AppUserIDs.isValid("user_123"))
        for bad in ["", "   ", "null", "NIL", "undefined", "a/b", String(repeating: "x", count: 101)] { XCTAssertFalse(AppUserIDs.isValid(bad), bad) }
        let anonymous = AppUserIDs.anonymous()
        XCTAssertTrue(AppUserIDs.isAnonymous(anonymous)); XCTAssertTrue(AppUserIDs.isAnonymous("$RCAnonymousID:abc")); XCTAssertFalse(AppUserIDs.isAnonymous("user_123"))
        XCTAssertNotEqual(anonymous, AppUserIDs.anonymous())
    }

    func testAttributeKeyAndValueRules() {
        for good in ["plan", "favorite_color", "a1", "$email", "$displayName", "$apnsTokens"] { XCTAssertTrue(SubscriberAttributes.isValidKey(good), good) }
        for bad in ["", "1abc", "$custom", "with space", "dash-ed", String(repeating: "k", count: 41), "émail"] { XCTAssertFalse(SubscriberAttributes.isValidKey(bad), bad) }
        XCTAssertNil(SubscriberAttributes.normalized(nil)); XCTAssertNil(SubscriberAttributes.normalized(""))
        XCTAssertEqual(SubscriberAttributes.normalized(String(repeating: "v", count: 600))?.count, 500)
    }

    func testConfigurationBuilderMatchesRevenueCatShape() {
        let configuration = Configuration.builder(withAPIKey: "aplyna_ios_key").with(appUserID: "user_1").build()
        XCTAssertEqual(configuration.apiKey, "aplyna_ios_key"); XCTAssertEqual(configuration.appUserID, "user_1")
        XCTAssertEqual(configuration.gatewayURL.absoluteString, "https://aplyna.com/api/billing")
        XCTAssertEqual(CacheFetchPolicy.default, .notStaleCachedOrFetched)
    }
}

final class PurchasesBridgeTests: XCTestCase {
    func testHybridJSONUsesRevenueCatFieldNames() throws {
        let source = try JSONDecoder().decode(AplynaCustomerInfo.self, from: Data(#"{"customerId":"c","environment":"sandbox","checkedAt":"2026-11-12T11:59:00Z","entitlements":[{"identifier":"premium","active":true,"productId":"monthly","expiresAt":"2099-01-01T00:00:00Z"}],"subscriptions":[{"provider":"apple","productId":"monthly","originalTransactionId":"1","active":true,"status":"active","expiresAt":"2099-01-01T00:00:00Z","autoRenew":true,"billingRetry":false,"gracePeriodExpiresAt":null,"isTrial":true}]}"#.utf8))
        let json = PurchasesBridge.json(CustomerInfo(source, appUserID: "user_1"))
        let entitlements = try XCTUnwrap(json["entitlements"] as? [String: Any])
        let premium = try XCTUnwrap((entitlements["active"] as? [String: Any])?["premium"] as? [String: Any])
        XCTAssertEqual(premium["isActive"] as? Bool, true); XCTAssertEqual(premium["periodType"] as? String, "TRIAL")
        XCTAssertEqual(premium["store"] as? String, "APP_STORE"); XCTAssertEqual(premium["productIdentifier"] as? String, "monthly")
        XCTAssertEqual(json["originalAppUserId"] as? String, "user_1"); XCTAssertEqual(json["activeSubscriptions"] as? [String], ["monthly"])
        XCTAssertNotNil((json["allExpirationDates"] as? [String: String])?["monthly"])

        let product = StoreProduct(productIdentifier: "monthly", localizedTitle: "Monthly", price: Decimal(string: "9.99")!, localizedPriceString: "9,99 €", currencyCode: "EUR",
                                   subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .month),
                                   introductoryDiscount: StoreProductDiscount(offerIdentifier: nil, price: 0, localizedPriceString: "0 €", paymentMode: .freeTrial, subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .week), numberOfPeriods: 1))
        let offering = Offering(identifier: "default", serverDescription: "Standard", metadata: [:], availablePackages: [Package(identifier: "$rc_monthly", packageType: .monthly, storeProduct: product, offeringIdentifier: "default")])
        let offerings = PurchasesBridge.json(Offerings(all: ["default": offering], current: offering))
        let current = try XCTUnwrap(offerings["current"] as? [String: Any])
        let monthly = try XCTUnwrap(current["monthly"] as? [String: Any])
        XCTAssertEqual(monthly["packageType"] as? String, "MONTHLY")
        let encoded = try XCTUnwrap(monthly["product"] as? [String: Any])
        XCTAssertEqual(encoded["priceString"] as? String, "9,99 €"); XCTAssertEqual(encoded["subscriptionPeriod"] as? String, "P1M")
        XCTAssertEqual((encoded["introPrice"] as? [String: Any])?["periodUnit"] as? String, "WEEK")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(offerings)); XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    func testBridgeErrorsCarryNumericCodeAndUserCancelled() async {
        let cancelled = PurchasesBridge.errorPayload(PurchasesErrors.make(.purchaseCancelledError))
        XCTAssertEqual(cancelled.code, "1"); XCTAssertEqual(cancelled.details["userCancelled"] as? Bool, true)
        XCTAssertEqual(cancelled.details["readableErrorCode"] as? String, "PURCHASE_CANCELLED")
        let offline = PurchasesBridge.errorPayload(AplynaBillingError.network(code: -1009, offline: true))
        XCTAssertEqual(offline.code, "35"); XCTAssertEqual(offline.details["userCancelled"] as? Bool, false)
        do { _ = try await PurchasesBridge().invoke(method: "purchases.configure", argumentsJSON: #"{"apiKey":"aplyna_test_x"}"#); XCTFail("Test Store keys must be refused") }
        catch { XCTAssertEqual(error as? ErrorCode, .invalidCredentialsError) }
    }
}
