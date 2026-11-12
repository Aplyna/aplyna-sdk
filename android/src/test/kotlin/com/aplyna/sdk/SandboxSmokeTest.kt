package com.aplyna.sdk

import java.net.URI
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class SandboxSmokeTest {
    @Test fun localTestStoreEventsReachTheDashboard() {
        val base = System.getenv("APLYNA_SDK_SMOKE_URL")
        val key = System.getenv("APLYNA_SDK_SMOKE_KEY")
        assumeTrue("An explicit local sandbox is required", base != null && key != null)
        val url = requireNotNull(base)
        val token = requireNotNull(key)
        require(URI(url).host in listOf("localhost", "127.0.0.1", "::1") && token.startsWith("aplyna_test_"))
        val directory = Files.createTempDirectory("aplyna-kotlin-sandbox").toFile()
        try {
            val client = AplynaClient(url, token, "sdk_kotlin_sandbox", directory)
            try { client.track("app_opened"); fail("Consent must be required") } catch (_: IllegalStateException) { }
            client.setConsent(true)
            for (name in listOf("app_opened", "onboarding_completed", "trial_started"))
                client.track(name, properties = mapOf("verification" to "local_sdk_test", "runtime" to "kotlin"))
            client.flush()
            assertEquals(0, client.pendingEventCount())
        } finally { directory.deleteRecursively() }
    }
}
