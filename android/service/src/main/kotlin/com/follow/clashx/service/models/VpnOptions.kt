package com.follow.clashx.service.models

import android.os.Parcelable
import com.follow.clashx.common.AccessControlMode
import kotlinx.parcelize.Parcelize

@Parcelize
data class AccessControlProps(
    val mode: AccessControlMode = AccessControlMode.rejectSelected,
    val acceptList: List<String> = emptyList(),
    val rejectList: List<String> = emptyList(),
) : Parcelable

private const val DEFAULT_IPV4_ADDRESS = "172.19.0.1/30"
private const val DEFAULT_IPV6_ADDRESS = "fdfe:dcba:9876::1/126"

@Parcelize
data class VpnOptions(
    val enable: Boolean = true,
    val port: Int = 7890,
    val socksPort: Int = 7891,
    val ipv4Address: String = DEFAULT_IPV4_ADDRESS,
    val ipv6Address: String = DEFAULT_IPV6_ADDRESS,
    // In-tunnel DNS resolver address supplied by the core (json key "dnsServerAddress").
    // The core hijacks :53 to it and resolves via the active config's dns settings.
    val dnsServerAddress: String = "",
    val routeAddress: List<String> = emptyList(),
    val allowBypass: Boolean = false,
    val systemProxy: Boolean = true,
    val bypassDomain: List<String> = emptyList(),
    val accessControl: AccessControlProps? = null,
    val ipv4: Boolean = true,
    val ipv6: Boolean = false,
    val includePackage: List<String>? = null,
    val excludePackage: List<String>? = null,
) : Parcelable

// Gson instantiates via Unsafe (no default-arg constructor call), so any field the
// JSON omits lands as null even in a non-null Kotlin type; every non-null field
// consumed downstream must be repaired here.
@Suppress("SENSELESS_COMPARISON")
fun VpnOptions.gsonSanitized(): VpnOptions = copy(
    ipv4Address = if (ipv4Address == null) DEFAULT_IPV4_ADDRESS else ipv4Address,
    ipv6Address = if (ipv6Address == null) DEFAULT_IPV6_ADDRESS else ipv6Address,
    dnsServerAddress = if (dnsServerAddress == null) "" else dnsServerAddress,
    routeAddress = if (routeAddress == null) emptyList() else routeAddress,
    bypassDomain = if (bypassDomain == null) emptyList() else bypassDomain,
    accessControl = accessControl?.gsonSanitized(),
)

@Suppress("SENSELESS_COMPARISON")
private fun AccessControlProps.gsonSanitized(): AccessControlProps = copy(
    acceptList = if (acceptList == null) emptyList() else acceptList,
    rejectList = if (rejectList == null) emptyList() else rejectList,
)

fun String.toCIDR(): Pair<String, Int>? {
    val parts = split("/", limit = 2)
    if (parts.size != 2) return null
    val prefix = parts[1].toIntOrNull() ?: return null
    return parts[0] to prefix
}

