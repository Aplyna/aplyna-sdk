package com.aplyna.sdk

import android.app.Activity
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * JSON bridge for the Flutter and React Native `Purchases` APIs. Shapes follow the
 * RevenueCat hybrid SDKs so Dart and TypeScript models keep the same fields.
 */
class PurchasesBridge(private val context: Context) {
    suspend fun invoke(method: String, argumentsJSON: String, activity: Activity? = null): String {
        if (argumentsJSON.toByteArray(Charsets.UTF_8).size > 262144) throw PurchasesException(PurchasesError(PurchasesErrorCode.PurchaseInvalidError, "Arguments exceed 256 KB."))
        val args = JSONObject(argumentsJSON)
        if (method == "purchases.configure") {
            val key = args.nullableString("apiKey")?.takeIf { it.startsWith("aplyna_android_") }
                ?: throw PurchasesException(PurchasesError(PurchasesErrorCode.InvalidCredentialsError, "Configure Purchases with this app's Aplyna Android SDK key."))
            val builder = PurchasesConfiguration.Builder(context, key).appUserID(args.nullableString("appUserID")).projectId(args.nullableString("projectId"))
            args.nullableString("gatewayUrl")?.let(builder::gatewayUrl)
            args.nullableBoolean("sandbox")?.let(builder::sandbox)
            Purchases.configure(builder.build())
            return "null"
        }
        if (method == "purchases.isConfigured") return Purchases.isConfigured.toString()
        if (!Purchases.isConfigured) throw PurchasesException(PurchasesError(PurchasesErrorCode.ConfigurationError, "Purchases has not been configured. Call Purchases.configure first."))
        val purchases = Purchases.sharedInstance
        return when (method) {
            "purchases.getOfferings" -> json(purchases.awaitOfferings()).toString()
            "purchases.getCustomerInfo" -> json(purchases.awaitCustomerInfo()).toString()
            "purchases.restorePurchases" -> json(purchases.awaitRestore()).toString()
            "purchases.syncPurchases" -> json(purchases.awaitSyncPurchases()).toString()
            "purchases.getAppUserID" -> JSONObject().put("appUserID", purchases.appUserID).put("isAnonymous", purchases.isAnonymous).toString()
            "purchases.canMakePayments" -> "true"
            "purchases.invalidateCustomerInfoCache" -> { purchases.invalidateCustomerInfoCache(); "null" }
            "purchases.logIn" -> purchases.awaitLogIn(args.nullableString("appUserID") ?: throw PurchasesException(PurchasesError(PurchasesErrorCode.InvalidAppUserIdError)))
                .let { JSONObject().put("customerInfo", json(it.customerInfo)).put("created", it.created).toString() }
            "purchases.logOut" -> json(purchases.awaitLogOut()).toString()
            "purchases.setAttributes" -> {
                val raw = args.optJSONObject("attributes") ?: throw PurchasesException(PurchasesError(PurchasesErrorCode.InvalidSubscriberAttributesError))
                purchases.setAttributes(raw.keys().asSequence().associateWith { raw.nullableString(it) }); "null"
            }
            "purchases.purchaseProduct" -> {
                val identifier = args.nullableString("productIdentifier")
                val product = purchases.awaitOfferings().all.values.flatMap { it.availablePackages }.map { it.product }.firstOrNull { it.id == identifier }
                    ?: throw PurchasesException(PurchasesError(PurchasesErrorCode.ProductNotAvailableForPurchaseError))
                val builder = PurchaseParams.Builder(activity ?: throw PurchasesException(PurchasesError(PurchasesErrorCode.PurchaseInvalidError, "Purchases need the attached foreground Activity.")), product)
                args.nullableString("oldProductIdentifier")?.let(builder::oldProductId)
                args.nullableString("googleReplacementMode")?.let { value -> GoogleReplacementMode.values().firstOrNull { it.name == value }?.let(builder::googleReplacementMode) }
                val result = purchases.awaitPurchase(builder.build())
                JSONObject().put("customerInfo", json(result.customerInfo)).put("productIdentifier", product.id)
                    .put("transaction", JSONObject().put("productIdentifier", product.id).put("purchaseDate", iso(Date(result.storeTransaction.purchaseTime)))).toString()
            }
            else -> throw PurchasesException(PurchasesError(PurchasesErrorCode.UnsupportedError, "Unsupported Purchases method."))
        }
    }

