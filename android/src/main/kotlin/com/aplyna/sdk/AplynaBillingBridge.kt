package com.aplyna.sdk

import android.app.Activity
import android.content.Context
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject

/** One asynchronous billing boundary for the Flutter and React Native adapters. */
class AplynaBillingBridge(private val context: Context) : AutoCloseable {
    @Volatile private var client: AplynaBillingClient? = null
    private val configuration = Mutex()
    suspend fun invoke(method: String, argumentsJSON: String, activity: Activity? = null): String {
        if (argumentsJSON.toByteArray(Charsets.UTF_8).size > 262144) throw AplynaBillingException("APLYNA_ARGUMENTS", "Billing arguments exceed 256 KB.")
        val args = JSONObject(argumentsJSON)
        if (method == "billing.configure") return configuration.withLock {
            val environment = AplynaBillingEnvironment.values().singleOrNull { it.value == args.getString("environment") }
                ?: throw AplynaBillingException("APLYNA_ARGUMENTS", "Use sandbox or production billing.")
            val sandboxOnly = args.opt("sandboxOnly") as? Boolean ?: throw AplynaBillingException("APLYNA_ARGUMENTS", "sandboxOnly must be a boolean.")
            if (args.has("googlePlayLicenseTester") && args.opt("googlePlayLicenseTester") !is Boolean) throw AplynaBillingException("APLYNA_ARGUMENTS", "googlePlayLicenseTester must be a boolean.")
            client?.close(); client = null
            client = AplynaBillingClient(context, args.getString("apiKey"), environment, sandboxOnly, args.optBoolean("googlePlayLicenseTester", false), args.getString("gatewayUrl"))
            JSONObject().put("environment", environment.value).put("provider", "google").toString()
        }
        val configured = client ?: throw AplynaBillingException("APLYNA_BILLING_NOT_CONFIGURED", "Configure Aplyna billing before calling billing methods.")
        return when (method) {
            "billing.products" -> JSONArray(configured.products().map { it.json() }).toString()
            "billing.customerInfo" -> configured.customerInfo().json.toString()
            "billing.sync" -> configured.sync().json.toString()
            "billing.restore" -> configured.restore().json.toString()
            "billing.purchase" -> {
                val mode = args.nullableString("replacementMode")?.let { value -> AplynaBillingReplacementMode.values().singleOrNull { it.name.lowercase() == value }
                    ?: throw AplynaBillingException("APLYNA_ARGUMENTS", "Use a supported subscription replacement mode.") }
                configured.purchase(requireActivity(activity), args.getString("productId"), AplynaBillingPurchaseOptions(args.nullableString("basePlanId"), args.nullableString("offerToken"), args.nullableString("replacedProductId"), mode)).json.toString()
            }
            "billing.manageSubscriptions" -> { configured.manageSubscriptions(requireActivity(activity), args.nullableString("productId")); "null" }
            "billing.storeStatuses" -> JSONArray(configured.storeStatuses().map { it.json() }).toString()
            "billing.diagnostics" -> configured.diagnostics().toString()
            "billing.requestRefund" -> throw AplynaBillingException("APLYNA_BILLING_UNSUPPORTED", "Google Play manages refund requests outside BillingClient. Verified refunds are reconciled by sync(); requesting a refund is not a confirmed revocation.")
            else -> throw AplynaBillingException("APLYNA_ARGUMENTS", "Unsupported billing method.")
        }
    }
    private fun requireActivity(value: Activity?): Activity = value ?: throw AplynaBillingException("APLYNA_BILLING_ACTIVITY", "Billing UI requires the attached foreground Activity.")
    override fun close() { client?.close(); client = null }
}
