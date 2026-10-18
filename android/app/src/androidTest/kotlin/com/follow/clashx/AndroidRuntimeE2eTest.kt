package com.follow.clashx

import android.content.Context
import android.net.VpnService
import android.os.Process
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

/** Production Go API, actual validator process, native transport and VPN/TUN.
 * All input is local; public DNS/HTTP endpoints are explicitly disabled. */
@RunWith(AndroidJUnit4::class)
class AndroidRuntimeE2eTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val fixtureState get() = context.getSharedPreferences("backend-e2e", Context.MODE_PRIVATE)
    private suspend fun snapshot() = Service.backend("snapshot").getJSONObject("runtime")
    private suspend fun await(label: String, condition: suspend () -> Boolean) = withTimeout(90_000L) {
        while (!condition()) delay(150)
    }
    private fun canConnect(port: Int): Boolean = runCatching {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 500) }; true
    }.getOrDefault(false)
    private suspend fun upload(source: String): String {
        val token = Service.backend("blob.create").getString("token")
        val bytes = source.toByteArray(Charsets.UTF_8)
        var offset = 0
        while (offset < bytes.size) {
            val size = minOf(192 * 1024, bytes.size - offset)
            Service.backend("blob.append", JSONObject().put("token", token).put("offset", offset)
                .put("data", Base64.encodeToString(bytes, offset, size, Base64.NO_WRAP)))
            offset += size
        }
        return token
    }
    private suspend fun importProfile(id: String, source: String, select: Boolean = true) {
        val token = upload(source)
        try {
            Service.backendCommand("profile.import.file", JSONObject().put("token", token)
                .put("metadata", JSONObject().put("id", id).put("label", "Local fixture"))
                .put("select", select))
        } finally { Service.backend("blob.delete", JSONObject().put("token", token)) }
    }
    private val source = """
        mixed-port: 17890
        ipv6: false
        dns: {enable: false}
        proxies:
          - {name: LocalBye, type: byedpi, mode: manual, strategy: '-d1 -s2'}
        proxy-groups:
          - {name: Select, type: select, proxies: [LocalBye, DIRECT]}
        rules: ['MATCH,DIRECT']
    """.trimIndent()

    @Test fun packagedBackendLifecycle() = runBlocking {
        assertTrue("x86_64 emulator required", android.os.Build.SUPPORTED_ABIS.contains("x86_64"))
        assertNull("CI must grant ACTIVATE_VPN", VpnService.prepare(context))
        for (type in listOf("naiveproxy", "olcrtc", "byedpi", "stormdns")) {
            val file = File(context.applicationInfo.nativeLibraryDir, "libflclashm_$type.so")
            assertTrue("Missing packaged $type", file.isFile)
            val magic = file.inputStream().use { input -> ByteArray(4).also { input.read(it) } }
            assertArrayEquals(byteArrayOf(0x7f, 0x45, 0x4c, 0x46), magic)
        }
        Service.bind()
        val scenario = InstrumentationRegistry.getArguments().getString("scenario", "lifecycle")
        if (scenario == "observe" || scenario == "recovered") {
            await("headless VPN") { snapshot().getJSONObject("observed").optString("state") == "running" }
            val runtime = snapshot()
            if (scenario == "observe") assertEquals(fixtureState.getLong("startedAt", -1), runtime.getLong("startedAt"))
            assertTrue(canConnect(fixtureState.getInt("port", 0)))
            assertTrue(Service.backend("presentation").optString("notificationTitle").contains("Local fixture"))
            // A native widget action works without Flutter initialization.
            Service.backendCommand("settings.patch", JSONObject().put("patch", JSONObject().put("patchClashConfig", JSONObject().put("mode", "direct"))))
            assertEquals("direct", Service.backend("presentation").getString("mode"))
            if (scenario == "recovered") {
                Service.backendCommand("runtime.stop")
                assertFalse(snapshot().getBoolean("desiredRunning"))
                await("native listener stopped") { !canConnect(fixtureState.getInt("port", 0)) }
            }
            Service.unbind()
            return@runBlocking
        }
        Service.backendCommand("data.reset")
        Service.backendCommand("settings.patch", JSONObject().put("patch", JSONObject()
            .put("appSetting", JSONObject().put("testUrl", "").put("overrideNetworkSettings", true))
            .put("patchClashConfig", JSONObject().put("mixed-port", 17890).put("ipv6", false))
            .put("vpnProps", JSONObject().put("enable", true).put("ipv6", false))))
        // Original source is larger than Binder's transaction limit. Chunking is
        // exercised both on import and on profile.get, with byte-for-byte checks.
        val largeSource = source + "\n#" + "a".repeat(1100 * 1024) + "\n"
        importProfile("fixture", largeSource)
        val record = Service.backend("profile.get", JSONObject().put("profileId", "fixture"))
        assertEquals(largeSource, record.getString("source"))
        Service.backendCommand("runtime.start")
        val runtime = snapshot()
        assertEquals("running", runtime.getJSONObject("observed").getString("state"))
        val view = Service.backend("runtime.view")
        val node = view.getJSONArray("nodes").getJSONObject(0)
        val port = node.getInt("port")
        assertTrue("Packaged external transport did not listen", canConnect(port))
        assertTrue(Service.getAppliedAndroidVpnOptions().isNotEmpty())
        assertTrue("Remote process not found", remotePid() > 0)
        assertNotEquals("Remote must outlive the UI PID", Process.myPid(), remotePid())
        fixtureState.edit().putLong("startedAt", runtime.getLong("startedAt")).putInt("port", port).commit()
        if (scenario == "seed") { Service.unbind(); return@runBlocking }
        try {
            // No source/model supplied on recovery; the committed Go input is used.
            Service.unbind()
            delay(500)
            Service.bind()
            Service.backendCommand("runtime.recover")
            assertEquals("running", snapshot().getJSONObject("observed").getString("state"))
            // Invalid edits fail without replacing either original source or VPN.
            val token = upload("proxies: [unterminated")
            try {
                assertTrue(runCatching { Service.backendCommand("profile.import.file", JSONObject().put("token", token)
                    .put("metadata", JSONObject().put("id", "fixture")).put("expectedRevision", record.getLong("revision"))) }.isFailure)
                assertEquals(largeSource, Service.backend("profile.get", JSONObject().put("profileId", "fixture")).getString("source"))
                assertEquals("running", snapshot().getJSONObject("observed").getString("state"))
            } finally { Service.backend("blob.delete", JSONObject().put("token", token)) }
            val generation = snapshot().getLong("appliedGeneration")
            Service.backendCommand("settings.patch", JSONObject().put("patch", JSONObject().put("patchClashConfig", JSONObject().put("mode", "direct"))))
            assertEquals("direct", Service.backend("runtime.view").getJSONObject("config").getString("mode"))
            assertTrue(snapshot().getLong("appliedGeneration") > generation)
        } finally {
            Service.backendCommand("runtime.stop")
            Service.backendCommand("runtime.recover")
            assertFalse(snapshot().getBoolean("desiredRunning"))
            assertEquals("stopped", snapshot().getJSONObject("observed").getString("state"))
            await("transport shutdown") { !canConnect(port) }
            Service.unbind()
        }
        // Proxy-only execution uses the same coordinator and survives without
        // a TUN or a VPN-consent decision in Flutter/Kotlin.
        Service.bind()
        try {
            Service.backendCommand("settings.patch", JSONObject().put("patch", JSONObject().put("vpnProps", JSONObject().put("enable", false))))
            assertFalse(Service.backend("presentation").getBoolean("requiresVpn"))
            Service.backendCommand("runtime.start")
            assertEquals("running", snapshot().getJSONObject("observed").getString("state"))
            assertFalse(JSONObject(Service.getAndroidVpnOptions()).getBoolean("enable"))
        } finally { Service.backendCommand("runtime.stop"); Service.unbind() }
    }
    private fun remotePid(): Int {
        val manager = context.getSystemService(android.app.ActivityManager::class.java)
        return manager.runningAppProcesses.firstOrNull { it.processName == context.packageName + ":remote" }?.pid ?: -1
    }
}
