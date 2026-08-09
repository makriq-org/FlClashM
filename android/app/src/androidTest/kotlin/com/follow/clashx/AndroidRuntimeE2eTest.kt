package com.follow.clashx

import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.common.SavedParams
import com.follow.clashx.service.models.VpnOptions
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * One vertical Android smoke test for CI. It deliberately uses production IPC,
 * service, core and runtime-process code; the only test-specific input is a
 * local DIRECT profile, so the result never depends on the public network.
 *
 * The workflow grants ACTIVATE_VPN before instrumentation starts. Android has
 * no supported API for accepting VPN consent headlessly, so a non-null
 * VpnService.prepare result is treated as a CI setup failure instead of adding
 * brittle UI automation here.
 */
@RunWith(AndroidJUnit4::class)
class AndroidRuntimeE2eTest {
    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Before
    fun setUp() = runBlocking {
        SavedParams.clearQuickStartParams()
        Service.bind()
        await("remote service bind") { Service.fetchServiceState() != null }
    }

    @After
    fun tearDown() = runBlocking {
        runCatching { Service.stopService() }
        runCatching { Service.stopRuntimeNodePlan() }
        SavedParams.clearQuickStartParams()
        Service.unbind()
    }

    @Test
    fun packagedRuntimeVpnAndHeadlessRecoveryLifecycle() = runBlocking {
        assertEquals("The emulator must execute the x86_64 runtime", "x86_64", primaryAbi())
        val nativeDir = File(context.applicationInfo.nativeLibraryDir)
        val runtimeLibraries = listOf(
            "libflclashm_naiveproxy.so",
            "libflclashm_olcrtc.so",
            "libflclashm_byedpi.so",
            "libflclashm_stormdns.so",
        ).associateWith { File(nativeDir, it) }
        runtimeLibraries.forEach { (name, file) -> assertElfExecutable(name, file) }

        // A representative local node goes through the real AIDL bridge and
        // RuntimeNodeProcessManager. Checking every CLI here would duplicate the
        // same Android process contract while making this job much slower.
        val runtimePort = 17891
        val runtimePlan = runtimePlan(
            executable = runtimeLibraries.getValue("libflclashm_byedpi.so"),
            port = runtimePort,
        )
        val runtimeState = Service.applyRuntimeNodePlan(runtimePlan)
        assertEquals("ready", JSONObject(runtimeState).getString("status"))
        Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", runtimePort), 1_000)
        }
        Service.stopRuntimeNodePlan()
        await("runtime listener cleanup") { !canConnect(runtimePort) }

        assertNull(
            "GitHub Actions must grant ACTIVATE_VPN before instrumentation",
            VpnService.prepare(context),
        )
        SavedParams.saveRuntimeNodesState("{\"nodes\":[]}")

        val quickStartError = quickStartCore()
        assertTrue("mihomo quickStart failed: $quickStartError", quickStartError.isEmpty())

        val coreOptions = Service.getAndroidVpnOptions()
        assertTrue("mihomo returned no Android VPN options", coreOptions.isNotBlank())
        val parsedOptions = JSONObject(coreOptions)
        assertTrue("mihomo disabled Android VPN", parsedOptions.getBoolean("enable"))
        assertEquals("unexpected mixed port", 17890, parsedOptions.getInt("port"))
        assertEquals(
            "unexpected IPv4 address",
            "172.19.0.1/30",
            parsedOptions.getString("ipv4Address"),
        )
        assertEquals("IPv6 must stay disabled", "", parsedOptions.getString("ipv6Address"))
        assertEquals(
            "unexpected in-tunnel DNS address",
            "172.19.0.2",
            parsedOptions.getString("dnsServerAddress"),
        )
        assertTrue("allowBypass unexpectedly enabled", !parsedOptions.getBoolean("allowBypass"))
        assertTrue("system proxy unexpectedly enabled", !parsedOptions.getBoolean("systemProxy"))
        val options = VpnOptions(
            enable = parsedOptions.getBoolean("enable"),
            port = parsedOptions.getInt("port"),
            socksPort = 17891,
            ipv4Address = parsedOptions.getString("ipv4Address"),
            ipv6Address = parsedOptions.getString("ipv6Address"),
            dnsServerAddress = parsedOptions.getString("dnsServerAddress"),
            routeAddress = parsedOptions.optJSONArray("routeAddress").strings(),
            allowBypass = parsedOptions.getBoolean("allowBypass"),
            systemProxy = parsedOptions.getBoolean("systemProxy"),
            bypassDomain = parsedOptions.optJSONArray("bypassDomain").strings(),
            ipv4 = true,
            ipv6 = false,
        )
        val startedAt = Service.startService(options, 0L)
        assertTrue("VPN foreground service did not start", startedAt > 0L)
        await("running VPN state") { Service.fetchServiceState()?.isRunning == true }
        await("VPN transport") { hasVpnTransport() }
        assertNotNull("foreground notification is missing", foregroundNotification())

        val oldRemotePid = remotePid()
        assertTrue("remote process was not found", oldRemotePid > 0)
        Process.killProcess(oldRemotePid)

        await("remote process replacement", timeoutMillis = 45_000L) {
            remotePid().let { it > 0 && it != oldRemotePid }
        }
        // FlVpnService and RemoteService share :remote. Killing that process tears
        // down the TUN and core; Android rebinds RemoteService, while the supported
        // headless recovery contract reissues quickStart/startService through AIDL.
        await("remote service rebind", timeoutMillis = 45_000L) {
            Service.fetchServiceState() != null
        }
        val coldStartError = quickStartCore()
        assertTrue("mihomo headless recovery failed: $coldStartError", coldStartError.isEmpty())
        assertTrue("VPN recovery command was rejected", Service.startService(options, 0L) > 0L)
        await("headless VPN recovery", timeoutMillis = 45_000L) {
            Service.fetchServiceState()?.isRunning == true
        }
        await("VPN transport after headless recovery", timeoutMillis = 20_000L) { hasVpnTransport() }
        assertNotNull("foreground notification was not restored", foregroundNotification())

