package com.aplyna.sdk

import org.json.JSONObject
import java.util.Date

// Aplyna's purchase API uses the same names and shapes as RevenueCat's public SDK so an app
// can switch by changing its imports and API key. This is an independent implementation on
// top of AplynaBillingClient; it talks only to the Aplyna billing gateway.

/** Same names and numeric codes as RevenueCat's PurchasesErrorCode. */
enum class PurchasesErrorCode(val code: Int, val description: String) {
    UnknownError(0, "Unknown error."),
    PurchaseCancelledError(1, "Purchase was cancelled."),
    StoreProblemError(2, "There was a problem with the store."),
    PurchaseNotAllowedError(3, "The device or user is not allowed to make the purchase."),
    PurchaseInvalidError(4, "One or more of the arguments provided are invalid."),
    ProductNotAvailableForPurchaseError(5, "The product is not available for purchase."),
    ProductAlreadyPurchasedError(6, "This product is already active for the user."),
    ReceiptAlreadyInUseError(7, "There is already another active subscriber using the same receipt."),
    InvalidReceiptError(8, "The receipt is not valid."),
    MissingReceiptFileError(9, "The receipt is missing."),
    NetworkError(10, "Error performing request."),
    InvalidCredentialsError(11, "There was a credentials issue. Check the underlying error for more details."),
    UnexpectedBackendResponseError(12, "Received unexpected response from the backend."),
    InvalidAppUserIdError(14, "The app user id is not valid."),
    OperationAlreadyInProgressError(15, "The operation is already in progress."),
    UnknownBackendError(16, "There was an unknown backend error."),
    InvalidAppleSubscriptionKeyError(17, "Apple Subscription Key is invalid or not present."),
    IneligibleError(18, "The User is ineligible for that action."),
    InsufficientPermissionsError(19, "App does not have sufficient permissions to make purchases."),
    PaymentPendingError(20, "The payment is pending."),
    InvalidSubscriberAttributesError(21, "One or more of the attributes sent could not be saved."),
    LogOutWithAnonymousUserError(22, "Called logOut but the current user is anonymous."),
    ConfigurationError(23, "There is an issue with your configuration. Check the underlying error for more details."),
    UnsupportedError(24, "There was a problem with the operation. Looks like we doesn't support that yet."),
    EmptySubscriberAttributesError(25, "A request for subscriber attributes returned none."),
    CustomerInfoError(29, "There was a problem related to the customer info.");

    /** Stable text code, as exposed by the hybrid SDKs. */
    val readableCode: String get() = when (this) {
        UnknownError -> "UNKNOWN"
        PurchaseCancelledError -> "PURCHASE_CANCELLED"
        StoreProblemError -> "STORE_PROBLEM"
        PurchaseNotAllowedError -> "PURCHASE_NOT_ALLOWED"
        PurchaseInvalidError -> "PURCHASE_INVALID"
        ProductNotAvailableForPurchaseError -> "PRODUCT_NOT_AVAILABLE_FOR_PURCHASE"
        ProductAlreadyPurchasedError -> "PRODUCT_ALREADY_PURCHASED"
        ReceiptAlreadyInUseError -> "RECEIPT_ALREADY_IN_USE"
        InvalidReceiptError -> "INVALID_RECEIPT"
        MissingReceiptFileError -> "MISSING_RECEIPT_FILE"
        NetworkError -> "NETWORK_ERROR"
        InvalidCredentialsError -> "INVALID_CREDENTIALS"
        UnexpectedBackendResponseError -> "UNEXPECTED_BACKEND_RESPONSE_ERROR"
        InvalidAppUserIdError -> "INVALID_APP_USER_ID"
        OperationAlreadyInProgressError -> "OPERATION_ALREADY_IN_PROGRESS"
        UnknownBackendError -> "UNKNOWN_BACKEND_ERROR"
        InvalidAppleSubscriptionKeyError -> "INVALID_APPLE_SUBSCRIPTION_KEY"
        IneligibleError -> "INELIGIBLE_ERROR"
        InsufficientPermissionsError -> "INSUFFICIENT_PERMISSIONS_ERROR"
        PaymentPendingError -> "PAYMENT_PENDING_ERROR"
        InvalidSubscriberAttributesError -> "INVALID_SUBSCRIBER_ATTRIBUTES"
        LogOutWithAnonymousUserError -> "LOGOUT_CALLED_WITH_ANONYMOUS_USER"
        ConfigurationError -> "CONFIGURATION_ERROR"
        UnsupportedError -> "UNSUPPORTED_ERROR"
        EmptySubscriberAttributesError -> "EMPTY_SUBSCRIBER_ATTRIBUTES"
        CustomerInfoError -> "CUSTOMER_INFO_ERROR"
    }
}

