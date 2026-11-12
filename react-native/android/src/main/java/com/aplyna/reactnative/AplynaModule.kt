package com.aplyna.reactnative

import com.aplyna.sdk.AplynaBridge
import com.aplyna.sdk.AplynaBillingBridge
import com.aplyna.sdk.AplynaBillingException
import com.aplyna.sdk.AplynaHttpException
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.annotations.ReactModule
import java.util.concurrent.Executors
import kotlinx.coroutines.*

@ReactModule(name = AplynaModule.NAME)
class AplynaModule(context: ReactApplicationContext) : NativeAplynaSpec(context) {
    private val bridge = AplynaBridge(context.filesDir, context.applicationContext)
    private val billing = AplynaBillingBridge(context.applicationContext)
    private val billingScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val executor = Executors.newSingleThreadExecutor()
    override fun getName() = NAME
    override fun invoke(method: String, argumentsJSON: String, promise: Promise) {
        if (method.startsWith("purchases.")) {
            // RevenueCat-compatible API: the numeric error code is the rejection code.
            billingScope.launch {
                try { promise.resolve(com.aplyna.sdk.PurchasesBridge(reactApplicationContext.applicationContext).invoke(method, argumentsJSON, reactApplicationContext.currentActivity)) }
                catch (e: CancellationException) { if (e is TimeoutCancellationException) promise.reject("2", "The store did not answer in time.", e) else throw e }
                catch (e: Exception) { val payload = com.aplyna.sdk.PurchasesBridge.errorPayload(e); promise.reject(payload.first, payload.second, e) }
            }
            return
        }
        if (method.startsWith("billing.")) {
            billingScope.launch {
                try { promise.resolve(billing.invoke(method, argumentsJSON, reactApplicationContext.currentActivity)) }
                catch (e: TimeoutCancellationException) { promise.reject("APLYNA_BILLING_TIMEOUT", "Billing timed out; foreground sync will reconcile any completed purchase.", e) }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) { promise.reject(if (e is AplynaBillingException) e.code else "APLYNA_SDK", e.message, e) }
            }
            return
        }
        try {
            executor.execute {
                try { promise.resolve(bridge.invoke(method, argumentsJSON)) }
                catch (error: Exception) { promise.reject(if (error is AplynaHttpException) "APLYNA_HTTP_${error.status}" else "APLYNA_SDK", error.message, error) }
            }
        } catch (error: Exception) { promise.reject("APLYNA_SDK", error.message, error) }
    }
    override fun invalidate() { billing.close(); billingScope.cancel(); executor.shutdownNow(); super.invalidate() }
    companion object { const val NAME = "Aplyna" }
}
