package com.follow.clashx.plugins

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import java.security.MessageDigest

internal object PhysicalNetworkScope {
    fun read(context: Context): String {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val ordered = buildList {
            manager.activeNetwork?.let(::add)
            manager.allNetworks.forEach { if (!contains(it)) add(it) }
        }
        val candidates = ordered.mapNotNull { network ->
            val capabilities = manager.getNetworkCapabilities(network) ?: return@mapNotNull null
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            ) return@mapNotNull null
            val links = manager.getLinkProperties(network) ?: return@mapNotNull null
            capabilities to links
        }
        val selected = candidates.firstOrNull {
            it.first.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        } ?: candidates.firstOrNull() ?: return "network-offline"
        return fingerprint(selected.first, selected.second)
    }

    private fun fingerprint(
        capabilities: NetworkCapabilities,
        links: LinkProperties,
    ): String {
        val transports = buildList {
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) add("wifi")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) add("cellular")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) add("ethernet")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) add("bluetooth")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_USB)) add("usb")
        }.ifEmpty { listOf("other") }
        val dns = links.dnsServers.mapNotNull { it.hostAddress }.sorted()
        val routes = links.routes
            .filter { it.isDefaultRoute }
            .map { route ->
                listOfNotNull(
                    route.gateway?.hostAddress,
                    links.interfaceName,
                ).joinToString("@")
            }
            .sorted()
        val material = listOf(
            transports.sorted().joinToString(","),
            dns.joinToString(","),
            routes.joinToString(","),
        ).joinToString("|")
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(material.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "network-${digest.take(24)}"
    }
}
