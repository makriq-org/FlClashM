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

@Parcelize
data class VpnOptions(
    val enable: Boolean = true,
    val port: Int = 7890,
    val socksPort: Int = 7891,
    val ipv4Address: String = "172.19.0.1/30",
    val ipv6Address: String = "fdfe:dcba:9876::1/126",
    val dnsServers: List<String> = listOf("8.8.8.8", "1.1.1.1"),
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

@Suppress("SENSELESS_COMPARISON")
fun VpnOptions.gsonSanitized(): VpnOptions = copy(
    dnsServers = if (dnsServers == null) listOf("8.8.8.8", "1.1.1.1") else dnsServers,
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