        Service.stopService()
        await("VPN stop") { Service.fetchServiceState()?.state == "stopped" }
        await("VPN transport cleanup") { !hasVpnTransport() }
        await("foreground notification cleanup") { foregroundNotification() == null }
        assertTrue("VPN active marker was not cleared", !SavedParams.isVpnActive())
        assertNotEquals("remote process unexpectedly disappeared on normal stop", 0, remotePid())
    }

    private suspend fun quickStartCore(): String {
        val home = File(context.filesDir, "android-e2e-core").apply { mkdirs() }
        val init = JSONObject()
            .put("home-dir", home.absolutePath)
            .put("version", 1)
            .toString()
        val config = JSONObject()
            .put("mixed-port", 17890)
            .put("allow-lan", false)
            .put("mode", "direct")
            .put("log-level", "info")
            .put("ipv6", false)
            .put("external-controller", "")
            .put("proxies", JSONArray())
            .put("proxy-groups", JSONArray())
            .put("rules", JSONArray().put("MATCH,DIRECT"))
            .put("dns", JSONObject().put("enable", false))
            .put(
                "tun",
                JSONObject()
                    .put("enable", true)
                    .put("device", "FlClashM-E2E")
                    .put("stack", "system")
                    .put("auto-route", false)
                    .put("dns-hijack", JSONArray().put("any:53")),
            )
        val setup = JSONObject()
            .put("config", config)
            .put("selected-map", JSONObject())
            .put("test-url", "http://example.invalid")
            .toString()
        val state = JSONObject()
            .put(
                "vpn-props",
                JSONObject()
                    .put("enable", true)
                    .put("systemProxy", false)
                    .put("ipv6", false)
                    .put("allowBypass", false)
                    .put("accessControl", JSONObject().put("enable", false)),
            )
            .put("only-statistics-proxy", false)
            .put("current-profile-name", "Android E2E")
            .put("bypass-domain", JSONArray())
            .toString()

        val result = CompletableDeferred<String>()
        val registration = Service.quickStart(init, setup, state, null) { result.complete(it) }
        registration.getOrThrow()
        return withTimeout(20_000L) { result.await() }
    }

    private fun runtimePlan(executable: File, port: Int): String = JSONObject()
        .put(
            "nodes",
            JSONArray().put(
                JSONObject()
                    .put("nodeId", "android-e2e-byedpi")
                    .put("type", "byedpi")
                    .put("name", "Android E2E ByeDPI")
                    .put("host", "127.0.0.1")
                    .put("port", port)
                    .put("executablePath", executable.absolutePath)
                    .put(
                        "workingDirectory",
                        File(context.cacheDir, "android-e2e-byedpi").absolutePath,
                    )
                    .put(
                        "arguments",
                        JSONArray(
                            listOf(
                                "--ip",
                                "127.0.0.1",
                                "--port",
                                "$port",
                                "--disorder",
                                "1",
                            ),
                        ),
                    )
                    .put("revision", "android-e2e-v1")
                    .put(
                        "connectivityCheck",
                        JSONObject()
                            .put("urls", JSONArray())
                            .put("required", false)
                            .put("startup-timeout", 10)
                            .put("resolver", "system"),
                    )
                    .put("startupFailurePatterns", JSONArray()),
            ),
        )
        .toString()

    private fun assertElfExecutable(name: String, file: File) {
        assertTrue("$name is missing from nativeLibraryDir", file.isFile)
        assertTrue("$name is not executable", file.canExecute())
        val magic = file.inputStream().use { input -> ByteArray(4).also { input.read(it) } }
        assertTrue(
            "$name is not an ELF binary",
            magic.contentEquals(byteArrayOf(0x7f, 0x45, 0x4c, 0x46)),
        )
    }

    private fun primaryAbi(): String = android.os.Build.SUPPORTED_ABIS.firstOrNull().orEmpty()

    private fun remotePid(): Int {
        val activityManager = context.getSystemService(ActivityManager::class.java)
        val processName = "${context.packageName}:remote"
        return activityManager.runningAppProcesses
            ?.firstOrNull { it.processName == processName }
            ?.pid ?: 0
    }

    private fun hasVpnTransport(): Boolean = vpnNetworkHandle() != null

    @Suppress("DEPRECATION")
    private fun vpnNetworkHandle(): Long? {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        return connectivity.allNetworks.firstOrNull { network ->
            connectivity.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }?.networkHandle
    }

    private fun foregroundNotification() =
        context.getSystemService(NotificationManager::class.java)
            .activeNotifications
            .firstOrNull { it.id == CommonGlobalState.NOTIFICATION_ID }

    private fun canConnect(port: Int): Boolean = runCatching {
        Socket().use { socket -> socket.connect(InetSocketAddress("127.0.0.1", port), 200) }
    }.isSuccess

    private suspend fun await(
        description: String,
        timeoutMillis: Long = 20_000L,
        condition: suspend () -> Boolean,
    ) {
        val deadline = android.os.SystemClock.elapsedRealtime() + timeoutMillis
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            if (runCatching { condition() }.getOrDefault(false)) return
            delay(100L)
        }
        assertTrue("Timed out waiting for $description", false)
    }

    private fun JSONArray?.strings(): List<String> = buildList {
        val source = this@strings ?: return@buildList
        for (index in 0 until source.length()) add(source.getString(index))
    }
}
