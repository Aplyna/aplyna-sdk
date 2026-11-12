package com.aplyna.sdk

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PurchasesTests {
    private val now = billingDateMillis("2026-11-12T12:00:00Z")
    private fun info(entitlementExpiry: String? = "2026-11-12T12:05:00Z", provider: String = "google", autoRenew: Boolean? = true, retry: Boolean = false, trial: Boolean = false, active: Boolean = true, product: String = "subscription:monthly") =
        AplynaBillingCustomerInfo(JSONObject().put("customerId", "12345678-1234-1234-1234-123456789012").put("environment", "sandbox").put("checkedAt", "2026-11-12T11:59:00Z")
            .put("entitlements", JSONArray().apply { if (entitlementExpiry != null) put(JSONObject().put("identifier", "premium").put("active", true).put("productId", product).put("expiresAt", entitlementExpiry)) })
            .put("subscriptions", JSONArray().put(JSONObject().put("provider", provider).put("productId", product).put("originalTransactionId", "1").put("active", active)
                .put("status", "active").put("expiresAt", entitlementExpiry ?: "2026-11-12T11:00:00Z").put("autoRenew", autoRenew ?: JSONObject.NULL).put("billingRetry", retry)
                .put("gracePeriodExpiresAt", JSONObject.NULL).put("isTrial", trial))))

    @Test fun errorCodeNumbersMatchRevenueCat() {
        val expected = mapOf(PurchasesErrorCode.PurchaseCancelledError to 1, PurchasesErrorCode.StoreProblemError to 2, PurchasesErrorCode.PurchaseNotAllowedError to 3,
            PurchasesErrorCode.ProductNotAvailableForPurchaseError to 5, PurchasesErrorCode.ProductAlreadyPurchasedError to 6, PurchasesErrorCode.ReceiptAlreadyInUseError to 7,
            PurchasesErrorCode.NetworkError to 10, PurchasesErrorCode.InvalidCredentialsError to 11, PurchasesErrorCode.InvalidAppUserIdError to 14,
            PurchasesErrorCode.OperationAlreadyInProgressError to 15, PurchasesErrorCode.PaymentPendingError to 20, PurchasesErrorCode.LogOutWithAnonymousUserError to 22,
            PurchasesErrorCode.ConfigurationError to 23)
        expected.forEach { (code, number) -> assertEquals(number, code.code) }
        assertEquals("PURCHASE_CANCELLED", PurchasesErrorCode.PurchaseCancelledError.readableCode)
        assertEquals(PurchasesErrorCode.values().size, PurchasesErrorCode.values().map { it.code }.toSet().size)
    }

    @Test fun billingFailuresMapToRevenueCatCodes() {
        val cases = mapOf("APLYNA_BILLING_CANCELLED" to PurchasesErrorCode.PurchaseCancelledError, "APLYNA_BILLING_PENDING" to PurchasesErrorCode.PaymentPendingError,
            "APLYNA_BILLING_IN_PROGRESS" to PurchasesErrorCode.OperationAlreadyInProgressError, "APLYNA_BILLING_ALREADY_OWNED" to PurchasesErrorCode.ProductAlreadyPurchasedError,
            "APLYNA_BILLING_UNAVAILABLE" to PurchasesErrorCode.StoreProblemError, "APLYNA_BILLING_UNSUPPORTED" to PurchasesErrorCode.PurchaseNotAllowedError,
            "APLYNA_BILLING_STORE_4" to PurchasesErrorCode.ProductNotAvailableForPurchaseError, "APLYNA_BILLING_STORE_5" to PurchasesErrorCode.PurchaseInvalidError,
            "APLYNA_BILLING_STORE_6" to PurchasesErrorCode.StoreProblemError, "APLYNA_BILLING_CUSTOMER_CONFLICT" to PurchasesErrorCode.ReceiptAlreadyInUseError,
            "APLYNA_HTTP_409" to PurchasesErrorCode.ReceiptAlreadyInUseError, "APLYNA_HTTP_401" to PurchasesErrorCode.InvalidCredentialsError,
            "APLYNA_HTTP_422" to PurchasesErrorCode.PurchaseInvalidError, "APLYNA_HTTP_503" to PurchasesErrorCode.UnknownBackendError,
            "APLYNA_BILLING_OFFLINE" to PurchasesErrorCode.NetworkError, "APLYNA_BILLING_SCOPE" to PurchasesErrorCode.ConfigurationError,
            "APLYNA_BILLING_RESPONSE" to PurchasesErrorCode.UnexpectedBackendResponseError, "SOMETHING_ELSE" to PurchasesErrorCode.UnknownError)
        cases.forEach { (source, expected) -> assertEquals(source, expected, PurchasesError.code(source)) }
        val mapped = PurchasesError.from(AplynaBillingException("APLYNA_BILLING_CANCELLED", "closed"))
        assertEquals(PurchasesErrorCode.PurchaseCancelledError, mapped.code); assertEquals("closed", mapped.underlyingErrorMessage)
        assertEquals(PurchasesErrorCode.NetworkError, PurchasesError.from(java.io.IOException("reset")).code)
        assertTrue(PurchasesTransactionException(mapped, true).userCancelled)
    }

    @Test fun activePaidSubscriptionMapsToEntitlementInfo() {
        val value = CustomerInfo.from(info(), "user_1", now)
        val premium = value.entitlements["premium"]!!
        assertTrue(premium.isActive); assertTrue(premium.willRenew)
        assertEquals(PeriodType.NORMAL, premium.periodType); assertEquals(Store.PLAY_STORE, premium.store); assertTrue(premium.isSandbox)
        assertEquals("subscription", premium.productIdentifier); assertEquals("monthly", premium.productPlanIdentifier)
        assertNull(premium.billingIssueDetectedAt); assertNull(premium.unsubscribeDetectedAt)
        assertEquals(setOf("premium"), value.entitlements.active.keys)
        assertEquals(setOf("subscription:monthly"), value.activeSubscriptions); assertEquals("user_1", value.originalAppUserId)
        assertEquals(billingDateMillis("2026-11-12T12:05:00Z"), value.latestExpirationDate!!.time)
        assertEquals(value.getExpirationDateForEntitlement("premium"), value.getExpirationDateForProductId("subscription:monthly"))
        assertEquals("https://play.google.com/store/account/subscriptions", value.managementUrlString)
    }

    @Test fun trialCancelledAndBillingIssueStates() {
        val trial = CustomerInfo.from(info(autoRenew = false, trial = true), "u", now).entitlements["premium"]!!
        // Cancelling keeps access until the paid or trial period ends.
        assertEquals(PeriodType.TRIAL, trial.periodType); assertTrue(trial.isActive); assertFalse(trial.willRenew); assertNotNull(trial.unsubscribeDetectedAt)
        val grace = CustomerInfo.from(info(retry = true), "u", now).entitlements["premium"]!!
        // Grace keeps access, but a billing issue is reported and the subscription is not set to renew.
        assertTrue(grace.isActive); assertFalse(grace.willRenew); assertNotNull(grace.billingIssueDetectedAt)
        // Renewal intent Google has not reported stays unknown rather than true.
        assertFalse(CustomerInfo.from(info(autoRenew = null), "u", now).entitlements["premium"]!!.willRenew)
    }

    @Test fun cachedAnswerNeverGrantsAccessPastItsVerifiedExpiry() {
        val stale = CustomerInfo.from(info(entitlementExpiry = "2026-11-12T11:30:00Z"), "u", now)
        assertFalse(stale.entitlements["premium"]!!.isActive); assertTrue(stale.entitlements.active.isEmpty()); assertTrue(stale.activeSubscriptions.isEmpty())
        assertEquals(setOf("subscription:monthly"), stale.allPurchasedProductIds)
        val none = CustomerInfo.from(info(entitlementExpiry = null, active = false), "u", now)
        assertTrue(none.entitlements.all.isEmpty())
    }

    private fun phase(price: String, micros: String, period: String) = AplynaBillingPricingPhase(price, micros, "EUR", period, 1, 1)
    private val monthly = AplynaBillingProduct("subscription:monthly", "Premium", "€10.99", "subscription", "monthly", listOf(
        AplynaBillingOffer("monthly", null, "token-regular", listOf(phase("€10.99", "10990000", "P1M")), emptyList()),
        AplynaBillingOffer("monthly", "trial", "token-trial", listOf(phase("Free", "0", "P1W"), phase("€10.99", "10990000", "P1M")), emptyList())))
    private val annual = AplynaBillingProduct("subscription:annual", "Premium", "€59.99", "subscription", "annual", listOf(
        AplynaBillingOffer("annual", null, "token-annual", listOf(phase("€59.99", "59990000", "P1Y")), emptyList())))

    @Test fun offeringsAttachStoreProductsAndKeepRevenueCatPackageNames() {
        val catalog = JSONObject("""{"project_id":"p","revision":3,"current":"default","offerings":[{"identifier":"default","description":"Standard","packages":[
            {"identifier":"${'$'}rc_monthly","description":"Monthly","products":[{"identifier":"monthly","store":"apple","entitlements":["premium"]},{"identifier":"subscription:monthly","store":"google","entitlements":["premium"]}]},
            {"identifier":"${'$'}rc_annual","description":"Annual","products":[{"identifier":"subscription:annual","store":"google","entitlements":["premium"]}]},
            {"identifier":"vip","description":"VIP","products":[{"identifier":"subscription:missing","store":"google","entitlements":[]}]}]},
            {"identifier":"empty","description":"","packages":[]}]}""")
        val offerings = Offerings.assemble(catalog, listOf(monthly, annual))
        val current = offerings.current!!
        assertEquals("default", current.identifier); assertEquals("Standard", current.serverDescription)
        // The package whose product the store did not return is omitted; so is the empty offering.
        assertEquals(listOf("\$rc_monthly", "\$rc_annual"), current.availablePackages.map { it.identifier })
        val pack = current.monthly!!
        assertEquals(PackageType.MONTHLY, pack.packageType); assertEquals("default", pack.offering)
        assertEquals("subscription:monthly", pack.product.id); assertEquals("subscription", pack.product.productId); assertEquals("monthly", pack.product.basePlanId)
        assertEquals("€10.99", pack.product.price.formatted); assertEquals(10990000L, pack.product.price.amountMicros); assertEquals("EUR", pack.product.price.currencyCode)
        assertEquals(Period(1, Period.Unit.MONTH, "P1M"), pack.product.period); assertEquals(Period(1, Period.Unit.WEEK, "P1W"), pack.product.freeTrialPeriod)
        assertEquals("€59.99", current.annual!!.product.price.formatted); assertNull(current.annual!!.product.freeTrialPeriod)
        assertNull(current.weekly); assertNull(current["vip"]); assertNull(offerings["empty"]); assertEquals(1, offerings.all.size)
    }

    @Test fun noConfiguredOfferingsGivesEmptyOfferingsWithNoCurrent() {
        val offerings = Offerings.assemble(JSONObject("""{"project_id":"p","revision":1,"current":null,"offerings":[]}"""), listOf(monthly))
        assertNull(offerings.current); assertTrue(offerings.all.isEmpty())
    }

    @Test fun packageTypesPeriodsIdentityAndAttributeRules() {
        assertEquals(PackageType.SIX_MONTH, PackageType.from("\$rc_six_month")); assertEquals(PackageType.WEEKLY, PackageType.from("Weekly")); assertEquals(PackageType.CUSTOM, PackageType.from("launch_promo"))
        assertEquals(Period.Unit.UNKNOWN, Period.create("garbage").unit); assertEquals(3, Period.create("P3D").value)
        assertTrue(AppUserIDs.isValid("user_123"))
        for (bad in listOf("", "   ", "null", "NIL", "undefined", "a/b", "x".repeat(101))) assertFalse(bad, AppUserIDs.isValid(bad))
        val anonymous = AppUserIDs.anonymous()
        assertTrue(AppUserIDs.isAnonymous(anonymous)); assertTrue(AppUserIDs.isAnonymous("\$RCAnonymousID:abc")); assertFalse(AppUserIDs.isAnonymous("user_123")); assertNotEquals(anonymous, AppUserIDs.anonymous())
        for (good in listOf("plan", "favorite_color", "a1", "\$email", "\$displayName", "\$fcmTokens")) assertTrue(good, SubscriberAttributes.isValidKey(good))
        for (bad in listOf("", "1abc", "\$custom", "with space", "dash-ed", "k".repeat(41), "émail")) assertFalse(bad, SubscriberAttributes.isValidKey(bad))
        assertNull(SubscriberAttributes.normalized(null)); assertNull(SubscriberAttributes.normalized("")); assertEquals(500, SubscriberAttributes.normalized("v".repeat(600))!!.length)
        assertEquals(CacheFetchPolicy.NOT_STALE_CACHED_OR_CURRENT, CacheFetchPolicy.default())
    }

    @Test fun offeringsAreReadBesideTheGatewayAndAttributesGoThroughIt() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("{\"current\":null,\"offerings\":[]}")); server.enqueue(MockResponse().setBody("{\"current\":null,\"offerings\":[]}"))
            server.enqueue(MockResponse().setBody("{\"accepted\":1}")); server.start()
            val gateway = BillingGateway(server.url("/api/billing").toString(), "aplyna_android_public_test")
            gateway.offerings(null); assertEquals("/api/v1/offerings", server.takeRequest().path)
            gateway.offerings("prj 1")
            val second = server.takeRequest()
            assertEquals("/api/v1/offerings?project_id=prj+1", second.path); assertEquals("Bearer aplyna_android_public_test", second.getHeader("Authorization"))
            val identity = JSONObject().put("customerToken", "private_customer_test_token")
            val body = JSONObject().put("attributes", JSONObject().put("plan", JSONObject().put("value", "gold").put("updatedAtMs", 1)))
            assertEquals(1, gateway.request("v1/customers/one/attributes", identity, body).getInt("accepted"))
            val third = server.takeRequest()
            assertEquals("POST", third.method); assertEquals("/api/billing/v1/customers/one/attributes", third.path)
            assertEquals("private_customer_test_token", third.getHeader("X-Aplyna-Customer-Token"))
        }
    }

    @Test fun unreachableGatewayReportsAStableNetworkCode() {
        val server = MockWebServer(); server.start()
        val url = server.url("/api/billing").toString(); server.shutdown()
        try { BillingGateway(url, "aplyna_android_public_test").request("v1/customers/one"); fail("expected a network failure") }
        catch (error: AplynaBillingException) {
            assertTrue(error.code, error.code in setOf("APLYNA_BILLING_OFFLINE", "APLYNA_BILLING_NETWORK"))
            assertEquals(PurchasesErrorCode.NetworkError, PurchasesError.from(error).code)
        }
    }
}

