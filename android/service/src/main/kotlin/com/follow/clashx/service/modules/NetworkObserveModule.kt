package com.follow.clashx.service.modules

import android.app.Service
import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.follow.clashx.common.GlobalState
import com.follow.clashx.service.Module
import com.google.gson.Gson

class NetworkObserveModule(
    service: Service,
    private val healthCheck: HealthCheckModule? = null,
) : Module(service) {

    companion object {
        private val gson = Gson()
    }

    private var registered = false
    private var currentNetwork: Network? = null
    private var lastCapabilities: NetworkCapabilities? = null
    private var lastActivityTime = 0L
    private var lastDnsJson: String? = null

    private data class DnsSource(
        val network: Network,
        val capabilities: NetworkCapabilities,
        val linkProperties: LinkProperties,
    )

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            super.onAvailable(network)
            val cm = connectivityManager
            val prev = currentNetwork
            val now = android.os.SystemClock.elapsedRealtime()
            val prevActivityTime = lastActivityTime
            val gap = if (prevActivityTime > 0L) now - prevActivityTime else 0L
            lastActivityTime = now
            currentNetwork = network
            updateDnsFromNetwork(cm, network, "available")

            when {
                prev != null && prev != network -> {
                    GlobalState.log("Network changed: $prev -> $network")
                    resetAndCheck("network-change")
                }
                prev == null || prevActivityTime == 0L -> {
                    GlobalState.log("Network restored: $network")
                    resetAndCheck("network-restored")
                }
                gap > 2000L -> {
                    GlobalState.log("Network wake after ${gap}ms idle on $network")
                    resetAndCheck("network-wake")
                }
            }
        }

        override fun onLost(network: Network) {
            super.onLost(network)
            if (currentNetwork == network) {
                GlobalState.log("Network lost: $network")
                currentNetwork = null
                lastCapabilities = null
            }
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            super.onCapabilitiesChanged(network, capabilities)
            lastActivityTime = android.os.SystemClock.elapsedRealtime()
            if (network != currentNetwork) return
            val prev = lastCapabilities
            lastCapabilities = capabilities
            if (prev == null) return
            val hadValidated = prev.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            val hasValidated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            if (!hadValidated && hasValidated) {
                GlobalState.log("Network validated on $network")
                updateDnsFromNetwork(connectivityManager, network, "validated")
                resetAndCheck("validated")
            }
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            super.onLinkPropertiesChanged(network, linkProperties)
            lastActivityTime = android.os.SystemClock.elapsedRealtime()
            if (currentNetwork == null) {
                val capabilities = connectivityManager.getNetworkCapabilities(network)
                if (capabilities != null && isSystemNetwork(capabilities)) {
                    currentNetwork = network
                    lastCapabilities = capabilities
                }
            }
            if (network != currentNetwork) return
            updateDns(network, linkProperties, "link-properties")
        }
    }

    private val connectivityManager: ConnectivityManager
        get() = service.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private fun isSystemNetwork(capabilities: NetworkCapabilities): Boolean {
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
    }

    private fun dnsServers(linkProperties: LinkProperties): List<String> {
        return linkProperties.dnsServers
            .mapNotNull { it.hostAddress }
            .filter { it.isNotBlank() }
            .distinct()
    }

    private fun selectDnsSource(cm: ConnectivityManager): DnsSource? {
        val networks = mutableListOf<Network>()
        cm.activeNetwork?.let { networks.add(it) }
        cm.allNetworks.forEach {
            if (!networks.contains(it)) networks.add(it)
        }

        val candidates = networks.mapNotNull { network ->
            val capabilities = cm.getNetworkCapabilities(network) ?: return@mapNotNull null
            if (!isSystemNetwork(capabilities)) return@mapNotNull null
            val linkProperties = cm.getLinkProperties(network) ?: return@mapNotNull null
            if (dnsServers(linkProperties).isEmpty()) return@mapNotNull null
            DnsSource(network, capabilities, linkProperties)
        }

        return candidates.firstOrNull {
            it.capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        } ?: candidates.firstOrNull()
    }

    private fun updateDnsFromNetwork(
        cm: ConnectivityManager,
        network: Network,
        reason: String,
    ): Boolean {
        val capabilities = cm.getNetworkCapabilities(network) ?: return false
        if (!isSystemNetwork(capabilities)) return false
        val linkProperties = cm.getLinkProperties(network) ?: return false
        return updateDns(network, linkProperties, reason)
    }

    private fun updateDns(
        network: Network,
        linkProperties: LinkProperties,
        reason: String,
    ): Boolean {
        val dns = dnsServers(linkProperties)
        if (dns.isEmpty()) return false

        val dnsJson = gson.toJson(dns)
        if (dnsJson == lastDnsJson) return true

        return runCatching {
            com.follow.clashx.core.Core.updateDns(dnsJson)
        }.onSuccess {
            lastDnsJson = dnsJson
            GlobalState.log("System DNS updated from $network ($reason)")
        }.onFailure {
            GlobalState.log("updateDns failed: ${it.message}")
        }.isSuccess
    }

    private fun seedDns(cm: ConnectivityManager) {
        val source = selectDnsSource(cm)
        if (source == null) {
            GlobalState.log("No non-VPN DNS available for initial update")
            return
        }
        currentNetwork = source.network
        lastCapabilities = source.capabilities
        updateDns(source.network, source.linkProperties, "initial")
    }

    private fun resetAndCheck(reason: String) {
        runCatching { com.follow.clashx.core.Core.resetConnections() }
            .onFailure { GlobalState.log("resetConnections failed: ${it.message}") }
        healthCheck?.scheduleCheck(reason)
    }

    override suspend fun install() {
        val cm = service.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        runCatching {
            cm.registerNetworkCallback(request, callback)
            registered = true
            seedDns(cm)
        }.onFailure { GlobalState.log("registerNetworkCallback failed: ${it.message}") }
    }

    override suspend fun uninstall() {
        if (!registered) return
        val cm = service.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        runCatching { cm.unregisterNetworkCallback(callback) }
        registered = false
    }
}
