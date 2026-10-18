package com.follow.clashx.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings
import android.util.Base64
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.SavedParams
import com.follow.clashx.core.Core
import com.follow.clashx.core.InvokeInterface
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** The native backend lives for the :remote process, independently of binders. */
object BackendHost {
    @Volatile var active = false
        private set
    private val initialization = Mutex()
    private val requests = ConcurrentHashMap<String, Job>()
    private val application get() = GlobalState.application
    private val validator by lazy { BackendValidatorHost(application) }
    @Volatile var onEvent: ((String) -> Unit)? = null

    suspend fun initialize() = initialization.withLock {
        if (active) return@withLock
        Core.setEventListener(object : InvokeInterface {
            override fun onResult(result: String) {
                val message = runCatching { JSONObject(result).optJSONObject("data") }.getOrNull()
                if (message?.optString("type") == "backendPlatform") {
                    dispatch(message.getJSONObject("data"))
                } else {
                    if (message?.optString("type") == "backend") {
                        projectRuntime(message.getJSONObject("data").getJSONObject("runtime"))
                    }
                    onEvent?.invoke(result)
                }
            }
        })
        val preferences = application.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val legacy = JSONObject(preferences.getString("flutter.config", "{}") ?: "{}")
        preferences.getString("flutter.clash_config", null)?.let {
            legacy.put("patchClashConfig", JSONObject(it))
        }
        installBundledGeo()
        // This privacy preference historically lived outside Config.
        if (preferences.contains("flutter.sendDeviceHeaders")) {
            legacy.put("sendDeviceHeaders", preferences.getBoolean("flutter.sendDeviceHeaders", true))
        }
        val version = application.packageManager.getPackageInfo(application.packageName, 0).versionName ?: ""
        val libraries = application.applicationInfo.nativeLibraryDir
        val executables = JSONObject()
        for (type in listOf("naiveproxy", "olcrtc", "byedpi", "stormdns")) {
            executables.put(type, File(libraries, "libflclashm_$type.so").absolutePath)
        }
        val trustManagers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {
            init(null as java.security.KeyStore?)
        }.trustManagers.filterIsInstance<X509TrustManager>()
        val certificates = JSONArray()
        trustManagers.flatMap { it.acceptedIssuers.toList() }.forEach {
            certificates.put(Base64.encodeToString(it.encoded, Base64.NO_WRAP))
        }
        val zone = TimeZone.getDefault()
        val options = JSONObject()
            .put("home", application.filesDir.absolutePath)
            .put("sdk", Build.VERSION.SDK_INT)
            .put("abi", Build.SUPPORTED_ABIS.first())
            .put("package", application.packageName)
            .put("executables", executables)
            .put("legacy", legacy)
            .put("legacyRunning", SavedParams.isVpnActive())
            .put("timeZone", zone.id)
            .put("utcOffset", zone.getOffset(System.currentTimeMillis()) / 1000)
            .put("userAgent", "FlClash X/v$version core/v1.19.32 Platform/android")
            .put("certificates", certificates)
        invoke("backend.open", options)
        active = true
        BackendOSObserver.install()
        val snapshot = command("snapshot").getJSONObject("result")
        projectRuntime(snapshot.getJSONObject("runtime"))
    }

    suspend fun invoke(method: String, data: Any?): Any? = withTimeout(90_000L) {
        val result = CompletableDeferred<Any?>()
        val action = JSONObject().put("id", UUID.randomUUID().toString()).put("method", method).put("data", data)
        Core.invokeAction(action.toString(), object : InvokeInterface {
            override fun onResult(value: String) {
                runCatching {
                    val envelope = JSONObject(value)
                    check(envelope.optInt("code", -1) == 0) { envelope.optString("data", "backend bridge failed") }
                    envelope.opt("data")
                }.onSuccess { result.complete(it) }.onFailure { result.completeExceptionally(it) }
            }
        })
        result.await()
    }

    suspend fun command(method: String, params: JSONObject = JSONObject()): JSONObject {
        val request = JSONObject().put("apiVersion", 1).put("operationId", UUID.randomUUID().toString())
            .put("method", method).put("params", params)
        return invoke("backend", request) as JSONObject
    }

