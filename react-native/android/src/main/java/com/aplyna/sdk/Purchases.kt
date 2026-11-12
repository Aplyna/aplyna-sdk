package com.aplyna.sdk

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

/** Configuration with the same builder as RevenueCat's. */
class PurchasesConfiguration private constructor(
    val context: Context, val apiKey: String, val appUserID: String?, val gatewayUrl: String, val projectId: String?, val sandbox: Boolean
) {
    class Builder(private val context: Context, private val apiKey: String) {
        private var appUserID: String? = null
        private var gatewayUrl = "https://aplyna.com/api/billing"
        private var projectId: String? = null
        private var sandbox: Boolean? = null
        fun appUserID(appUserID: String?) = apply { this.appUserID = appUserID }
        /** Aplyna only: another billing gateway, for self-hosted or test environments. */
        fun gatewayUrl(url: String) = apply { gatewayUrl = url }
        /** Aplyna only: catalog project for legacy app-wide keys. Store-bound keys do not need it. */
        fun projectId(id: String?) = apply { projectId = id }
        /**
         * Aplyna only: Google does not tell an app whether its account is a license tester.
         * Debuggable builds default to sandbox and release builds to production; set it explicitly otherwise.
         */
        fun sandbox(enabled: Boolean) = apply { sandbox = enabled }
        fun build(): PurchasesConfiguration {
            val debuggable = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
            return PurchasesConfiguration(context.applicationContext, apiKey, appUserID, gatewayUrl, projectId, sandbox ?: debuggable)
        }
    }
}

fun interface UpdatedCustomerInfoListener { fun onReceived(customerInfo: CustomerInfo) }
interface ReceiveOfferingsCallback { fun onReceived(offerings: Offerings); fun onError(error: PurchasesError) }
interface ReceiveCustomerInfoCallback { fun onReceived(customerInfo: CustomerInfo); fun onError(error: PurchasesError) }
interface PurchaseCallback { fun onCompleted(storeTransaction: StoreTransaction, customerInfo: CustomerInfo); fun onError(error: PurchasesError, userCancelled: Boolean) }
interface LogInCallback { fun onReceived(customerInfo: CustomerInfo, created: Boolean); fun onError(error: PurchasesError) }

/** Purchase request with the same builder as RevenueCat's. */
class PurchaseParams private constructor(val activity: Activity, val product: StoreProduct, val oldProductId: String?, val googleReplacementMode: GoogleReplacementMode?) {
    class Builder(private val activity: Activity, private val product: StoreProduct) {
        constructor(activity: Activity, packageToPurchase: Package) : this(activity, packageToPurchase.product)
        private var oldProductId: String? = null
        private var mode: GoogleReplacementMode? = null
        /** The subscription being replaced, for upgrades and downgrades. */
        fun oldProductId(id: String) = apply { oldProductId = id }
        fun googleReplacementMode(mode: GoogleReplacementMode) = apply { this.mode = mode }
        fun build() = PurchaseParams(activity, product, oldProductId, mode)
    }
}

enum class GoogleReplacementMode(internal val aplyna: AplynaBillingReplacementMode) {
    WITHOUT_PRORATION(AplynaBillingReplacementMode.WITHOUT_PRORATION), WITH_TIME_PRORATION(AplynaBillingReplacementMode.WITH_TIME_PRORATION),
    CHARGE_FULL_PRICE(AplynaBillingReplacementMode.CHARGE_FULL_PRICE), CHARGE_PRORATED_PRICE(AplynaBillingReplacementMode.CHARGE_PRORATED_PRICE),
    DEFERRED(AplynaBillingReplacementMode.DEFERRED)
}

/** Entry point with the same names as RevenueCat's `Purchases`. */
class Purchases private constructor(private val configuration: PurchasesConfiguration) : Application.ActivityLifecycleCallbacks {
    companion object {
        private const val STALE_MILLIS = 5 * 60 * 1000L
        @Volatile private var instance: Purchases? = null
        @JvmStatic var logLevel: LogLevel = LogLevel.INFO
        @JvmStatic val isConfigured: Boolean get() = instance != null
        @JvmStatic val sharedInstance: Purchases
            get() = instance ?: throw UninitializedPropertyAccessException("There is no singleton instance. Make sure you configure Purchases before trying to get the default instance.")

        @JvmStatic @Synchronized fun configure(configuration: PurchasesConfiguration): Purchases {
            instance?.close()
            return Purchases(configuration).also { instance = it; it.start() }
        }
    }

