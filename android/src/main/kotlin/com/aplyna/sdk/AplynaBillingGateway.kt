package com.aplyna.sdk

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI

internal class BillingGateway(private val base: String, private val sdkKey: String) {
    init {
        val uri = URI(base)
        require(uri.host != null && uri.userInfo == null && uri.query == null && uri.fragment == null &&
            (uri.scheme == "https" || uri.scheme == "http" && uri.host in listOf("localhost", "127.0.0.1", "10.0.2.2", "::1"))) { "Use an HTTPS billing gateway, or HTTP on a local development host." }
        require(sdkKey.startsWith("aplyna_android_") && sdkKey.length <= 500) { "Use this Google Play app's Android SDK key." }
    }
    /** Offerings live beside the billing gateway: https://host/api/billing -> https://host/api/v1/offerings. */
    fun offerings(projectId: String?): JSONObject {
        val root = base.trimEnd('/').substringBeforeLast('/')
        val query = projectId?.takeIf { it.isNotBlank() }?.let { "?project_id=" + java.net.URLEncoder.encode(it, "UTF-8") }.orEmpty()
        return call("$root/v1/offerings$query", null, null)
    }
    fun request(path: String, identity: JSONObject? = null, body: JSONObject? = null): JSONObject = call(base.trimEnd('/') + "/" + path, identity, body)
    private fun call(url: String, identity: JSONObject?, body: JSONObject?): JSONObject {
        // Transport failures get a stable code instead of a raw IOException.
        val connection = try { URI(url).toURL().openConnection() as HttpURLConnection } catch (error: java.io.IOException) { throw network(error) }
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20_000; connection.readTimeout = 55_000
            connection.requestMethod = if (body == null) "GET" else "POST"
            connection.setRequestProperty("Authorization", "Bearer $sdkKey")
            connection.setRequestProperty("Content-Type", "application/json")
            identity?.let { connection.setRequestProperty("X-Aplyna-Customer-Token", it.getString("customerToken")) }
            if (body != null) { connection.doOutput = true; connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) } }
            val status = connection.responseCode
            val input = if (status in 200..299) connection.inputStream else connection.errorStream
            val bytes = input?.use { stream ->
                val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
                while (true) { val count = stream.read(buffer); if (count < 0) break; if (output.size() + count > 1_048_576) throw AplynaBillingException("APLYNA_BILLING_RESPONSE", "Billing response exceeds the supported size."); output.write(buffer, 0, count) }
                output.toByteArray()
            } ?: byteArrayOf()
            val response = try { JSONObject(String(bytes, Charsets.UTF_8)) } catch (_: Exception) { null }
            if (status !in 200..299) throw AplynaBillingException("APLYNA_HTTP_$status", response?.optString("error")?.takeIf { it.isNotBlank() } ?: "The billing gateway rejected this request.")
            return response ?: throw AplynaBillingException("APLYNA_BILLING_RESPONSE", "The billing gateway returned an invalid response.")
        } catch (error: java.io.IOException) { throw network(error)
        } finally { connection.disconnect() }
    }
    private fun network(error: java.io.IOException): AplynaBillingException {
        val offline = error is java.net.UnknownHostException || error is java.net.ConnectException || error is java.net.NoRouteToHostException
        return AplynaBillingException(if (offline) "APLYNA_BILLING_OFFLINE" else "APLYNA_BILLING_NETWORK",
            if (offline) "The device is offline. Check the connection and try again." else "The billing service could not be reached. Try again.", error)
    }
}