    companion object {
        /** Error fields for the hybrid layers: numeric code as text, message, readable code, userCancelled. */
        fun errorPayload(error: Throwable): Triple<String, String, JSONObject> {
            val mapped = PurchasesError.from(error)
            val message = mapped.underlyingErrorMessage ?: mapped.message
            return Triple(mapped.code.code.toString(), message, JSONObject().put("code", mapped.code.code).put("readableErrorCode", mapped.code.readableCode)
                .put("readable_error_code", mapped.code.readableCode).put("userCancelled", mapped.code == PurchasesErrorCode.PurchaseCancelledError)
                .put("message", message).put("underlyingErrorMessage", mapped.underlyingErrorMessage ?: JSONObject.NULL))
        }

        internal fun iso(date: Date): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(date)
        private fun optional(date: Date?): Any = date?.let(::iso) ?: JSONObject.NULL

        internal fun json(entitlement: EntitlementInfo): JSONObject = JSONObject()
            .put("identifier", entitlement.identifier).put("isActive", entitlement.isActive).put("willRenew", entitlement.willRenew).put("periodType", entitlement.periodType.name)
            .put("latestPurchaseDate", optional(entitlement.latestPurchaseDate)).put("originalPurchaseDate", optional(entitlement.originalPurchaseDate))
            .put("expirationDate", optional(entitlement.expirationDate)).put("store", entitlement.store.name).put("productIdentifier", entitlement.productIdentifier)
            .put("productPlanIdentifier", entitlement.productPlanIdentifier ?: JSONObject.NULL).put("isSandbox", entitlement.isSandbox)
            .put("unsubscribeDetectedAt", optional(entitlement.unsubscribeDetectedAt)).put("billingIssueDetectedAt", optional(entitlement.billingIssueDetectedAt))
            .put("ownershipType", entitlement.ownershipType.name)

        internal fun json(info: CustomerInfo): JSONObject {
            fun map(values: Map<String, EntitlementInfo>) = JSONObject().apply { values.forEach { (key, value) -> put(key, json(value)) } }
            return JSONObject().put("entitlements", JSONObject().put("all", map(info.entitlements.all)).put("active", map(info.entitlements.active)))
                .put("activeSubscriptions", JSONArray(info.activeSubscriptions.sorted())).put("allPurchasedProductIdentifiers", JSONArray(info.allPurchasedProductIds.sorted()))
                .put("latestExpirationDate", optional(info.latestExpirationDate)).put("originalAppUserId", info.originalAppUserId).put("requestDate", iso(info.requestDate))
                .put("managementURL", info.managementUrlString ?: JSONObject.NULL)
                .put("allExpirationDates", JSONObject().apply { info.allExpirationDatesByProduct.forEach { (key, value) -> put(key, optional(value)) } })
        }

        internal fun json(product: StoreProduct): JSONObject {
            val intro: Any = product.freeTrialPeriod?.let {
                JSONObject().put("price", 0).put("priceString", "Free").put("period", it.iso8601).put("cycles", 1).put("periodUnit", it.unit.name).put("periodNumberOfUnits", it.value)
            } ?: JSONObject.NULL
            return JSONObject().put("identifier", product.id).put("title", product.title).put("description", product.description)
                .put("price", product.price.amountMicros / 1_000_000.0).put("priceString", product.price.formatted).put("currencyCode", product.price.currencyCode)
                .put("productCategory", "SUBSCRIPTION").put("subscriptionPeriod", product.period?.iso8601 ?: JSONObject.NULL).put("introPrice", intro)
                .put("subscriptionGroupIdentifier", JSONObject.NULL).put("productId", product.productId).put("basePlanId", product.basePlanId ?: JSONObject.NULL)
        }

        internal fun json(pack: Package): JSONObject = JSONObject().put("identifier", pack.identifier).put("packageType", pack.packageType.name).put("product", json(pack.product))
            .put("offeringIdentifier", pack.offering).put("presentedOfferingContext", JSONObject().put("offeringIdentifier", pack.offering))

        internal fun json(offering: Offering): JSONObject {
            val value = JSONObject().put("identifier", offering.identifier).put("serverDescription", offering.serverDescription).put("metadata", JSONObject())
                .put("availablePackages", JSONArray(offering.availablePackages.map { json(it) }))
            mapOf("lifetime" to offering.lifetime, "annual" to offering.annual, "sixMonth" to offering.sixMonth, "threeMonth" to offering.threeMonth,
                "twoMonth" to offering.twoMonth, "monthly" to offering.monthly, "weekly" to offering.weekly).forEach { (key, pack) -> if (pack != null) value.put(key, json(pack)) }
            return value
        }

        internal fun json(offerings: Offerings): JSONObject = JSONObject()
            .put("all", JSONObject().apply { offerings.all.forEach { (key, value) -> put(key, json(value)) } })
            .put("current", offerings.current?.let { json(it) } ?: JSONObject.NULL)
    }
}
