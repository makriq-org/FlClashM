package com.follow.clashx.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.PowerManager
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.PhysicalNetworkScope
import com.follow.clashx.common.registerReceiverCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Process-lifetime OS observations; no retry, health, sleep or recovery policy. */
internal object BackendOSObserver {
    private val installed = AtomicBoolean()
    private val sequence = AtomicLong()
    private val context get() = GlobalState.application
    private val connectivity get() = context.getSystemService(ConnectivityManager::class.java)

    fun install() {
        if (!installed.compareAndSet(false, true)) return
        connectivity.registerNetworkCallback(NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), networkCallback)
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            if (Build.VERSION.SDK_INT >= 33) addAction(PowerManager.ACTION_DEVICE_LIGHT_IDLE_MODE_CHANGED)
        }
        context.registerReceiverCompat(screenReceiver, filter)
        publishNetwork()
        screen()
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = publishNetwork()
        override fun onLost(network: Network) = publishNetwork()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = publishNetwork()
        override fun onLinkPropertiesChanged(network: Network, links: LinkProperties) = publishNetwork()
    }
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = screen()
    }

    private fun publishNetwork() {
        val networks = connectivity.allNetworks.mapNotNull { connectivity.getNetworkCapabilities(it) }
            .filter { it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) }
        emit(JSONObject().put("kind", "network").put("seq", sequence.incrementAndGet())
            .put("available", networks.isNotEmpty())
            .put("validated", networks.any { it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) })
            .put("dns", JSONArray(SystemDnsReader.read()))
            .put("scope", PhysicalNetworkScope.read(context)))
    }
    private fun screen() {
        val power = context.getSystemService(PowerManager::class.java)
        val dozing = power.isDeviceIdleMode || (Build.VERSION.SDK_INT >= 33 && power.isDeviceLightIdleMode)
        emit(JSONObject().put("kind", "screen").put("seq", sequence.incrementAndGet())
            .put("screenOn", power.isInteractive).put("dozing", dozing))
    }
    fun service(kind: String) {
        emit(JSONObject().put("kind", kind).put("seq", sequence.incrementAndGet()))
    }
    private fun emit(event: JSONObject) {
        GlobalState.launch {
            runCatching { BackendHost.invoke("backend.host.event", event) }
                .onFailure { GlobalState.log("backend OS observation failed: ${it.message}") }
        }
    }
}
