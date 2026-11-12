import XCTest
@testable import Aplyna
final class BillingTests: XCTestCase {
    func testDecodedAccessExpiresLocally() throws {
        let json = #"{"customerId":"customer","environment":"sandbox","checkedAt":"2026-01-01T00:00:00.000Z","entitlements":[{"identifier":"expired","active":true,"productId":"monthly","expiresAt":"2000-01-01T00:00:00.000Z"},{"identifier":"lifetime","active":true,"productId":"forever","expiresAt":null}]}"#
        let info = try JSONDecoder().decode(AplynaCustomerInfo.self, from: Data(json.utf8))
        XCTAssertFalse(info.hasAccess(to: "expired"))
        XCTAssertTrue(info.hasAccess(to: "lifetime"))
        XCTAssertFalse(info.hasAccess(to: "missing"))
    }
    func testPurchaseTransportRequiresHTTPS() throws {
        XCTAssertThrowsError(try AplynaBillingClient(gatewayURL: URL(string: "http://example.com/api/billing")!, sdkKey: "key", environment: .sandbox))
        _ = try AplynaBillingClient(gatewayURL: URL(string: "https://example.com/api/billing")!, sdkKey: "key", environment: .sandbox)
    }
    func testSandboxGuardRejectsProductionAndURLCredentialsBeforeStoreAccess() throws {
        XCTAssertThrowsError(try AplynaBillingClient(gatewayURL: URL(string: "https://example.com/api/billing")!, sdkKey: "key", environment: .production, sandboxOnly: true)) { error in
            XCTAssertEqual((error as? AplynaBillingError)?.code, "APLYNA_BILLING_ENVIRONMENT")
        }
        for raw in ["https://user:secret@example.com/api/billing", "https://example.com/api/billing?token=secret", "ftp://localhost/billing"] {
            XCTAssertThrowsError(try AplynaBillingClient(gatewayURL: URL(string: raw)!, sdkKey: "key", environment: .sandbox))
        }
    }
    func testBillingStatesDecodeWithoutConflatingGraceAndPaidAccess() throws {
        let json = #"{"customerId":"customer","environment":"sandbox","checkedAt":"2026-11-09T12:00:00Z","entitlements":[{"identifier":"pro","active":true,"productId":"weekly","expiresAt":"2099-11-09T12:00:00Z"}],"subscriptions":[{"provider":"apple","productId":"weekly","originalTransactionId":"chain","active":true,"status":"grace_period","expiresAt":"2099-11-09T12:00:00Z","autoRenew":true,"billingRetry":true,"gracePeriodExpiresAt":"2099-11-09T12:00:00Z"}]}"#
        let value = try JSONDecoder().decode(AplynaCustomerInfo.self, from: Data(json.utf8))
        XCTAssertTrue(value.hasAccess(to: "pro"))
        XCTAssertEqual(value.subscriptions?.first?.status, "grace_period")
        XCTAssertEqual(value.subscriptions?.first?.billingRetry, true)
    }
    func testBillingBridgeDoesNotRequireAnalyticsConsentAndRejectsTestStoreKeys() async throws {
        let bridge = AplynaBillingBridge()
        do {
            _ = try await bridge.invoke(method: "billing.configure", argumentsJSON: #"{"apiKey":"aplyna_test_example","environment":"sandbox","sandboxOnly":true,"gatewayUrl":"https://example.com/api/billing"}"#)
            XCTFail("Test Store catalog keys cannot process Apple purchases")
        } catch is AplynaBridgeError {}
        do { _ = try await bridge.invoke(method: "billing.purchase", argumentsJSON: #"{"productId":"weekly"}"#); XCTFail("Must configure billing independently") }
        catch AplynaBridgeError.notConfigured {}
    }
}