class PurchasesError(val code: PurchasesErrorCode, val underlyingErrorMessage: String? = null) {
    val message: String get() = code.description
    override fun toString() = "PurchasesError(code=$code, underlyingErrorMessage=$underlyingErrorMessage, message='$message')"

    companion object {
        /** Translates store, transport and gateway failures into the RevenueCat error codes. */
        fun from(error: Throwable): PurchasesError = when (error) {
            is PurchasesException -> error.error
            is AplynaBillingException -> PurchasesError(code(error.code), error.message)
            is java.io.IOException -> PurchasesError(PurchasesErrorCode.NetworkError, error.message)
            is kotlinx.coroutines.TimeoutCancellationException -> PurchasesError(PurchasesErrorCode.StoreProblemError, "Google Play did not answer in time.")
            else -> PurchasesError(PurchasesErrorCode.UnknownError, error.message)
        }

        fun code(aplynaCode: String): PurchasesErrorCode = when {
            aplynaCode == "APLYNA_BILLING_CANCELLED" -> PurchasesErrorCode.PurchaseCancelledError
            aplynaCode == "APLYNA_BILLING_PENDING" -> PurchasesErrorCode.PaymentPendingError
            aplynaCode == "APLYNA_BILLING_IN_PROGRESS" -> PurchasesErrorCode.OperationAlreadyInProgressError
            aplynaCode == "APLYNA_BILLING_ALREADY_OWNED" -> PurchasesErrorCode.ProductAlreadyPurchasedError
            aplynaCode == "APLYNA_BILLING_UNAVAILABLE" -> PurchasesErrorCode.StoreProblemError
            aplynaCode == "APLYNA_BILLING_UNSUPPORTED" -> PurchasesErrorCode.PurchaseNotAllowedError
            aplynaCode in setOf("APLYNA_BILLING_PRODUCT", "APLYNA_BILLING_OFFER", "APLYNA_BILLING_STORE_4") -> PurchasesErrorCode.ProductNotAvailableForPurchaseError
            aplynaCode == "APLYNA_BILLING_STORE_5" || aplynaCode == "APLYNA_ARGUMENTS" || aplynaCode == "APLYNA_BILLING_ACTIVITY" -> PurchasesErrorCode.PurchaseInvalidError
            aplynaCode.startsWith("APLYNA_BILLING_STORE_") || aplynaCode == "APLYNA_BILLING_UPDATE" -> PurchasesErrorCode.StoreProblemError
            aplynaCode in setOf("APLYNA_BILLING_CUSTOMER_CONFLICT", "APLYNA_BILLING_IDENTITY_IN_USE", "APLYNA_HTTP_409") -> PurchasesErrorCode.ReceiptAlreadyInUseError
            aplynaCode in setOf("APLYNA_BILLING_NETWORK", "APLYNA_BILLING_OFFLINE") -> PurchasesErrorCode.NetworkError
            aplynaCode in setOf("APLYNA_BILLING_SCOPE", "APLYNA_BILLING_NOT_READY", "APLYNA_BILLING_SANDBOX_SETUP", "APLYNA_BILLING_NOT_CONFIGURED", "APLYNA_BILLING_CLOSED") -> PurchasesErrorCode.ConfigurationError
            aplynaCode == "APLYNA_BILLING_RESPONSE" || aplynaCode == "APLYNA_HTTP_404" -> PurchasesErrorCode.UnexpectedBackendResponseError
            aplynaCode == "APLYNA_BILLING_IDENTITY" -> PurchasesErrorCode.CustomerInfoError
            aplynaCode == "APLYNA_BILLING_LIMIT" -> PurchasesErrorCode.StoreProblemError
            aplynaCode == "APLYNA_HTTP_401" || aplynaCode == "APLYNA_HTTP_403" -> PurchasesErrorCode.InvalidCredentialsError
            aplynaCode == "APLYNA_HTTP_400" || aplynaCode == "APLYNA_HTTP_422" -> PurchasesErrorCode.PurchaseInvalidError
            aplynaCode.startsWith("APLYNA_HTTP_") -> PurchasesErrorCode.UnknownBackendError
            else -> PurchasesErrorCode.UnknownError
        }
    }
}

open class PurchasesException(val error: PurchasesError) : Exception(error.underlyingErrorMessage ?: error.message) {
    val code: PurchasesErrorCode get() = error.code
    val underlyingErrorMessage: String? get() = error.underlyingErrorMessage
}

