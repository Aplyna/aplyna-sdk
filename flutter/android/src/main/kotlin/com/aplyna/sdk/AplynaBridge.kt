package com.aplyna.sdk

import org.json.JSONObject
import java.io.File
import java.net.URI
import java.util.UUID
import android.content.Context

/** Shared bridge contract. invoke performs blocking IO: adapters dispatch it off the UI thread. */
class AplynaBridge(private val storageDirectory: File, private val context: Context? = null) {
    private var client: AplynaClient? = null

    @Synchronized fun invoke(method: String, argumentsJson: String): String {
        require(argumentsJson.toByteArray(Charsets.UTF_8).size <= 262144) { "SDK arguments exceed 256 KB" }
        val args = JSONObject(argumentsJson)
        if (method == "configure") {
            val base = text(args, "baseUrl")
            val url = URI(base)
            require(url.host != null && url.userInfo == null && url.query == null && url.fragment == null && (url.scheme == "https" || url.scheme == "http" && url.host in listOf("localhost", "127.0.0.1", "10.0.2.2", "::1"))) { "Use HTTPS, or HTTP on a local development host" }
            val key = text(args, "apiKey")
            val installationId = optionalText(args, "installationId")?.let(::identifier) ?: run {
                val file = File(storageDirectory, "aplyna/installation-id")
                if (file.exists()) identifier(file.readText()) else UUID.randomUUID().toString().also {
                    file.parentFile!!.mkdirs()
                    val temporary = File(file.parentFile, "installation-id.tmp")
                    temporary.writeText(it)
                    check(temporary.renameTo(file)) { "Could not persist installation identity" }
                }
            }
            client = AplynaClient(base, key, installationId, storageDirectory, context)
            return JSONObject().put("installationId", installationId).toString()
        }
        val sdk = checkNotNull(client) { "Configure Aplyna before calling SDK methods" }
        when (method) {
            "setConsent" -> { require(args.opt("granted") is Boolean) { "granted must be a boolean" }; sdk.setConsent(args.getBoolean("granted")) }
            "track" -> {
                val name = text(args, "name")
                require(name.matches(Regex("^[a-z][a-z0-9_]{0,79}$"))) { "Use a lowercase event name of up to 80 characters" }
                val raw = if (args.has("properties")) args.getJSONObject("properties") else JSONObject()
                val properties = raw.keys().asSequence().associateWith { key ->
                    val value = raw.get(key)
                    require(key.length <= 80 && value is String && value.length <= 500) { "Event properties must have string values within the event limits" }
                    value as String
                }
                sdk.track(name, optionalText(args, "flowId")?.let(::identifier), optionalText(args, "stepId")?.let(::identifier), if (args.has("assignment")) assignment(args.getJSONObject("assignment")) else null, properties)
            }
            "expose" -> sdk.expose(assignment(args.getJSONObject("assignment")))
            "flush" -> sdk.flush()
            // ATT is iOS-only; shared host-app callbacks may safely invoke this.
            "collectAppleAdsAttribution" -> Unit // iOS-only attribution
            "refreshTrackingAuthorizationStatus" -> Unit
            "setAppLanguage" -> sdk.setAppLanguage(optionalText(args, "language"))
            "pendingEventCount" -> return sdk.pendingEventCount().toString()
            "assignment" -> {
                val value = sdk.assignment(identifier(text(args, "flowId")))
                return JSONObject().put("flowId", value.flowId).put("experimentId", value.experimentId ?: JSONObject.NULL).put("variant", value.variant).toString()
            }
            "configuration" -> return sdk.configuration(identifier(text(args, "flowId"))).toString()
            else -> throw IllegalArgumentException("Unsupported Aplyna SDK method")
        }
        return "null"
    }
    private fun text(args: JSONObject, key: String): String {
        val value = args.opt(key)
        require(value is String && value.isNotEmpty()) { "$key must be a nonempty string" }
        return value
    }
    private fun optionalText(args: JSONObject, key: String): String? = if (!args.has(key) || args.isNull(key)) null else text(args, key)
    private fun identifier(value: String): String { require(value.matches(Regex("^[a-zA-Z0-9_.:-]{1,120}$"))) { "Invalid SDK identifier" }; return value }
    private fun assignment(value: JSONObject): AplynaAssignment {
        val variant = text(value, "variant")
        require(variant in listOf("A", "B")) { "Use a valid Aplyna assignment" }
        return AplynaAssignment(variant, optionalText(value, "experimentId")?.let(::identifier), identifier(text(value, "flowId")))
    }
}
