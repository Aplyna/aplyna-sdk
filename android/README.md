# Aplyna for Android

Kotlin library `com.aplyna.sdk`, Android API 23+, Play Billing 9, coroutines.

## Install

Clone this repository and include the module:

```kotlin
// settings.gradle.kts
include(":aplyna-sdk")
project(":aplyna-sdk").projectDir = file("../aplyna-sdk/android")

// app/build.gradle.kts
dependencies { implementation(project(":aplyna-sdk")) }
```

## Use

```kotlin
import com.aplyna.sdk.*

Purchases.configure(PurchasesConfiguration.Builder(context, "aplyna_android_…").build())

val offerings = Purchases.sharedInstance.awaitOfferings()
val result = Purchases.sharedInstance.awaitPurchase(
    PurchaseParams.Builder(activity, offerings.current!!.monthly!!).build())
val unlocked = Purchases.sharedInstance.awaitCustomerInfo().entitlements["premium"]?.isActive == true

Purchases.sharedInstance.awaitRestore()
Purchases.sharedInstance.awaitLogIn("user_123")
Purchases.sharedInstance.setAttributes(mapOf("plan" to "gold"))
Purchases.sharedInstance.updatedCustomerInfoListener = UpdatedCustomerInfoListener { info -> }
```

Callback variants (`getOfferingsWith`, `purchaseWith`, `logInWith`, …) are available. Failures are `PurchasesException` with RevenueCat's `PurchasesErrorCode` values; a closed checkout is a `PurchasesTransactionException` with `userCancelled == true`.

Debuggable builds use the sandbox environment and release builds use production; set `sandbox(true|false)` on the builder to override. Google test purchases need a Play license tester account. To change plan, pass `oldProductId` and a `GoogleReplacementMode` on `PurchaseParams`.

Run the checks with `./gradlew testDebugUnitTest`.
