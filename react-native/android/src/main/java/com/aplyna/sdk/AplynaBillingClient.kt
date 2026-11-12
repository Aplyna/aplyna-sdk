package com.aplyna.sdk

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.android.billingclient.api.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Google Play subscription billing, independent of telemetry configuration and consent. */
class AplynaBillingClient(
    context: Context,
    sdkKey: String,
    val environment: AplynaBillingEnvironment,
    private val sandboxOnly: Boolean = true,
    private val googlePlayLicenseTester: Boolean = false,
    gatewayUrl: String = "https://aplyna.com/api/billing"
) : AutoCloseable {
    private val app = context.applicationContext
    private val gateway = BillingGateway(gatewayUrl, sdkKey)
    private val storage: BillingStorage = AndroidBillingStorage(app, "$gatewayUrl|${app.packageName}|${environment.value}")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val closed = AtomicBoolean(false)
    private val operations = Mutex()
    private val connection = Mutex()
    private val identities = Mutex()
    private val purchases = Mutex()
    private var state: JSONObject? = null
    private data class Pending(val product: String, val previousTokens: Set<String>, val result: CompletableDeferred<AplynaBillingCustomerInfo>)
    private val pending = AtomicReference<Pending?>(null)
    @Volatile private var lastUpdateError: String? = null
    private val play = BillingClient.newBuilder(app)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().enablePrepaidPlans().build())
        .enableAutoServiceReconnection()
        .setListener { result, values -> onPurchasesUpdated(result, values ?: emptyList()) }
        .build()

    init { require(!sandboxOnly || environment == AplynaBillingEnvironment.SANDBOX) { "sandboxOnly requires the sandbox environment." } }
    private fun ensureOpen() { if (closed.get()) throw AplynaBillingException("APLYNA_BILLING_CLOSED", "The billing client is closed.") }
    private fun failure(result: BillingResult): AplynaBillingException = AplynaBillingException(
        when (result.responseCode) {
            BillingClient.BillingResponseCode.USER_CANCELED -> "APLYNA_BILLING_CANCELLED"
            BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> "APLYNA_BILLING_ALREADY_OWNED"
            BillingClient.BillingResponseCode.SERVICE_DISCONNECTED, BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE, BillingClient.BillingResponseCode.NETWORK_ERROR -> "APLYNA_BILLING_UNAVAILABLE"
            BillingClient.BillingResponseCode.BILLING_UNAVAILABLE, BillingClient.BillingResponseCode.FEATURE_NOT_SUPPORTED -> "APLYNA_BILLING_UNSUPPORTED"
            else -> "APLYNA_BILLING_STORE_${result.responseCode}"
        }, result.debugMessage.ifBlank { "Google Play billing did not complete." })

    private suspend fun ready() = connection.withLock {
        ensureOpen()
        if (!play.isReady) withContext(Dispatchers.Main.immediate) {
            withTimeout(60_000) { suspendCancellableCoroutine<Unit> { continuation ->
                play.startConnection(object : BillingClientStateListener {
                    override fun onBillingSetupFinished(result: BillingResult) {
                        if (continuation.isActive) {
                            if (result.responseCode == BillingClient.BillingResponseCode.OK) continuation.resume(Unit)
                            else continuation.resumeWithException(failure(result))
                        }
                    }
                    override fun onBillingServiceDisconnected() {
                        if (continuation.isActive) continuation.resumeWithException(AplynaBillingException("APLYNA_BILLING_UNAVAILABLE", "Google Play disconnected; retry on the next foreground sync."))
                    }
                })
            } }
        }
    }

    private suspend fun identity(): JSONObject = identities.withLock {
        ensureOpen()
        if (state == null) state = withContext(Dispatchers.IO) { storage.read() }
        state?.let { saved ->
            val value = saved.getJSONObject("identity")
            validateIdentity(value)
            return@withLock value
        }
        val created = withContext(Dispatchers.IO) { gateway.request("v1/customers", body = JSONObject().put("environment", environment.value)) }
        validateIdentity(created)
        ensureOpen()
        val saved = JSONObject().put("identity", created).put("tokens", JSONObject())
        withContext(Dispatchers.IO) { ensureOpen(); storage.write(saved) }
        state = saved
        created
    }
    private fun validateIdentity(value: JSONObject) {
        val id = value.getString("id")
        if (UUID.fromString(id).toString() != id || value.getString("environment") != environment.value ||
            value.getString("customerToken").length !in 32..500 || value.getString("googleObfuscatedAccountId") != billingHash(id))
            throw AplynaBillingException("APLYNA_BILLING_IDENTITY", "The billing identity does not match its verified scope.")
    }
    private suspend fun request(path: String = "", body: JSONObject? = null): JSONObject {
        val customer = identity()
        return withContext(Dispatchers.IO) { ensureOpen(); gateway.request("v1/customers/${customer.getString("id")}$path", customer, body) }
    }
    private suspend fun info(): AplynaBillingCustomerInfo {
        val value = AplynaBillingCustomerInfo(request())
        if (value.customerId != identity().getString("id") || value.environment != environment.value)
            throw AplynaBillingException("APLYNA_BILLING_RESPONSE", "The billing response belongs to another customer or environment.")
        return value
    }
    suspend fun customerInfo(): AplynaBillingCustomerInfo = operations.withLock { info() }
    /** Stable billing customer for this install. */
    suspend fun customerId(): String = identity().getString("id")
    /** Offerings and packages from the product catalog. projectId is only needed for legacy app-wide keys. */
    suspend fun offeringsCatalog(projectId: String? = null): JSONObject = withContext(Dispatchers.IO) { ensureOpen(); gateway.offerings(projectId) }
    /** Sends customer attributes as {key: {value, updatedAtMs}}; a null value deletes the attribute. */
    suspend fun sendAttributes(attributes: JSONObject): JSONObject = request("/attributes", JSONObject().put("attributes", attributes))

    private suspend fun catalog(): List<BillingCatalogProduct> {
        val catalog = request("/products")
        if (catalog.nullableString("googlePackageName") != app.packageName || catalog.nullableString("environment") != environment.value)
            throw AplynaBillingException("APLYNA_BILLING_SCOPE", "The billing gateway must verify this Google Play package and environment before store UI opens.")
        if (!catalog.optBoolean("googleBillingReady", false)) throw AplynaBillingException("APLYNA_BILLING_NOT_READY", "Configure Google Play server verification before opening checkout.")
        val values = catalog.getJSONArray("products").objects().filter {
            it.getString("provider") == "google" && it.getString("type") == "subscription" && it.getJSONArray("entitlements").length() > 0
        }
        if (values.size > 100) throw AplynaBillingException("APLYNA_BILLING_LIMIT", "The mapped subscription catalog exceeds 100 entries.")
        return values.map { BillingCatalogProduct.parse(it.getString("identifier")) }
    }
    private suspend fun details(ids: List<String>): List<ProductDetails> {
        ready()
        val result = mutableListOf<ProductDetails>()
        for (batch in ids.distinct().chunked(20)) result += withContext(Dispatchers.Main.immediate) {
            withTimeout(60_000) { suspendCancellableCoroutine<List<ProductDetails>> { continuation ->
                val params = QueryProductDetailsParams.newBuilder().setProductList(batch.map {
                    QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(BillingClient.ProductType.SUBS).build()
                }).build()
                play.queryProductDetailsAsync(params) { response, products ->
                    if (continuation.isActive) {
                        if (response.responseCode == BillingClient.BillingResponseCode.OK) continuation.resume(products.productDetailsList)
                        else continuation.resumeWithException(failure(response))
                    }
                }
            } }
        }
        return result
    }
    private fun offer(value: ProductDetails.SubscriptionOfferDetails) = AplynaBillingOffer(value.basePlanId, value.offerId, value.offerToken,
        value.pricingPhases.pricingPhaseList.map { AplynaBillingPricingPhase(it.formattedPrice, it.priceAmountMicros.toString(), it.priceCurrencyCode, it.billingPeriod, it.billingCycleCount, it.recurrenceMode) }, value.offerTags.toList())
    private suspend fun mapped(): Pair<List<AplynaBillingProduct>, Map<String, ProductDetails>> {
        val catalog = catalog()
        val details = details(catalog.map { it.productId }).associateBy { it.productId }
        val rows = catalog.flatMap { item ->
            val detail = details[item.productId] ?: return@flatMap emptyList()
            (detail.subscriptionOfferDetails ?: emptyList()).filter { item.basePlanId == null || it.basePlanId == item.basePlanId }.groupBy { it.basePlanId }.map { (basePlan, values) ->
                val offers = values.map(::offer)
                val regular = offers.firstOrNull { it.offerId == null }
                val price = regular?.pricingPhases?.lastOrNull()?.price ?: offers.first().pricingPhases.lastOrNull()?.price.orEmpty()
                AplynaBillingProduct(item.id, detail.name, price, item.productId, basePlan, offers)
            }
        }
        return rows.sortedWith(compareBy({ it.id }, { it.basePlanId })) to details
    }
    suspend fun products(): List<AplynaBillingProduct> = operations.withLock { mapped().first }

    private suspend fun queryPurchases(): List<Purchase> {
        ready()
        return withContext(Dispatchers.Main.immediate) { withTimeout(60_000) { suspendCancellableCoroutine { continuation ->
            play.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).includeSuspendedSubscriptions(true).build()) { result, values ->
                if (continuation.isActive) {
                    if (result.responseCode == BillingClient.BillingResponseCode.OK) continuation.resume(values.toList())
                    else continuation.resumeWithException(failure(result))
                }
            }
        } } }
    }
    private fun tokens(): JSONObject = checkNotNull(state).getJSONObject("tokens")
    private suspend fun save() = withContext(Dispatchers.IO) { ensureOpen(); storage.write(checkNotNull(state)) }
    private fun owns(value: Purchase, customer: JSONObject): Boolean = value.packageName == app.packageName &&
        (value.accountIdentifiers?.obfuscatedAccountId == customer.getString("googleObfuscatedAccountId") ||
            value.accountIdentifiers?.obfuscatedAccountId.isNullOrEmpty() && tokens().has(billingHash(value.purchaseToken)))
    private suspend fun remember(value: Purchase) {
        val values = tokens(); val key = billingHash(value.purchaseToken)
        if (values.has(key)) return
        // Only verified, long-expired records may leave the bounded native history.
        val removable = values.keys().asSequence().filter { k ->
            val row = values.getJSONObject(k)
            row.optBoolean("verified", false) && row.has("expiresAt") && !row.isNull("expiresAt") &&
                billingDateMillis(row.getString("expiresAt")) < System.currentTimeMillis() - 60L * 24 * 60 * 60 * 1000
        }.toList()
        if (values.length() >= 64) removable.forEach(values::remove)
        if (values.length() >= 64) throw AplynaBillingException("APLYNA_BILLING_LIMIT", "Billing reconciliation has reached its retained purchase limit; no pending token was discarded.")
        values.put(key, JSONObject().put("token", value.purchaseToken).put("verified", false))
        save() // Persist before verification/acknowledgement, so network failure is retryable.
    }
    private suspend fun refreshToken(key: String): AplynaBillingCustomerInfo {
        val saved = tokens().getJSONObject(key)
        saved.put("lastAttemptAt", System.currentTimeMillis())
        save() // Failed reads also advance the bounded queue across relaunches.
        val response = request("/purchases/google", JSONObject().put("environment", environment.value).put("purchaseToken", saved.getString("token")))
        val result = AplynaBillingCustomerInfo(response)
        if (result.customerId != identity().getString("id") || result.environment != environment.value)
            throw AplynaBillingException("APLYNA_BILLING_RESPONSE", "The verified purchase response has the wrong scope.")
        val row = response.optJSONArray("subscriptions")?.objects()?.firstOrNull { it.getString("provider") == "google" && it.getString("originalTransactionId") == key }
        saved.put("verified", true).put("expiresAt", row?.nullableString("expiresAt") ?: JSONObject.NULL)
            .put("recentActive", row?.optBoolean("active", false) ?: false).put("lastVerifiedAt", System.currentTimeMillis())
        save()
        return result
    }
    private suspend fun reconcile(current: List<Purchase>, strictProduct: String? = null): AplynaBillingCustomerInfo {
        val customer = identity()
        val mapped = catalog().map { it.productId }.toSet()
        val completed = current.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED && it.products.any(mapped::contains) }
        if (strictProduct != null && completed.any { strictProduct in it.products && !owns(it, customer) })
            throw AplynaBillingException("APLYNA_BILLING_CUSTOMER_CONFLICT", "The Google purchase belongs to a different billing customer.")
        val owned = completed.filter { owns(it, customer) }
        owned.forEach { remember(it) }
        val currentKeys = owned.map { billingHash(it.purchaseToken) }.toSet()
        val now = System.currentTimeMillis()
        val expired = tokens().keys().asSequence().filter { key ->
            val row = tokens().getJSONObject(key)
            key !in currentKeys && row.optBoolean("verified", false) && !row.optBoolean("recentActive", false) &&
                row.nullableString("expiresAt")?.let { billingDateMillis(it) < now - 60L * 24 * 60 * 60 * 1000 } == true
        }.toList()
        expired.forEach { tokens().remove(it) }
        if (expired.isNotEmpty()) save()
        // A checkout callback is verified first. The remaining queue uses its
        // persisted attempt time so repeated failures cannot starve later tokens.
        val required = if (strictProduct == null) emptySet() else owned.filter { strictProduct in it.products }.map { billingHash(it.purchaseToken) }.toSet()
        val work = billingReconciliationBatch(tokens(), currentKeys, required, now)
        var failure: Exception? = null
        for (key in work) try { refreshToken(key) } catch (e: CancellationException) { throw e } catch (e: Exception) { if (failure == null) failure = e }
        if (failure != null) throw failure
        return info()
    }

    /** Refreshes active and retained tokens, including subscriptions no longer returned by Play. */
    suspend fun sync(): AplynaBillingCustomerInfo = operations.withLock { reconcile(queryPurchases()) }
    /** Google restores its current account's purchases without granting another customer's token. */
    suspend fun restore(): AplynaBillingCustomerInfo = sync()

    suspend fun purchase(activity: Activity, productId: String, options: AplynaBillingPurchaseOptions = AplynaBillingPurchaseOptions()): AplynaBillingCustomerInfo {
        ensureOpen()
        if (sandboxOnly && !googlePlayLicenseTester) throw AplynaBillingException("APLYNA_BILLING_SANDBOX_SETUP", "Google does not expose test-account status before checkout. Configure an actual Google Play license tester and explicitly set googlePlayLicenseTester before Sandbox checkout.")
        if (!purchases.tryLock()) throw AplynaBillingException("APLYNA_BILLING_IN_PROGRESS", "Another Google purchase is already in progress.")
        var awaiting: Pending? = null
        try {
            val prepared = operations.withLock {
                val customer = identity()
                val (rows, details) = mapped()
                val matching = rows.filter { it.id == productId && (options.basePlanId == null || it.basePlanId == options.basePlanId) }
                if (matching.size != 1) throw AplynaBillingException("APLYNA_BILLING_PRODUCT", "Choose one mapped product and base plan returned by products().")
                val row = matching.single()
                val chosen = if (options.offerToken != null) row.offers.singleOrNull { it.offerToken == options.offerToken }
                    else row.offers.singleOrNull { it.offerId == null }
                if (chosen == null) throw AplynaBillingException("APLYNA_BILLING_OFFER", "Choose an eligible offer returned by products(); no introductory offer is selected automatically.")
                if ((options.replacedProductId == null) != (options.replacementMode == null)) throw AplynaBillingException("APLYNA_ARGUMENTS", "A plan replacement requires both replacedProductId and replacementMode.")
                val product = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(checkNotNull(details[row.storeProductId])).setOfferToken(chosen.offerToken)
                val flow = BillingFlowParams.newBuilder().setObfuscatedAccountId(customer.getString("googleObfuscatedAccountId"))
                if (options.replacedProductId != null) {
                    val previous = BillingCatalogProduct.parse(options.replacedProductId)
                    val current = queryPurchases().filter { it.purchaseState == Purchase.PurchaseState.PURCHASED && previous.productId in it.products && owns(it, customer) }
                    if (current.size != 1) throw AplynaBillingException("APLYNA_BILLING_CUSTOMER_CONFLICT", "Choose an owned current subscription for replacement.")
                    // The replacement mode belongs on SubscriptionUpdateParams, whose constants AplynaBillingReplacementMode uses
                    // (CHARGE_FULL_PRICE 5, DEFERRED 6). The per-product replacement params number them differently (4, 5) and
                    // Google Play rejected a base-plan change inside one subscription when they were used.
                    flow.setSubscriptionUpdateParams(BillingFlowParams.SubscriptionUpdateParams.newBuilder().setOldPurchaseToken(current.single().purchaseToken)
                        .setSubscriptionReplacementMode(checkNotNull(options.replacementMode).playValue).build())
                }
                flow.setProductDetailsParamsList(listOf(product.build()))
                Triple(row.storeProductId, flow.build(), tokens().keys().asSequence().toSet())
            }
            awaiting = Pending(prepared.first, prepared.third, CompletableDeferred())
            withContext(Dispatchers.Main.immediate) {
                ensureOpen()
                if (activity.isFinishing || activity.isDestroyed) throw AplynaBillingException("APLYNA_BILLING_ACTIVITY", "Purchase requires the foreground Activity.")
                pending.set(awaiting)
                val result = play.launchBillingFlow(activity, prepared.second)
                if (result.responseCode != BillingClient.BillingResponseCode.OK) throw failure(result)
            }
            return withTimeout(300_000) { awaiting.result.await() }
        } finally { awaiting?.let { pending.compareAndSet(it, null) }; purchases.unlock() }
    }
    private fun onPurchasesUpdated(result: BillingResult, values: List<Purchase>) {
        if (closed.get()) return
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            pending.getAndSet(null)?.result?.completeExceptionally(failure(result)); return
        }
        val waiting = pending.get()
        if (waiting != null && values.any { waiting.product in it.products && it.purchaseState == Purchase.PurchaseState.PENDING }) {
            pending.compareAndSet(waiting, null)
            waiting.result.completeExceptionally(AplynaBillingException("APLYNA_BILLING_PENDING", "Payment is pending; no entitlement or acknowledgement is granted yet."))
        }
        scope.launch {
            try {
                val info = operations.withLock { reconcile(values, waiting?.product) }
                lastUpdateError = null
                if (waiting != null && values.any { waiting.product in it.products && it.purchaseState == Purchase.PurchaseState.PURCHASED && billingHash(it.purchaseToken) !in waiting.previousTokens }) {
                    pending.compareAndSet(waiting, null); waiting.result.complete(info)
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                lastUpdateError = if (e is AplynaBillingException) e.code else "APLYNA_BILLING_UPDATE"
                if (waiting != null) { pending.compareAndSet(waiting, null); waiting.result.completeExceptionally(e) }
            }
        }
    }

    /** Android BillingClient does not expose grace: these are explicitly server-verified states. */
    suspend fun storeStatuses(): List<AplynaBillingStoreStatus> = operations.withLock {
        val info = info()
        info.subscriptions.filter { it.provider == "google" }.map { AplynaBillingStoreStatus(it.productId, "snapshot:${it.originalTransactionId}", it.status, true, it.autoRenew, it.billingRetry, environment.value, it.expiresAt, it.gracePeriodExpiresAt) }
    }
    suspend fun manageSubscriptions(activity: Activity, productId: String? = null) {
        val selected = operations.withLock {
            val mapped = catalog()
            if (productId != null) mapped.singleOrNull { it.id == productId }?.productId ?: throw AplynaBillingException("APLYNA_BILLING_PRODUCT", "Choose a mapped product for management.")
            else mapped.map { it.productId }.distinct().singleOrNull()
        }
        val url = Uri.parse("https://play.google.com/store/account/subscriptions").buildUpon().apply { if (selected != null) { appendQueryParameter("sku", selected); appendQueryParameter("package", app.packageName) } }.build()
        withContext(Dispatchers.Main.immediate) {
            ensureOpen()
            if (activity.isFinishing || activity.isDestroyed) throw AplynaBillingException("APLYNA_BILLING_ACTIVITY", "Management requires the foreground Activity.")
            val intent = Intent(Intent.ACTION_VIEW, url).setPackage("com.android.vending")
            try { activity.startActivity(intent) } catch (_: android.content.ActivityNotFoundException) { activity.startActivity(Intent(Intent.ACTION_VIEW, url)) }
        }
    }
    fun diagnostics(): JSONObject = JSONObject().put("updateError", lastUpdateError ?: JSONObject.NULL)
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        pending.getAndSet(null)?.result?.completeExceptionally(AplynaBillingException("APLYNA_BILLING_CLOSED", "The billing client closed before checkout completed."))
        scope.cancel()
        storage.close()
        android.os.Handler(android.os.Looper.getMainLooper()).post { play.endConnection() }
    }
}