/** Thrown by awaitPurchase. `userCancelled` is true when the customer closed the checkout. */
class PurchasesTransactionException(error: PurchasesError, val userCancelled: Boolean) : PurchasesException(error)

// MARK: Customer info

enum class PeriodType { NORMAL, INTRO, TRIAL, PREPAID }
enum class Store { APP_STORE, MAC_APP_STORE, PLAY_STORE, STRIPE, PROMOTIONAL, UNKNOWN_STORE, AMAZON }
enum class OwnershipType { PURCHASED, FAMILY_SHARED, UNKNOWN }

data class EntitlementInfo(
    val identifier: String, val isActive: Boolean, val willRenew: Boolean, val periodType: PeriodType,
    val latestPurchaseDate: Date?, val originalPurchaseDate: Date?, val expirationDate: Date?, val store: Store,
    val productIdentifier: String, val productPlanIdentifier: String?, val isSandbox: Boolean,
    /** When renewal was turned off; the verification time of the answer that reported it. */
    val unsubscribeDetectedAt: Date?,
    /** When a billing problem was reported; the verification time of the answer that reported it. */
    val billingIssueDetectedAt: Date?,
    val ownershipType: OwnershipType = OwnershipType.PURCHASED
)

data class EntitlementInfos(val all: Map<String, EntitlementInfo>) {
    val active: Map<String, EntitlementInfo> get() = all.filterValues { it.isActive }
    operator fun get(identifier: String): EntitlementInfo? = all[identifier]
}

data class CustomerInfo(
    val entitlements: EntitlementInfos, val activeSubscriptions: Set<String>, val allPurchasedProductIds: Set<String>,
    val allExpirationDatesByProduct: Map<String, Date?>, val latestExpirationDate: Date?, val originalAppUserId: String,
    val requestDate: Date, val managementUrlString: String?
) {
    val managementURL: android.net.Uri? get() = managementUrlString?.let(android.net.Uri::parse)
    fun getExpirationDateForProductId(productId: String): Date? = allExpirationDatesByProduct[productId]
    fun getExpirationDateForEntitlement(identifier: String): Date? = entitlements[identifier]?.expirationDate

    companion object {
        /**
         * Builds the RevenueCat-shaped view of a server-verified answer. `nowMillis` only decides
         * whether an already verified expiry has passed; it never grants access.
         */
        fun from(info: AplynaBillingCustomerInfo, appUserID: String, nowMillis: Long = System.currentTimeMillis()): CustomerInfo {
            val checked = Date(billingDateMillis(info.checkedAt))
            val sandbox = info.environment == "sandbox"
            val rows = info.json.optJSONArray("subscriptions")?.objects().orEmpty()
            fun split(id: String) = id.split(':').let { it[0] to it.getOrNull(1) }
            val all = info.entitlements.associate { entitlement ->
                val row = rows.firstOrNull { it.getString("productId") == entitlement.productId }
                val expiry = entitlement.expiresAt?.let(::billingDateMillis)
                val retry = row?.nullableBoolean("billingRetry") == true
                val renews = row?.nullableBoolean("autoRenew")
                val (product, plan) = split(entitlement.productId)
                entitlement.identifier to EntitlementInfo(
                    identifier = entitlement.identifier, isActive = entitlement.active && (expiry == null || nowMillis < expiry),
                    willRenew = renews == true && !retry, periodType = if (row?.nullableBoolean("isTrial") == true) PeriodType.TRIAL else PeriodType.NORMAL,
                    latestPurchaseDate = null, originalPurchaseDate = null, expirationDate = expiry?.let(::Date),
                    store = if (row?.nullableString("provider") == "apple") Store.APP_STORE else Store.PLAY_STORE,
                    productIdentifier = product, productPlanIdentifier = plan, isSandbox = sandbox,
                    unsubscribeDetectedAt = if (renews == false) checked else null, billingIssueDetectedAt = if (retry) checked else null)
            }
            val expirations = mutableMapOf<String, Long>()
            for (row in rows) row.nullableString("expiresAt")?.let(::billingDateMillis)?.let { expirations[row.getString("productId")] = maxOf(it, expirations[row.getString("productId")] ?: Long.MIN_VALUE) }
            val providers = rows.map { it.nullableString("provider") }
            return CustomerInfo(
                entitlements = EntitlementInfos(all),
                activeSubscriptions = rows.filter { it.getBoolean("active") && (expirations[it.getString("productId")] ?: Long.MAX_VALUE) > nowMillis }.map { it.getString("productId") }.toSet(),
                allPurchasedProductIds = rows.map { it.getString("productId") }.toSet(),
                allExpirationDatesByProduct = expirations.mapValues { Date(it.value) },
                latestExpirationDate = expirations.values.maxOrNull()?.let(::Date), originalAppUserId = appUserID, requestDate = checked,
                managementUrlString = when { "google" in providers -> "https://play.google.com/store/account/subscriptions"; "apple" in providers -> "https://apps.apple.com/account/subscriptions"; else -> null })
        }
    }
}

