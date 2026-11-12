package com.aplyna.sdk

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AplynaTests {
    @Test fun consentedDeviceMetadataIsDurableAndDoesNotInventATTOrEvents() {
        val directory = Files.createTempDirectory("aplyna-kotlin-metadata-").toFile()
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(401)); server.enqueue(MockResponse().setResponseCode(202)); server.enqueue(MockResponse().setResponseCode(202)); server.start()
        try {
            val provider = { mapOf("app_language" to "en", "device_locale" to "en-GB", "os_version" to "16") }
            val client = AplynaClient(server.url("/").toString(), "test", "metadata_customer", directory, deviceMetadataProvider = provider)
            client.setAppLanguage("fr"); assertEquals(0, server.requestCount)
            client.setConsent(true)
            assertThrows(AplynaHttpException::class.java) { client.flush() }
            val first = server.takeRequest().body.readUtf8()
            val restored = AplynaClient(server.url("/").toString(), "test", "metadata_customer", directory, deviceMetadataProvider = provider)
            restored.setAppLanguage("fr"); restored.setConsent(true); restored.flush()
            val second = server.takeRequest().body.readUtf8()
            assertEquals(first, second)
            val body = JSONObject(second)
            assertEquals(0, body.getJSONArray("events").length())
            val attributes = body.getJSONArray("customer_attributes").getJSONObject(0)
            assertFalse(attributes.has("att_consent")); assertEquals("android", attributes.getString("platform"))
            assertEquals("fr", attributes.getJSONObject("device").getString("app_language"))
            assertEquals("en-GB", attributes.getJSONObject("device").getString("device_locale"))
            restored.flush(); assertEquals(2,server.requestCount)
            restored.setAppLanguage("de"); restored.flush(); assertEquals(3,server.requestCount)
            restored.setConsent(false); restored.setAppLanguage("es"); assertEquals(3,server.requestCount)
        } finally { server.shutdown(); directory.deleteRecursively() }
    }
    @Test fun identityConsentAndDurableQueue() {
        val directory = Files.createTempDirectory("aplyna-kotlin-").toFile()
        try {
            val options = """{"baseUrl":"https://example.test","apiKey":"test"}"""
            val first = AplynaBridge(directory)
            val identity = first.invoke("configure", options)
            assertEquals("null", first.invoke("refreshTrackingAuthorizationStatus", "{}"))
            assertEquals("0", first.invoke("pendingEventCount", "{}"))
            assertThrows(IllegalStateException::class.java) { first.invoke("track", """{"name":"app_opened"}""") }
            first.invoke("setConsent", """{"granted":true}""")
            first.invoke("track", """{"name":"app_opened","properties":{"screen":"welcome"}}""")
            val restored = AplynaBridge(directory)
            assertEquals(identity, restored.invoke("configure", options))
            assertEquals("1", restored.invoke("pendingEventCount", "{}"))
            assertThrows(IllegalArgumentException::class.java) { restored.invoke("setConsent", """{"granted":1}""") }
            assertThrows(IllegalArgumentException::class.java) { restored.invoke("track", """{"name":"Invalid Event"}""") }
            assertThrows(IllegalArgumentException::class.java) { restored.invoke("track", """{"name":"app_opened","properties":{"bad":1}}""") }
            assertThrows(IllegalArgumentException::class.java) { restored.invoke("configure", """{"baseUrl":"http://example.test","apiKey":"test"}""") }
            restored.invoke("setConsent", """{"granted":false}""")
            assertEquals("0", restored.invoke("pendingEventCount", "{}"))
        } finally { directory.deleteRecursively() }
    }
    @Test fun networkRetryPreservesIdsAndAssignmentDoesNotExpose() {
        val directory = Files.createTempDirectory("aplyna-kotlin-http-").toFile()
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody("""{"flow_id":"flow_1","experiment_id":"exp_1","variant":"B"}"""))
        server.enqueue(MockResponse().setResponseCode(500).setBody("{}"))
        server.enqueue(MockResponse().setResponseCode(202).setBody("{}"))
        server.start()
        try {
            val bridge = AplynaBridge(directory)
            bridge.invoke("configure", """{"baseUrl":"${server.url("/")}","apiKey":"test","installationId":"customer_1"}""")
            bridge.invoke("setConsent", """{"granted":true}""")
            val assignment = bridge.invoke("assignment", """{"flowId":"flow_1"}""")
            assertEquals("0", bridge.invoke("pendingEventCount", "{}"))
            bridge.invoke("expose", """{"assignment":$assignment}""")
            bridge.invoke("flush", "{}")
            assertEquals(3, server.requestCount)
            val assignmentRequest = server.takeRequest()
            assertEquals("Bearer test", assignmentRequest.getHeader("Authorization"))
            val firstBody = server.takeRequest().body.readUtf8()
            val secondBody = server.takeRequest().body.readUtf8()
            assertEquals(firstBody, secondBody)
            assertEquals("customer_1", JSONObject(firstBody).getJSONArray("events").getJSONObject(0).getString("installation_id"))
            assertEquals("0", bridge.invoke("pendingEventCount", "{}"))
        } finally { server.shutdown(); directory.deleteRecursively() }
    }
    @Test fun rejectedDeliveryRetainsQueue() {
        val directory = Files.createTempDirectory("aplyna-kotlin-rejected-").toFile()
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(401))
        server.start()
        try {
            val bridge = AplynaBridge(directory)
            bridge.invoke("configure", """{"baseUrl":"${server.url("/")}","apiKey":"test"}""")
            bridge.invoke("setConsent", """{"granted":true}""")
            bridge.invoke("track", """{"name":"app_opened"}""")
            assertThrows(AplynaHttpException::class.java) { bridge.invoke("flush", "{}") }
            assertEquals("1", bridge.invoke("pendingEventCount", "{}"))
        } finally { server.shutdown(); directory.deleteRecursively() }
    }
}