    private fun dispatch(request: JSONObject) {
        val id = request.getString("id")
        if (request.getString("method") == "request.cancel") {
            requests.remove(id)?.cancel()
            return
        }
        val job = GlobalState.scope.launch(start = CoroutineStart.LAZY) {
            val result = JSONObject().put("id", id)
            try {
                val value: Any? = when (request.getString("method")) {
                    "engine.validate" -> { validator.validate(request.getJSONObject("input").getString("path")); true }
                    "vpn.start" -> { AndroidBackendPlatform.start(id); true }
                    "vpn.stop" -> { AndroidBackendPlatform.stop(); true }
                    "vpn.observe" -> JSONObject().put("state", if (State.runTime != 0L) "running" else "stopped")
                    "vpn.awake" -> { State.tunOwner.get()?.setAwake(request.getJSONObject("input").getBoolean("active")); true }
                    "network.available" -> physicalNetwork() != null
                    "network.dns" -> JSONArray(SystemDnsReader.read())
                    "network.scope" -> networkScope()
                    "packages.list" -> JSONArray(application.packageManager.getInstalledApplications(0).map { it.packageName })
                    "device.headers" -> deviceHeaders()
                    else -> error("unsupported platform mechanism")
                }
                result.put("value", value ?: JSONObject.NULL)
            } catch (error: Throwable) {
                result.put("error", error.message ?: "platform request failed")
            } finally {
                requests.remove(id)
                // Even a cancelled coroutine must release the Go waiter; late
                // results are rejected by its broker after cancellation.
                Core.invokeAction(JSONObject().put("id", "platform-$id")
                    .put("method", "backend.platform.complete").put("data", result).toString(),
                    object : InvokeInterface { override fun onResult(result: String) {} })
            }
        }
        check(requests.putIfAbsent(id, job) == null) { "duplicate platform request" }
        job.start()
    }

    private fun physicalNetwork(): android.net.Network? {
        val manager = application.getSystemService(ConnectivityManager::class.java)
        val candidates = buildList {
            manager.activeNetwork?.let { add(it) }
            manager.allNetworks.forEach { if (!contains(it)) add(it) }
        }.filter { network ->
            val caps = manager.getNetworkCapabilities(network)
            caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        }
        return candidates.firstOrNull {
            manager.getNetworkCapabilities(it)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        } ?: candidates.firstOrNull()
    }

    private fun networkScope(): String =
        com.follow.clashx.common.PhysicalNetworkScope.read(application)

    private fun deviceHeaders(): JSONObject {
        val id = Settings.Secure.getString(application.contentResolver, Settings.Secure.ANDROID_ID)
            ?.takeIf { it.isNotEmpty() } ?: "${Build.BRAND}-${Build.DEVICE}-${Build.HARDWARE}-${Build.ID}"
        return JSONObject().put("x-hwid", id).put("x-device-os", "Android")
            .put("x-ver-os", Build.VERSION.RELEASE).put("x-device-model", "${Build.MANUFACTURER} ${Build.MODEL}")
    }

    private fun projectRuntime(runtime: JSONObject) {
        val observed = runtime.optJSONObject("observed")?.optString("state") ?: "unknown"
        val desired = runtime.optBoolean("desiredRunning")
        val state = when {
            observed == "running" -> StateHub.RUNNING
            desired -> StateHub.STARTING
            observed == "stopped" -> StateHub.STOPPED
            else -> StateHub.STOPPING
        }
        StateHub.publish(state, runtime.optLong("startedAt"))
    }

    private fun installBundledGeo() {
        for (name in listOf("geoip.metadb", "ASN.mmdb", "GeoIP.dat", "GeoSite.dat")) {
            val target = File(application.filesDir, name)
            if (target.exists()) continue
            val temporary = File.createTempFile("geo-", ".tmp", application.filesDir)
            try {
                application.assets.open("flutter_assets/assets/data/$name").use { input ->
                    FileOutputStream(temporary).use { output -> input.copyTo(output); output.fd.sync() }
                }
                check(temporary.renameTo(target)) { "bundled geo installation failed" }
            } finally { temporary.delete() }
        }
    }
}
