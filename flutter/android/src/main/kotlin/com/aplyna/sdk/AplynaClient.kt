package com.aplyna.sdk

import org.json.JSONArray
import org.json.JSONObject
import android.content.Context
import android.content.res.Resources
import android.os.Build
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

data class AplynaAssignment(val variant: String, val experimentId: String?, val flowId: String)
class AplynaHttpException(val status: Int, message: String) : Exception(message)

@Suppress("DEPRECATION")
private fun deviceMetadata(context: Context): Map<String, String> {
    fun locale(resources: Resources): String? {
        val configuration = resources.configuration
        return (if (Build.VERSION.SDK_INT >= 24) configuration.locales.takeUnless { it.isEmpty }?.get(0) else configuration.locale)?.toLanguageTag()
    }
    return buildMap {
        locale(context.resources)?.let { put("app_language", it) }
        locale(Resources.getSystem())?.let { put("device_locale", it) }
        put("os_version", Build.VERSION.RELEASE)
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull()?.let { put("app_version", it) }
        put("sdk_version", "1.0.0")
    }
}

/** Code-first pilot SDK. Call networking methods on an IO/background dispatcher. */
class AplynaClient(
    private val baseUrl: String,
    private val apiKey: String,
    private val installationId: String,
    storageDirectory: File,
    context: Context? = null,
    private val deviceMetadataProvider: () -> Map<String, String>? = { context?.let(::deviceMetadata) }
) {
    private val sessionId = UUID.randomUUID().toString()
    private val directory = File(storageDirectory, "aplyna/" + hash(baseUrl + apiKey + installationId))
    private val queueFile = File(directory, "queue.json")
    @Volatile private var consent = false
    @Volatile private var consentGeneration = 0
    private var flushing = false
    private var queue: JSONArray = runCatching { JSONArray(queueFile.readText()) }.getOrDefault(JSONArray())
    private val attributesFile = File(directory, "customer-attributes.json")
    private var pendingAttributes: JSONObject? = runCatching { JSONObject(attributesFile.readText()) }.getOrNull()
    private var lastObservedDevice: Map<String, String>? = null
    private var appLanguageOverride: String? = null
    init {
        val uri = URI(baseUrl)
        require(uri.scheme == "https" || uri.scheme == "http" && uri.host in listOf("localhost", "127.0.0.1", "10.0.2.2", "::1")) { "HTTPS is required outside local development" }
    }
    @Synchronized fun setConsent(granted: Boolean) {
        consent = granted
        consentGeneration++
        if (!granted) { queue = JSONArray(); pendingAttributes = null; lastObservedDevice = null; persist(); persistAttributes() }
        else refreshDeviceMetadata()
    }
    @Synchronized private fun refreshDeviceMetadata() {
        if (!consent) return
        val device = ((deviceMetadataProvider() ?: emptyMap()) + (appLanguageOverride?.let { mapOf("app_language" to it) } ?: emptyMap())).filterValues { it.isNotBlank() && it.length <= 80 }.takeIf { it.isNotEmpty() } ?: return
        val saved = pendingAttributes?.optJSONObject("device")
        val previous = saved?.keys()?.asSequence()?.associateWith { saved.getString(it) } ?: lastObservedDevice
        lastObservedDevice = device
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val expired = pendingAttributes?.let { runCatching { formatter.parse(it.getString("observed_at"))!!.time < System.currentTimeMillis() - 89L * 86400000 }.getOrDefault(true) } ?: false
        if (device == previous && !expired) return
        pendingAttributes = JSONObject().put("observation_id", "obs_" + UUID.randomUUID()).put("installation_id", installationId).put("platform", "android").put("device", JSONObject(device)).put("observed_at", formatter.format(Date()))
        persistAttributes()
    }
    private fun persistAttributes() {
        pendingAttributes?.let { write(attributesFile, it.toString()) } ?: run { if (attributesFile.exists()) check(attributesFile.delete()) { "Could not clear customer metadata" } }
    }
    @Synchronized fun setAppLanguage(language: String?) {
        require(language == null || language.length <= 80 && language.matches(Regex("^[a-zA-Z]{2,8}([-_][a-zA-Z0-9]{1,8})*$"))) { "Use a language tag" }
        appLanguageOverride = language?.replace('_', '-')
        refreshDeviceMetadata()
    }
    @Synchronized fun pendingEventCount(): Int = queue.length()
    @Synchronized fun track(name: String, flowId: String? = null, stepId: String? = null, assignment: AplynaAssignment? = null, properties: Map<String, String> = emptyMap()) {
        check(consent) { "Explicit consent is required" }
        check(queue.length() < 1000) { "Event queue is full; flush before tracking more" }
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val event = JSONObject().put("event_id", "evt_" + UUID.randomUUID()).put("installation_id", installationId).put("session_id", sessionId).put("name", name).put("occurred_at", formatter.format(Date())).put("properties", JSONObject(properties))
        (flowId ?: assignment?.flowId)?.let { event.put("flow_id", it) }
        stepId?.let { event.put("step_id", it) }
        assignment?.experimentId?.let { event.put("experiment_id", it); event.put("variant", assignment.variant) }
        queue.put(event); persist()
    }
    @Synchronized fun expose(assignment: AplynaAssignment) {
        if (assignment.experimentId != null) track("experiment_exposed", assignment = assignment)
    }
    fun flush() {
        val generation = synchronized(this) {
            check(consent) { "Explicit consent is required" }
            if (flushing) return
            refreshDeviceMetadata()
            flushing = true
            consentGeneration
        }
        try {
            while (true) {
                val (batch, attributes) = synchronized(this) {
                    if (!consent || generation != consentGeneration || queue.length() == 0 && pendingAttributes == null) return
                    Pair(JSONArray().also { batch -> for (i in 0 until minOf(100, queue.length())) batch.put(queue.getJSONObject(i)) }, pendingAttributes?.let { JSONObject(it.toString()) })
                }
                val ids = (0 until batch.length()).map { batch.getJSONObject(it).getString("event_id") }.toSet()
                val payload = JSONObject().put("consent", true).put("events", batch).also { if (attributes != null) it.put("customer_attributes", JSONArray().put(attributes)) }.toString()
                var attempt = 0
                while (true) {
                    if (!consent || generation != consentGeneration) return
                    try { request("api/v1/events", payload); break }
                    catch (error: Exception) {
                        if (error is AplynaHttpException && error.status < 500 && error.status != 429) throw error
                        if (attempt >= 2) throw error
                        attempt++; Thread.sleep(250L * (1L shl attempt))
                    }
                }
                synchronized(this) {
                    if (!consent || generation != consentGeneration) return
                    val remaining = JSONArray()
                    for (i in 0 until queue.length()) {
                        val event = queue.getJSONObject(i)
                        if (event.getString("event_id") !in ids) remaining.put(event)
                    }
                    queue = remaining; persist()
                    if (attributes != null && pendingAttributes?.optString("observation_id") == attributes.getString("observation_id")) { pendingAttributes = null; persistAttributes() }
                }
            }
        } finally { synchronized(this) { flushing = false } }
    }
    @Synchronized fun assignment(flowId: String): AplynaAssignment {
        check(consent) { "Explicit consent is required" }
        val cache = File(directory, "assignment-" + hash(flowId) + ".json")
        val text = try {
            val response = request("api/v1/assignment?flow_id=${encode(flowId)}&installation_id=${encode(installationId)}").second
            write(cache, response); response
        } catch (_: Exception) { if (cache.exists()) cache.readText() else return AplynaAssignment("A", null, flowId) }
        val json = JSONObject(text)
        return AplynaAssignment(json.getString("variant"), if (json.isNull("experiment_id")) null else json.getString("experiment_id"), json.getString("flow_id"))
    }
    @Synchronized fun configuration(flowId: String): JSONObject {
        val cache = File(directory, "config-" + hash(flowId) + ".json")
        val saved = runCatching { JSONObject(cache.readText()) }.getOrNull()
        try {
            val response = request("api/v1/config?flow_id=${encode(flowId)}&schema_version=1", etag = saved?.optString("etag"))
            if (response.first == 304 && saved != null) return saved.getJSONObject("config")
            val config = JSONObject(response.second)
            check(config.getInt("schema_version") == 1 && config.getJSONArray("steps").length() > 0) { "Unsupported configuration" }
            write(cache, JSONObject().put("etag", response.third).put("config", config).toString())
            return config
        } catch (error: Exception) {
            val fallback = saved?.optJSONObject("config")
            if (fallback?.optInt("schema_version") == 1) return fallback
            throw error
        }
    }
    private fun request(path: String, body: String? = null, etag: String? = null): Triple<Int, String, String?> {
        val connection = URI(baseUrl.trimEnd('/') + "/" + path).toURL().openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 10000; connection.readTimeout = 10000; connection.instanceFollowRedirects = false
            connection.setRequestProperty("Authorization", "Bearer $apiKey")
            if (!etag.isNullOrBlank()) connection.setRequestProperty("If-None-Match", etag)
            if (body != null) {
                connection.requestMethod = "POST"; connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            if (status == 304) return Triple(status, "", etag)
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
            if (status !in 200..299) throw AplynaHttpException(status, text)
            return Triple(status, text, connection.getHeaderField("ETag"))
        } finally { connection.disconnect() }
    }
    private fun persist() = write(queueFile, queue.toString())
    private fun write(file: File, text: String) {
        directory.mkdirs()
        val temporary = File(directory, file.name + ".tmp"); temporary.writeText(text)
        check(temporary.renameTo(file)) { "Could not persist SDK data" }
    }
    private fun encode(value: String) = URLEncoder.encode(value, "UTF-8")
    private fun hash(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
}