    private val prefs = configuration.context.getSharedPreferences("com.aplyna.purchases", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val client = AplynaBillingClient(
        configuration.context, configuration.apiKey,
        if (configuration.sandbox) AplynaBillingEnvironment.SANDBOX else AplynaBillingEnvironment.PRODUCTION,
        sandboxOnly = configuration.sandbox, googlePlayLicenseTester = configuration.sandbox, gatewayUrl = configuration.gatewayUrl)
    private val attributes = Mutex()
    @Volatile private var user: String = configuration.appUserID?.takeIf(AppUserIDs::isValid) ?: prefs.getString("appUserID", null) ?: AppUserIDs.anonymous()
    @Volatile private var offerings: Offerings? = null
    @Volatile private var offeringsAt = 0L
    @Volatile private var latest: Pair<AplynaBillingCustomerInfo, Long>? = null
    @Volatile private var lastPublished: CustomerInfo? = null

    @Volatile var updatedCustomerInfoListener: UpdatedCustomerInfoListener? = null
    val appUserID: String get() = user
    val isAnonymous: Boolean get() = AppUserIDs.isAnonymous(user)

    private fun start() {
        prefs.edit().putString("appUserID", user).apply()
        (configuration.context as? Application)?.registerActivityLifecycleCallbacks(this)
        scope.launch { runCatching { refresh() }; runCatching { flushAttributes() } }
    }
    fun close() {
        (configuration.context as? Application)?.unregisterActivityLifecycleCallbacks(this)
        scope.cancel(); client.close()
        if (instance === this) instance = null
    }

    // Offerings

    suspend fun awaitOfferings(): Offerings = guarded { loadOfferings(false) }
    private suspend fun loadOfferings(refresh: Boolean): Offerings {
        // Offerings are reused for five minutes, then read again so catalog changes arrive.
        offerings?.takeIf { !refresh && System.currentTimeMillis() - offeringsAt < STALE_MILLIS }?.let { return it }
        try {
            val catalog = client.offeringsCatalog(configuration.projectId)
            val products = client.products()
            val wanted = catalog.optJSONArray("offerings")?.objects().orEmpty().flatMap { it.optJSONArray("packages")?.objects().orEmpty() }
                .flatMap { it.optJSONArray("products")?.objects().orEmpty() }.count { it.optString("store") == "google" }
            if (wanted > 0 && products.isEmpty())
                throw PurchasesException(PurchasesError(PurchasesErrorCode.ConfigurationError, "None of the products registered in the Aplyna catalog could be fetched from Google Play."))
            return Offerings.assemble(catalog, products).also { offerings = it; offeringsAt = System.currentTimeMillis() }
        } catch (error: Throwable) {
            // A previous successful answer stays usable when the refresh fails.
            offerings?.let { return it }
            throw error
        }
    }

    // Purchasing

    suspend fun awaitPurchase(purchaseParams: PurchaseParams): PurchaseResult {
        try {
            runCatching { flushAttributes() }
            val info = client.purchase(purchaseParams.activity, purchaseParams.product.id,
                AplynaBillingPurchaseOptions(replacedProductId = purchaseParams.oldProductId, replacementMode = purchaseParams.googleReplacementMode?.aplyna))
            return PurchaseResult(StoreTransaction(listOf(purchaseParams.product.productId), System.currentTimeMillis()), publish(info))
        } catch (error: Throwable) {
            val mapped = PurchasesError.from(error)
            throw PurchasesTransactionException(mapped, mapped.code == PurchasesErrorCode.PurchaseCancelledError)
        }
    }
    suspend fun awaitRestore(): CustomerInfo = guarded { publish(client.restore()) }
    suspend fun awaitSyncPurchases(): CustomerInfo = guarded { publish(client.sync()) }

    // Customer info

    suspend fun awaitCustomerInfo(fetchPolicy: CacheFetchPolicy = CacheFetchPolicy.default()): CustomerInfo = guarded {
        val memory = latest
        val known = memory?.first ?: cachedOnDisk()
        val fresh = memory != null && System.currentTimeMillis() - memory.second < STALE_MILLIS
        when (fetchPolicy) {
            CacheFetchPolicy.CACHE_ONLY -> return@guarded known?.let { CustomerInfo.from(it, user) }
                ?: throw PurchasesException(PurchasesError(PurchasesErrorCode.CustomerInfoError, "No cached customer info is available."))
            CacheFetchPolicy.CACHED_OR_FETCHED -> if (known != null) {
                if (!fresh) scope.launch { runCatching { refresh() } }
                return@guarded CustomerInfo.from(known, user)
            }
            CacheFetchPolicy.NOT_STALE_CACHED_OR_CURRENT -> if (memory != null && fresh) return@guarded CustomerInfo.from(memory.first, user)
            CacheFetchPolicy.FETCH_CURRENT -> Unit
        }
        try { refresh() } catch (error: Throwable) {
            // Offline or server trouble: show the last verified answer instead of failing,
            // unless the caller asked for a current one. Expired entitlements stay expired.
            if (fetchPolicy != CacheFetchPolicy.FETCH_CURRENT && known != null) CustomerInfo.from(known, user) else throw error
        }
    }
    fun invalidateCustomerInfoCache() { latest = null }
    private suspend fun refresh(): CustomerInfo = publish(client.sync())
    private fun cachedOnDisk(): AplynaBillingCustomerInfo? =
        prefs.getString("customerInfo", null)?.let { runCatching { AplynaBillingCustomerInfo(JSONObject(it)) }.getOrNull() }

    private fun publish(info: AplynaBillingCustomerInfo): CustomerInfo {
        latest = info to System.currentTimeMillis()
        prefs.edit().putString("customerInfo", info.json.toString()).apply()
        val value = CustomerInfo.from(info, user)
        val previous = lastPublished
        lastPublished = value
        if (previous == null || previous.entitlements != value.entitlements || previous.activeSubscriptions != value.activeSubscriptions)
            updatedCustomerInfoListener?.let { listener -> scope.launch { listener.onReceived(value) } }
        return value
    }

    // Identity

    /**
     * Associates this install's purchases with the app's own user ID. `created` is true the first
     * time this install sees the ID. Purchases stay with the device's billing customer.
     */
    suspend fun awaitLogIn(appUserID: String): LogInResult = guarded {
        if (!AppUserIDs.isValid(appUserID)) throw PurchasesException(PurchasesError(PurchasesErrorCode.InvalidAppUserIdError))
        val seen = prefs.getStringSet("seenUsers", emptySet()).orEmpty()
        val created = appUserID !in seen
        if (appUserID != user) {
            user = appUserID
            prefs.edit().putString("appUserID", appUserID).putStringSet("seenUsers", seen + appUserID).apply()
            queueAttributes(mapOf("\$appUserId" to appUserID), validate = false)
        }
        runCatching { flushAttributes() }
        LogInResult(awaitCustomerInfo(CacheFetchPolicy.FETCH_CURRENT), created)
    }
    suspend fun awaitLogOut(): CustomerInfo = guarded {
        if (isAnonymous) throw PurchasesException(PurchasesError(PurchasesErrorCode.LogOutWithAnonymousUserError))
        runCatching { flushAttributes() }
        user = AppUserIDs.anonymous()
        prefs.edit().putString("appUserID", user).apply()
        queueAttributes(mapOf("\$appUserId" to null), validate = false)
        // Tell the server now that this install no longer carries the user ID; a failure is retried later.
        runCatching { flushAttributes() }
        offerings = null
        awaitCustomerInfo(CacheFetchPolicy.FETCH_CURRENT)
    }

    // Attributes

    /** Null or empty values delete the attribute. Invalid keys are ignored. */
    fun setAttributes(attributes: Map<String, String?>) { scope.launch { queueAttributes(attributes, validate = true); runCatching { flushAttributes() } } }
    fun setEmail(email: String?) = setAttributes(mapOf(SubscriberAttributes.EMAIL to email))
    fun setDisplayName(displayName: String?) = setAttributes(mapOf(SubscriberAttributes.DISPLAY_NAME to displayName))
    fun setPhoneNumber(phoneNumber: String?) = setAttributes(mapOf(SubscriberAttributes.PHONE_NUMBER to phoneNumber))
    fun setPushToken(fcmToken: String?) = setAttributes(mapOf(SubscriberAttributes.FCM_TOKENS to fcmToken))

    private suspend fun queueAttributes(values: Map<String, String?>, validate: Boolean) = attributes.withLock {
        val pending = JSONObject(prefs.getString("attributes", null) ?: "{}")
        for ((key, raw) in values) {
            if (validate && !SubscriberAttributes.isValidKey(key)) continue
            pending.put(key, JSONObject().put("value", SubscriberAttributes.normalized(raw) ?: JSONObject.NULL).put("updatedAtMs", System.currentTimeMillis()))
        }
        prefs.edit().putString("attributes", pending.toString()).apply()
    }
    /** Unsent attributes are kept on the device and retried on the next call or launch. */
    private suspend fun flushAttributes(): Int = attributes.withLock {
        val raw = prefs.getString("attributes", null) ?: return@withLock 0
        val pending = JSONObject(raw)
        if (pending.length() == 0) return@withLock 0
        client.sendAttributes(pending)
        prefs.edit().remove("attributes").apply()
        pending.length()
    }
    suspend fun awaitSyncAttributesAndOfferingsIfNeeded(): Offerings = guarded { flushAttributes(); loadOfferings(true) }

    // Callback variants

    fun getOfferings(listener: ReceiveOfferingsCallback) = getOfferingsWith(listener::onError, listener::onReceived)
    fun getOfferingsWith(onError: (PurchasesError) -> Unit = {}, onSuccess: (Offerings) -> Unit) = run(onError, onSuccess) { awaitOfferings() }
    fun getCustomerInfo(callback: ReceiveCustomerInfoCallback) = getCustomerInfoWith(callback::onError, callback::onReceived)
    fun getCustomerInfoWith(onError: (PurchasesError) -> Unit = {}, onSuccess: (CustomerInfo) -> Unit) = run(onError, onSuccess) { awaitCustomerInfo() }
    fun restorePurchases(callback: ReceiveCustomerInfoCallback) = restorePurchasesWith(callback::onError, callback::onReceived)
    fun restorePurchasesWith(onError: (PurchasesError) -> Unit = {}, onSuccess: (CustomerInfo) -> Unit) = run(onError, onSuccess) { awaitRestore() }
    fun syncPurchases() { scope.launch { runCatching { awaitSyncPurchases() } } }
    fun logOut(callback: ReceiveCustomerInfoCallback? = null) = run({ callback?.onError(it) }, { callback?.onReceived(it) }) { awaitLogOut() }
    fun logIn(appUserID: String, callback: LogInCallback? = null) = logInWith(appUserID, { callback?.onError(it) }) { info, created -> callback?.onReceived(info, created) }
    fun logInWith(appUserID: String, onError: (PurchasesError) -> Unit = {}, onSuccess: (CustomerInfo, Boolean) -> Unit) =
        run(onError, { result: LogInResult -> onSuccess(result.customerInfo, result.created) }) { awaitLogIn(appUserID) }
    fun purchase(purchaseParams: PurchaseParams, callback: PurchaseCallback) =
        purchaseWith(purchaseParams, callback::onError) { transaction, info -> callback.onCompleted(transaction, info) }
    fun purchaseWith(purchaseParams: PurchaseParams, onError: (PurchasesError, Boolean) -> Unit = { _, _ -> }, onSuccess: (StoreTransaction, CustomerInfo) -> Unit) {
        scope.launch {
            try { awaitPurchase(purchaseParams).let { onSuccess(it.storeTransaction, it.customerInfo) } }
            catch (error: PurchasesTransactionException) { onError(error.error, error.userCancelled) }
            catch (error: Throwable) { onError(PurchasesError.from(error), false) }
        }
    }

    private fun <T> run(onError: (PurchasesError) -> Unit, onSuccess: (T) -> Unit, work: suspend () -> T) {
        scope.launch { try { onSuccess(work()) } catch (error: Throwable) { onError(PurchasesError.from(error)) } }
    }
    private suspend fun <T> guarded(work: suspend () -> T): T =
        try { work() } catch (error: PurchasesException) { throw error } catch (error: Throwable) { throw PurchasesException(PurchasesError.from(error)) }

    // Returning to the app refreshes a stale answer: renewals, cancellations and purchases
    // approved outside the app reach the listener without the app asking.
    override fun onActivityResumed(activity: Activity) {
        val memory = latest
        if (memory == null || System.currentTimeMillis() - memory.second >= STALE_MILLIS) scope.launch { runCatching { refresh() }; runCatching { flushAttributes() } }
    }
    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