class PurchasesBridgeTests {
    @Test fun hybridJsonUsesRevenueCatFieldNames() {
        val source = AplynaBillingCustomerInfo(JSONObject().put("customerId", "12345678-1234-1234-1234-123456789012").put("environment", "sandbox").put("checkedAt", "2026-11-12T11:59:00Z")
            .put("entitlements", JSONArray().put(JSONObject().put("identifier", "premium").put("active", true).put("productId", "subscription:monthly").put("expiresAt", "2099-01-01T00:00:00Z")))
            .put("subscriptions", JSONArray().put(JSONObject().put("provider", "google").put("productId", "subscription:monthly").put("originalTransactionId", "1").put("active", true)
                .put("status", "active").put("expiresAt", "2099-01-01T00:00:00Z").put("autoRenew", true).put("billingRetry", false).put("gracePeriodExpiresAt", JSONObject.NULL).put("isTrial", true))))
        val json = PurchasesBridge.json(CustomerInfo.from(source, "user_1"))
        val premium = json.getJSONObject("entitlements").getJSONObject("active").getJSONObject("premium")
        assertTrue(premium.getBoolean("isActive")); assertEquals("TRIAL", premium.getString("periodType")); assertEquals("PLAY_STORE", premium.getString("store"))
        assertEquals("subscription", premium.getString("productIdentifier")); assertEquals("monthly", premium.getString("productPlanIdentifier"))
        assertEquals("user_1", json.getString("originalAppUserId")); assertEquals("subscription:monthly", json.getJSONArray("activeSubscriptions").getString(0))
        assertEquals("2099-01-01T00:00:00.000Z", json.getJSONObject("allExpirationDates").getString("subscription:monthly"))

        val product = StoreProduct("subscription:monthly", ProductType.SUBS, Price("€10.99", 10990000, "EUR"), "Premium", "", Period.create("P1M"), "subscription", "monthly", Period.create("P1W"), null)
        val offering = Offering("default", "Standard", emptyMap(), listOf(Package("\$rc_monthly", PackageType.MONTHLY, product, PresentedOfferingContext("default"))))
        val monthly = PurchasesBridge.json(Offerings(offering, mapOf("default" to offering))).getJSONObject("current").getJSONObject("monthly")
        assertEquals("MONTHLY", monthly.getString("packageType"))
        val encoded = monthly.getJSONObject("product")
        assertEquals("€10.99", encoded.getString("priceString")); assertEquals(10.99, encoded.getDouble("price"), 0.0001); assertEquals("P1M", encoded.getString("subscriptionPeriod"))
        assertEquals("WEEK", encoded.getJSONObject("introPrice").getString("periodUnit"))
    }

    @Test fun bridgeErrorsCarryNumericCodeAndUserCancelled() {
        val cancelled = PurchasesBridge.errorPayload(AplynaBillingException("APLYNA_BILLING_CANCELLED", "closed"))
        assertEquals("1", cancelled.first); assertTrue(cancelled.third.getBoolean("userCancelled")); assertEquals("PURCHASE_CANCELLED", cancelled.third.getString("readableErrorCode"))
        val offline = PurchasesBridge.errorPayload(AplynaBillingException("APLYNA_BILLING_OFFLINE", "offline"))
        assertEquals("10", offline.first); assertFalse(offline.third.getBoolean("userCancelled"))
    }
}
