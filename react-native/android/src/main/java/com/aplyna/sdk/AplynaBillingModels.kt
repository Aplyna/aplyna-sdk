package com.aplyna.sdk

import org.json.JSONArray
import org.json.JSONObject
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** Stable billing failures shared by the Kotlin, Flutter and React Native APIs. */
class AplynaBillingException(val code: String, message: String, cause: Throwable? = null) : Exception(message, cause)

enum class AplynaBillingEnvironment(val value: String) { SANDBOX("sandbox"), PRODUCTION("production") }

data class AplynaBillingEntitlement(val identifier: String, val active: Boolean, val productId: String, val expiresAt: String?)
data class AplynaBillingSubscription(val provider: String, val productId: String, val originalTransactionId: String, val active: Boolean, val status: String, val expiresAt: String?, val autoRenew: Boolean?, val billingRetry: Boolean?, val gracePeriodExpiresAt: String?)
data class AplynaBillingStoreStatus(val productId: String, val transactionId: String, val state: String, val ownedByCurrentCustomer: Boolean, val willAutoRenew: Boolean?, val billingRetry: Boolean?, val environment: String, val expiresAt: String?, val gracePeriodExpiresAt: String?, val source: String = "server_verified_google") {
    internal fun json() = JSONObject().put("source", source).put("provider", "google").put("productId", productId).put("transactionId", transactionId).put("state", state)
        .put("ownedByCurrentCustomer", ownedByCurrentCustomer).put("willAutoRenew", willAutoRenew ?: JSONObject.NULL).put("billingRetry", billingRetry ?: JSONObject.NULL)
        .put("environment", environment).put("expiresAt", expiresAt ?: JSONObject.NULL).put("gracePeriodExpiresAt", gracePeriodExpiresAt ?: JSONObject.NULL)
}

/** Access comes from the authenticated server response, never the BillingClient callback. */
class AplynaBillingCustomerInfo internal constructor(internal val json: JSONObject) {
    val customerId: String = json.getString("customerId")
    val environment: String = json.getString("environment")
    val checkedAt: String = json.getString("checkedAt")
    val entitlements: List<AplynaBillingEntitlement> = json.getJSONArray("entitlements").objects().map {
        AplynaBillingEntitlement(it.getString("identifier"), it.getBoolean("active"), it.getString("productId"), it.nullableString("expiresAt")).also { e -> e.expiresAt?.let(::billingDateMillis) }
    }
    val subscriptions: List<AplynaBillingSubscription> = json.optJSONArray("subscriptions")?.objects().orEmpty().map {
        AplynaBillingSubscription(it.getString("provider"), it.getString("productId"), it.getString("originalTransactionId"), it.getBoolean("active"), it.getString("status"), it.nullableString("expiresAt"), it.nullableBoolean("autoRenew"), it.nullableBoolean("billingRetry"), it.nullableString("gracePeriodExpiresAt")).also { row -> row.expiresAt?.let(::billingDateMillis); row.gracePeriodExpiresAt?.let(::billingDateMillis) }
    }
    init { billingDateMillis(checkedAt); require(environment in listOf("sandbox", "production")) }
    fun hasAccessTo(identifier: String, nowMillis: Long = System.currentTimeMillis()): Boolean = entitlements.any {
        it.identifier == identifier && it.active && (it.expiresAt == null || nowMillis < billingDateMillis(it.expiresAt))
    }
}

data class AplynaBillingPricingPhase(val price: String, val amountMicros: String, val currency: String, val billingPeriod: String, val billingCycleCount: Int, val recurrenceMode: Int) {
    internal fun json() = JSONObject().put("price", price).put("amountMicros", amountMicros).put("currency", currency).put("billingPeriod", billingPeriod).put("billingCycleCount", billingCycleCount).put("recurrenceMode", recurrenceMode)
}
data class AplynaBillingOffer(val basePlanId: String, val offerId: String?, val offerToken: String, val pricingPhases: List<AplynaBillingPricingPhase>, val tags: List<String>) {
    internal fun json() = JSONObject().put("basePlanId", basePlanId).put("offerId", offerId ?: JSONObject.NULL).put("offerToken", offerToken).put("pricingPhases", JSONArray(pricingPhases.map { it.json() })).put("tags", JSONArray(tags))
}
data class AplynaBillingProduct(val id: String, val name: String, val price: String, val storeProductId: String, val basePlanId: String, val offers: List<AplynaBillingOffer>) {
    internal fun json() = JSONObject().put("id", id).put("name", name).put("price", price).put("subscriptionGroupId", JSONObject.NULL).put("storeProductId", storeProductId).put("basePlanId", basePlanId).put("offers", JSONArray(offers.map { it.json() }))
}

enum class AplynaBillingReplacementMode(val playValue: Int) {
    WITH_TIME_PRORATION(1), CHARGE_PRORATED_PRICE(2), WITHOUT_PRORATION(3), CHARGE_FULL_PRICE(5), DEFERRED(6)
}
data class AplynaBillingPurchaseOptions(val basePlanId: String? = null, val offerToken: String? = null, val replacedProductId: String? = null, val replacementMode: AplynaBillingReplacementMode? = null)

internal data class BillingCatalogProduct(val id: String, val productId: String, val basePlanId: String?) {
    companion object {
        fun parse(id: String): BillingCatalogProduct {
            val parts = id.split(':')
            if (parts.size !in 1..2 || parts.any { !it.matches(Regex("[a-zA-Z0-9_.-]{1,200}")) }) throw AplynaBillingException("APLYNA_BILLING_PRODUCT", "Invalid Google catalog product identifier.")
            return BillingCatalogProduct(id, parts[0], parts.getOrNull(1))
        }
    }
}

internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
internal fun JSONObject.nullableString(key: String): String? = if (!has(key) || isNull(key)) null else getString(key)
internal fun JSONObject.nullableBoolean(key: String): Boolean? = if (!has(key) || isNull(key)) null else getBoolean(key)
internal fun billingReconciliationBatch(tokens: JSONObject, current: Set<String>, required: Set<String>, now: Long): List<String> {
    if (required.size > 20) throw AplynaBillingException("APLYNA_BILLING_LIMIT", "Too many completed purchases in one checkout callback; retained tokens will reconcile on subsequent syncs.")
    val keys = tokens.keys().asSequence().toList().sorted()
    val priority = keys.filter { key -> key in current || tokens.getJSONObject(key).let { !it.optBoolean("verified", false) || it.optBoolean("recentActive", false) } }
        .sortedBy { tokens.getJSONObject(it).optLong("lastAttemptAt", 0) }
    val historical = keys.filter { key -> key !in priority && now - tokens.getJSONObject(key).optLong("lastAttemptAt", 0) >= 300_000 }
        .sortedBy { tokens.getJSONObject(it).optLong("lastAttemptAt", 0) }
    val priorityBudget = if (historical.isEmpty()) 20 else maxOf(required.size, 15)
    val first = (required + priority).take(priorityBudget)
    return first + historical.take(20 - first.size)
}
internal fun billingDateMillis(value: String): Long {
    val pattern = when {
        value.matches(Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z")) -> "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        value.matches(Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z")) -> "yyyy-MM-dd'T'HH:mm:ss'Z'"
        else -> throw AplynaBillingException("APLYNA_BILLING_RESPONSE", "Invalid verified billing date.")
    }
    val position = ParsePosition(0)
    val parsed = SimpleDateFormat(pattern, Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC"); isLenient = false }.parse(value, position)
    if (parsed == null || position.index != value.length) throw AplynaBillingException("APLYNA_BILLING_RESPONSE", "Invalid verified billing date.")
    return parsed.time
}
