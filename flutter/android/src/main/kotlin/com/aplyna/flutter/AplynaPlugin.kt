package com.aplyna.flutter

import android.os.Handler
import android.os.Looper
import android.app.Activity
import com.aplyna.sdk.AplynaBridge
import com.aplyna.sdk.AplynaBillingBridge
import com.aplyna.sdk.AplynaBillingException
import com.aplyna.sdk.AplynaHttpException
import com.aplyna.sdk.PurchasesBridge
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlinx.coroutines.*

class AplynaPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private var bridge: AplynaBridge? = null
    private var billing: AplynaBillingBridge? = null
    private var purchasesContext: android.content.Context? = null
    private var activity: Activity? = null
    private var billingScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var attached = false
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        executor = Executors.newSingleThreadExecutor()
        bridge = AplynaBridge(binding.applicationContext.filesDir, binding.applicationContext)
        billingScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        billing = AplynaBillingBridge(binding.applicationContext)
        purchasesContext = binding.applicationContext
        attached = true
        channel = MethodChannel(binding.binaryMessenger, "com.aplyna/sdk").also { it.setMethodCallHandler(this) }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "invoke") { result.notImplemented(); return }
        val method = call.argument<String>("method")
        val json = call.argument<String>("argumentsJSON")
        val sdk = bridge
        if (method == null || json == null || sdk == null) { result.error("APLYNA_ARGUMENTS", "Use a method and JSON arguments on an attached engine", null); return }
        if (method.startsWith("purchases.")) {
            // RevenueCat-compatible API: numeric error code, readable code and userCancelled in details.
            val context = purchasesContext ?: run { result.error("23", "The billing engine is detached.", null); return }
            billingScope.launch {
                try { val response = PurchasesBridge(context).invoke(method, json, activity); if (attached) result.success(response) }
                catch (e: CancellationException) { if (e is TimeoutCancellationException) { if (attached) result.error("2", "The store did not answer in time.", null) } else throw e }
                catch (e: Exception) {
                    val payload = PurchasesBridge.errorPayload(e)
                    val details = payload.third.keys().asSequence().associateWith { key -> payload.third.get(key).takeIf { it != org.json.JSONObject.NULL } }
                    if (attached) result.error(payload.first, payload.second, details)
                }
            }
            return
        }
        if (method.startsWith("billing.")) {
            val configured = billing ?: run { result.error("APLYNA_BILLING_CLOSED", "The billing engine is detached.", null); return }
            billingScope.launch {
                try { val response = configured.invoke(method, json, activity); if (attached) result.success(response) }
                catch (e: TimeoutCancellationException) { if (attached) result.error("APLYNA_BILLING_TIMEOUT", "Billing timed out; foreground sync will reconcile any completed purchase.", null) }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) { if (attached) result.error(if (e is AplynaBillingException) e.code else "APLYNA_SDK", e.message, null) }
            }
            return
        }
        try {
            executor.execute {
                try { val response = sdk.invoke(method, json); main.post { if (attached) result.success(response) } }
                catch (error: Exception) { main.post { if (attached) result.error(if (error is AplynaHttpException) "APLYNA_HTTP_${error.status}" else "APLYNA_SDK", error.message, null) } }
            }
        } catch (error: Exception) { result.error("APLYNA_SDK", error.message, null) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel?.setMethodCallHandler(null)
        channel = null
        bridge = null
        billing?.close(); billing = null; purchasesContext = null; billingScope.cancel(); activity = null
        executor.shutdownNow()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }
}