// MARK: Offerings

enum class PackageType(val identifier: String?) {
    UNKNOWN(null), CUSTOM(null), LIFETIME("\$rc_lifetime"), ANNUAL("\$rc_annual"), SIX_MONTH("\$rc_six_month"), THREE_MONTH("\$rc_three_month"),
    TWO_MONTH("\$rc_two_month"), MONTHLY("\$rc_monthly"), WEEKLY("\$rc_weekly");

    companion object {
        /** RevenueCat's reserved `$rc_` package identifiers keep their meaning; plain names work too. */
        fun from(identifier: String): PackageType = when (identifier.lowercase().removePrefix("\$rc_").removePrefix("\$aplyna_")) {
            "lifetime" -> LIFETIME; "annual", "yearly" -> ANNUAL; "six_month", "sixmonth" -> SIX_MONTH
            "three_month", "threemonth", "quarterly" -> THREE_MONTH; "two_month", "twomonth" -> TWO_MONTH
            "monthly" -> MONTHLY; "weekly" -> WEEKLY; else -> CUSTOM
        }
    }
}

data class Price(val formatted: String, val amountMicros: Long, val currencyCode: String)

data class Period(val value: Int, val unit: Unit, val iso8601: String) {
    enum class Unit { DAY, WEEK, MONTH, YEAR, UNKNOWN }
    companion object {
        fun create(iso8601: String): Period {
            val match = Regex("^P(\\d+)([DWMY])$").find(iso8601) ?: return Period(0, Unit.UNKNOWN, iso8601)
            val unit = when (match.groupValues[2]) { "D" -> Unit.DAY; "W" -> Unit.WEEK; "M" -> Unit.MONTH; else -> Unit.YEAR }
            return Period(match.groupValues[1].toInt(), unit, iso8601)
        }
    }
}

enum class ProductType { SUBS, INAPP, UNKNOWN }

data class StoreProduct(
    /** `productId:basePlanId` for Google Play subscriptions, as in RevenueCat. */
    val id: String, val type: ProductType, val price: Price, val title: String, val description: String, val period: Period?,
    val productId: String, val basePlanId: String?, val freeTrialPeriod: Period?, val introductoryPrice: Price?
) {
    companion object {
        /** Uses the regular base-plan price; a free first phase is reported as the free trial. */
        fun from(product: AplynaBillingProduct): StoreProduct {
            val regular = product.offers.firstOrNull { it.offerId == null } ?: product.offers.firstOrNull()
            val recurring = regular?.pricingPhases?.lastOrNull()
            val phases = product.offers.flatMap { it.pricingPhases.dropLast(1) }
            val free = phases.firstOrNull { it.amountMicros == "0" }
            val intro = phases.firstOrNull { it.amountMicros != "0" }
            return StoreProduct(
                id = product.id, type = ProductType.SUBS,
                price = Price(recurring?.price ?: product.price, recurring?.amountMicros?.toLongOrNull() ?: 0, recurring?.currency.orEmpty()),
                title = product.name, description = "", period = recurring?.billingPeriod?.let(Period::create),
                productId = product.storeProductId, basePlanId = product.basePlanId,
                freeTrialPeriod = free?.billingPeriod?.let(Period::create),
                introductoryPrice = intro?.let { Price(it.price, it.amountMicros.toLongOrNull() ?: 0, it.currency) })
        }
    }
}

data class PresentedOfferingContext(val offeringIdentifier: String)

data class Package(val identifier: String, val packageType: PackageType, val product: StoreProduct, val presentedOfferingContext: PresentedOfferingContext) {
    val offering: String get() = presentedOfferingContext.offeringIdentifier
}

data class Offering(val identifier: String, val serverDescription: String, val metadata: Map<String, Any>, val availablePackages: List<Package>) {
    val lifetime: Package? get() = first(PackageType.LIFETIME)
    val annual: Package? get() = first(PackageType.ANNUAL)
    val sixMonth: Package? get() = first(PackageType.SIX_MONTH)
    val threeMonth: Package? get() = first(PackageType.THREE_MONTH)
    val twoMonth: Package? get() = first(PackageType.TWO_MONTH)
    val monthly: Package? get() = first(PackageType.MONTHLY)
    val weekly: Package? get() = first(PackageType.WEEKLY)
    operator fun get(identifier: String): Package? = getPackage(identifier)
    fun getPackage(identifier: String): Package? = availablePackages.firstOrNull { it.identifier == identifier }
    private fun first(type: PackageType) = availablePackages.firstOrNull { it.packageType == type }
}

