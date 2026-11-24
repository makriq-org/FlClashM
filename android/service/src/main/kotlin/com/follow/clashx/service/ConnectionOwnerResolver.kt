package com.follow.clashx.service

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.system.OsConstants
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap

/**
 * Attributes one TUN flow to the app that owns its socket.
 *
 * Go calls this from the TUN packet path, so every answer must be cheap and
 * complete: the UID together with every package sharing it are needed to apply
 * the same per-app policy Android's VpnService.Builder received. A flow whose
 * socket Android cannot attribute is reported as unknown, never guessed.
 */
internal class ConnectionOwnerResolver(context: Context) {
    private val appContext = context.applicationContext

    private data class Packages(val names: List<String>, val expiresAt: Long)

    private val packageCache = ConcurrentHashMap<Int, Packages>()

    fun resolve(protocol: Int, source: InetSocketAddress, target: InetSocketAddress, uidHint: Int): String {
        val answer = JsonObject()
        try {
            val uid = if (uidHint > 0) uidHint else ownerUid(protocol, source, target)
            if (uid < 0) {
                answer.addProperty("unknown", true)
                return answer.toString()
            }
            answer.addProperty("uid", uid)
            answer.add("packages", JsonArray().apply { packagesFor(uid).forEach { add(it) } })
        } catch (error: Throwable) {
            answer.addProperty("error", "${error.javaClass.simpleName}: ${error.message ?: ""}")
        }
        return answer.toString()
    }

    private fun ownerUid(protocol: Int, source: InetSocketAddress, target: InetSocketAddress): Int {
        // getConnectionOwnerUid is API 29+; older releases are resolved in Go
        // through /proc/net before the callback runs.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return -1
        if (protocol != OsConstants.IPPROTO_TCP && protocol != OsConstants.IPPROTO_UDP) return -1
        val connectivity = appContext.getSystemService(ConnectivityManager::class.java) ?: return -1
        return connectivity.getConnectionOwnerUid(protocol, source, target)
    }

    private fun packagesFor(uid: Int): List<String> {
        // Root/system daemons own sockets but no package; the guard exempts the
        // system UIDs it knows and applies the app policy to the rest.
        if (uid <= 0) return emptyList()
        if (uid % PER_USER_RANGE < FIRST_APPLICATION_UID) return emptyList()
        val now = System.currentTimeMillis()
        packageCache[uid]?.let { if (now < it.expiresAt) return it.names }
        val names = runCatching {
            appContext.packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        }.getOrDefault(emptyList())
        if (packageCache.size >= MAX_CACHED_UIDS) packageCache.clear()
        // Install and uninstall change a UID's package set; the bounded TTL
        // keeps that accurate without a package-change receiver in :remote.
        packageCache[uid] = Packages(names, now + PACKAGE_CACHE_TTL_MS)
        return names
    }

    private companion object {
        const val PER_USER_RANGE = 100000
        const val FIRST_APPLICATION_UID = 10000
        const val MAX_CACHED_UIDS = 512
        const val PACKAGE_CACHE_TTL_MS = 60_000L
    }
}
