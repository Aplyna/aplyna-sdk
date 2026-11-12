package com.aplyna.sdk

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer

class BillingTests {
    private fun info(active: Boolean = true, expires: String = "2026-11-10T15:00:00.000Z") = AplynaBillingCustomerInfo(JSONObject()
        .put("customerId", "12345678-1234-1234-1234-123456789012").put("environment", "sandbox").put("checkedAt", "2026-11-10T14:00:00.000Z")
        .put("entitlements", JSONArray().apply { if (active) put(JSONObject().put("identifier", "premium").put("active", true).put("productId", "subscription:monthly").put("expiresAt", expires)) }))

    @Test fun cancelledRenewalRetainsOnlyTheVerifiedPaidPeriod() {
        val value = info()
        assertTrue(value.hasAccessTo("premium", billingDateMillis("2026-11-10T14:59:59.999Z")))
        assertFalse(value.hasAccessTo("premium", billingDateMillis("2026-11-10T15:00:00.000Z")))
        assertFalse(value.hasAccessTo("another", billingDateMillis("2026-11-10T14:00:00.000Z")))
    }
    @Test fun billingRetryAndExpiredGraceCannotInventAnEntitlement() {
        val now = billingDateMillis("2026-11-10T14:00:00.000Z")
        assertFalse(info(false).hasAccessTo("premium", now))
        assertTrue(info(expires = "2026-11-10T14:01:00.000Z").hasAccessTo("premium", now))
        assertFalse(info(expires = "2026-11-10T14:01:00.000Z").hasAccessTo("premium", now + 60_000))
    }
    @Test fun malformedAndImpossibleDatesFailClosed() {
        for (date in listOf("", "invalid", "2026-02-30T00:00:00.000Z", "2026-11-10T15:00:00.000Zextra", "2026-11-10T99:00:00Z")) {
            try { info(expires = date); fail("Invalid expiry accepted") }
            catch (e: AplynaBillingException) { assertEquals("APLYNA_BILLING_RESPONSE", e.code) }
        }
    }
    @Test fun catalogPlansKeepTheirExactStoreReference() {
        val monthly = BillingCatalogProduct.parse("premium_subscription:monthly")
        assertEquals("premium_subscription", monthly.productId)
        assertEquals("monthly", monthly.basePlanId)
        assertEquals("premium_subscription:monthly", monthly.id)
        assertNull(BillingCatalogProduct.parse("legacy_product").basePlanId)
        for (id in listOf(":monthly", "product:", "product:monthly:other", "product/path:monthly", "product:monthly plan")) {
            try { BillingCatalogProduct.parse(id); fail("Ambiguous plan accepted") }
            catch (e: AplynaBillingException) { assertEquals("APLYNA_BILLING_PRODUCT", e.code) }
        }
    }
    @Test fun gatewayUsesTheExactCustomerAndAndroidAppKey() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("{\"customerId\":\"one\"}")); server.start()
            val gateway = BillingGateway(server.url("/api/billing").toString(), "aplyna_android_public_test")
            val identity = JSONObject().put("customerToken", "private_customer_test_token")
            val response = gateway.request("v1/customers/one", identity)
            assertEquals("one", response.getString("customerId"))
            val request = server.takeRequest()
            assertEquals("/api/billing/v1/customers/one", request.path)
            assertEquals("Bearer aplyna_android_public_test", request.getHeader("Authorization"))
            assertEquals("private_customer_test_token", request.getHeader("X-Aplyna-Customer-Token"))
        }
    }
    @Test fun gatewayNeverForwardsCredentialsThroughARedirect() {
        MockWebServer().use { destination -> MockWebServer().use { source ->
            destination.start(); source.enqueue(MockResponse().setResponseCode(302).setHeader("Location", destination.url("/steal"))); source.start()
            try { BillingGateway(source.url("/").toString(), "aplyna_android_public_test").request("v1/customers/one", JSONObject().put("customerToken", "private_customer_test_token")); fail("Redirect followed") }
            catch (e: AplynaBillingException) { assertEquals("APLYNA_HTTP_302", e.code) }
            assertEquals(0, destination.requestCount)
        } }
    }
    @Test fun failedVerificationKeepsItsHttpCodeAndDoesNotBecomeSuccess() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(503).setBody("{\"error\":\"Acknowledgement needs retry\"}")); server.start()
            try { BillingGateway(server.url("/").toString(), "aplyna_android_public_test").request("v1/customers/one/purchases/google", JSONObject().put("customerToken", "private_customer_test_token"), JSONObject().put("purchaseToken", "test_purchase_token").put("environment", "sandbox")); fail("Verification failure accepted") }
            catch (e: AplynaBillingException) { assertEquals("APLYNA_HTTP_503", e.code); assertEquals("Acknowledgement needs retry", e.message) }
            assertEquals("test_purchase_token", JSONObject(server.takeRequest().body.readUtf8()).getString("purchaseToken"))
        }
    }
    @Test fun insecureGatewaysAndOtherPlatformKeysAreRejected() {
        for ((url, key) in listOf("http://example.com" to "aplyna_android_test", "https://user:pass@example.com" to "aplyna_android_test", "https://example.com?token=bad" to "aplyna_android_test", "https://example.com" to "aplyna_ios_test", "https://example.com" to "aplyna_test_test")) {
            try { BillingGateway(url, key); fail("Invalid gateway scope accepted") } catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun repeatedFailuresCannotStarveRetainedTokensOrRefundHistory() {
        val saved = JSONObject()
        repeat(64) { i -> saved.put("token$i", JSONObject().put("verified", i >= 44).put("recentActive", false)) }
        val attempted = mutableSetOf<String>()
        repeat(4) { turn ->
            val now = 1_000_000L + turn
            val batch = billingReconciliationBatch(saved, emptySet(), emptySet(), now)
            assertTrue(batch.size <= 20)
            // Failed verification persists its attempt without becoming verified.
            batch.forEach { saved.getJSONObject(it).put("lastAttemptAt", now); attempted.add(it) }
        }
        assertEquals(64, attempted.size)
        assertFalse(saved.getJSONObject("token0").getBoolean("verified"))
        val replayed = JSONObject(saved.toString())
        assertFalse(billingReconciliationBatch(replayed, emptySet(), emptySet(), 1_000_004L).any { it.substringAfter("token").toInt() >= 44 })
    }
    @Test fun checkoutGetsImmediateVerificationAheadOfAFullRetryQueue() {
        val saved = JSONObject()
        repeat(64) { i -> saved.put("token$i", JSONObject().put("verified", false)) }
        val batch = billingReconciliationBatch(saved, setOf("token63"), setOf("token63"), 1_000_000)
        assertEquals("token63", batch.first())
        assertEquals(20, batch.size)
    }
}