data class Offerings(val current: Offering?, val all: Map<String, Offering>) {
    operator fun get(identifier: String): Offering? = all[identifier]
    fun getOffering(identifier: String): Offering? = all[identifier]

    companion object {
        /**
         * Attaches store products to the catalog. A package whose product the store did not return
         * is left out; an offering with no purchasable package is left out too.
         */
        fun assemble(catalog: JSONObject, products: List<AplynaBillingProduct>, store: String = "google"): Offerings {
            val byId = products.associateBy { it.id }
            val all = linkedMapOf<String, Offering>()
            for (offering in catalog.optJSONArray("offerings")?.objects().orEmpty()) {
                val id = offering.getString("identifier")
                val packages = offering.optJSONArray("packages")?.objects().orEmpty().mapNotNull { pack ->
                    val item = pack.optJSONArray("products")?.objects().orEmpty().firstOrNull { it.optString("store") == store && byId.containsKey(it.optString("identifier")) } ?: return@mapNotNull null
                    Package(pack.getString("identifier"), PackageType.from(pack.getString("identifier")), StoreProduct.from(byId.getValue(item.getString("identifier"))), PresentedOfferingContext(id))
                }
                if (packages.isNotEmpty()) all[id] = Offering(id, offering.nullableString("description").orEmpty(), emptyMap(), packages)
            }
            return Offerings(catalog.nullableString("current")?.let { all[it] }, all)
        }
    }
}

enum class CacheFetchPolicy {
    CACHE_ONLY, FETCH_CURRENT, NOT_STALE_CACHED_OR_CURRENT, CACHED_OR_FETCHED;
    companion object { fun default() = NOT_STALE_CACHED_OR_CURRENT }
}

enum class LogLevel { VERBOSE, DEBUG, INFO, WARN, ERROR }

data class LogInResult(val customerInfo: CustomerInfo, val created: Boolean)
data class StoreTransaction(val productIds: List<String>, val purchaseTime: Long)
data class PurchaseResult(val storeTransaction: StoreTransaction, val customerInfo: CustomerInfo)

/** Customer attributes with RevenueCat's reserved keys and limits. */
object SubscriberAttributes {
    const val EMAIL = "\$email"
    const val DISPLAY_NAME = "\$displayName"
    const val PHONE_NUMBER = "\$phoneNumber"
    const val FCM_TOKENS = "\$fcmTokens"
    val reserved = setOf(EMAIL, DISPLAY_NAME, PHONE_NUMBER, FCM_TOKENS, "\$apnsTokens", "\$idfa", "\$idfv", "\$gpsAdId", "\$ip", "\$attConsentStatus",
        "\$mediaSource", "\$campaign", "\$adGroup", "\$ad", "\$keyword", "\$creative", "\$adjustId", "\$appsflyerId", "\$fbAnonId", "\$mparticleId", "\$onesignalId",
        "\$airshipChannelId", "\$cleverTapId", "\$mixpanelDistinctId", "\$firebaseAppInstanceId", "\$posthogUserId", "\$amplitudeUserId", "\$amplitudeDeviceId")

    /** Keys: a letter, then letters, digits or underscores, 40 characters at most; `$` only for reserved keys. */
    fun isValidKey(key: String): Boolean = key in reserved || Regex("^[A-Za-z][A-Za-z0-9_]{0,39}$").matches(key)
    /** Values are at most 500 characters; null or empty deletes the attribute. */
    fun normalized(value: String?): String? = value?.takeIf { it.isNotEmpty() }?.take(500)
}

object AppUserIDs {
    const val ANONYMOUS_PREFIX = "\$AplynaAnonymousID:"
    fun anonymous(): String = ANONYMOUS_PREFIX + java.util.UUID.randomUUID().toString().replace("-", "")
    fun isAnonymous(id: String): Boolean = id.startsWith(ANONYMOUS_PREFIX) || id.startsWith("\$RCAnonymousID:")
    /** Same rules as RevenueCat: not blank, at most 100 characters, no `/`, and not a placeholder value. */
    fun isValid(id: String): Boolean = id.trim().isNotEmpty() && id.length <= 100 && !id.contains('/') &&
        id.trim().lowercase() !in setOf("null", "nil", "none", "undefined", "(null)", "nan", "unidentified", "no_user")
}
