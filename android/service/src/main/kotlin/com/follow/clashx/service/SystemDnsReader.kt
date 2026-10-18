package com.follow.clashx.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.follow.clashx.common.GlobalState

object SystemDnsReader {
    const val MAX_SYSTEM_DNS_SERVERS = 16

    /** Physical OS DNS addresses only; rendering and restart policy live in Go. */
    fun sanitize(servers: List<String>): List<String> = servers
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.contains('%') }
        .distinct()
        .take(MAX_SYSTEM_DNS_SERVERS)

    fun read(): List<String> = runCatching {
        val manager = GlobalState.application
            .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val networks = buildList {
            manager.activeNetwork?.let { add(it) }
            manager.allNetworks.forEach { if (!contains(it)) add(it) }
        }
        val candidates = networks.mapNotNull { network ->
            val capabilities = manager.getNetworkCapabilities(network) ?: return@mapNotNull null
            // The VPN's own resolvers would loop traffic back into the tunnel.
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                return@mapNotNull null
            }
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) {
                return@mapNotNull null
            }
            val linkProperties = manager.getLinkProperties(network) ?: return@mapNotNull null
            val servers = sanitize(linkProperties.dnsServers.mapNotNull { it.hostAddress })
            if (servers.isEmpty()) {
                null
            } else {
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) to servers
            }
        }
        (candidates.firstOrNull { it.first } ?: candidates.firstOrNull())?.second.orEmpty()
    }.getOrElse { emptyList() }
}
