package com.follow.clashx.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.follow.clashx.common.GlobalState
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Declares that a runtime node reads a generated resolver list.
 *
 * The node stages [template]; the platform renders it into [path]. When
 * [dependsOnSystemDns] is set, the render substitutes the DNS servers of the
 * physical network for the [SYSTEM_DNS_PLACEHOLDER] line, so the resolver list
 * survives a DNS change with no Flutter process involved.
 *
 * This contract is node-type agnostic: nothing here knows which runtime asked
 * for it.
 */
data class RuntimeNodeResolverFile(
    val template: String,
    val path: String,
    val dependsOnSystemDns: Boolean,
    val resetPaths: List<String>,
) {
    companion object {
        /**
         * Marker a node stages where it wants the physical-network DNS servers
         * inserted. Pinned against the Dart constant by a product contract test.
         */
        const val SYSTEM_DNS_PLACEHOLDER = "# @flclashm:system-dns"

        fun fromJson(value: JSONObject?): RuntimeNodeResolverFile? {
            if (value == null) return null
            val template = value.optString("template", "").trim()
            val path = value.optString("path", "").trim()
            if (template.isEmpty() || path.isEmpty()) return null
            val rawResetPaths = value.optJSONArray("resetPaths") ?: JSONArray()
            val resetPaths = buildList {
                for (index in 0 until rawResetPaths.length()) {
                    val entry = rawResetPaths.optString(index, "").trim()
                    if (entry.isNotEmpty()) add(entry)
                }
            }
            return RuntimeNodeResolverFile(
                template = template,
                path = path,
                dependsOnSystemDns = value.optBoolean("dependsOnSystemDns", false),
                resetPaths = resetPaths,
            )
        }
    }
}

enum class RuntimeNodeResolverFileRenderResult {
    CHANGED,
    UNCHANGED,
    FAILED,

    /**
     * The node has nothing but the system-DNS marker to build its list from and
     * the physical network is not advertising any resolvers.
     *
     * Kept apart from [FAILED] because it is not a defect in the declaration:
     * a node with `activation: auto` wakes up precisely when connectivity is
     * poor, so this is the ordinary case rather than a corner one, and the
     * message the user sees has to say which of the two happened.
     */
    SYSTEM_DNS_UNAVAILABLE,
}

/**
 * Renders resolver files and keeps every produced path inside the node working
 * directory.
 */
object RuntimeNodeResolverFileWriter {

    /**
     * Resolves [relativePath] against [workingDirectory], rejecting anything
     * that escapes it. A node may only read and write inside its own directory,
     * so `..` segments and absolute paths are refused rather than sanitised.
     */
    fun resolveInside(workingDirectory: File, relativePath: String): File? {
        if (relativePath.isBlank()) return null
        // `File(parent, child)` quietly re-roots an absolute child inside the
        // parent, which would hide a malformed declaration instead of reporting
        // it. Only genuinely relative paths are accepted.
        if (File(relativePath).isAbsolute) return null
        val candidate = File(workingDirectory, relativePath)
        val root = runCatching { workingDirectory.canonicalFile }.getOrNull() ?: return null
        val resolved = runCatching { candidate.canonicalFile }.getOrNull() ?: return null
        val rootPath = root.path
        val resolvedPath = resolved.path
        val contained = resolvedPath == rootPath ||
            resolvedPath.startsWith(rootPath + File.separator)
        return if (contained) resolved else null
    }

    /**
     * Renders the template into the generated file.
     *
     * Reports whether the generated content changed or rendering failed, so
     * callers can restart only the nodes that need it and fail closed.
     */
    fun render(
        workingDirectory: File,
        spec: RuntimeNodeResolverFile,
        systemDns: List<String>,
    ): RuntimeNodeResolverFileRenderResult {
        val template = resolveInside(workingDirectory, spec.template)
            ?: return RuntimeNodeResolverFileRenderResult.FAILED
        val target = resolveInside(workingDirectory, spec.path)
            ?: return RuntimeNodeResolverFileRenderResult.FAILED
        if (!template.isFile) return RuntimeNodeResolverFileRenderResult.FAILED

        val templateText = runCatching { template.readText() }.getOrNull()
            ?: return RuntimeNodeResolverFileRenderResult.FAILED
        val rendered = runCatching {
            buildResolverList(templateText, systemDns)
        }.getOrNull() ?: return RuntimeNodeResolverFileRenderResult.FAILED
        if (rendered.isEmpty()) {
            // An empty list has two very different causes. Report them apart so
            // the caller can say "the network is not handing out DNS yet"
            // instead of the generic "could not render the resolver file".
            val wantsSystemDns = templateText.lineSequence().any {
                it.trim() == RuntimeNodeResolverFile.SYSTEM_DNS_PLACEHOLDER
            }
            return if (wantsSystemDns && systemDns.isEmpty()) {
                RuntimeNodeResolverFileRenderResult.SYSTEM_DNS_UNAVAILABLE
            } else {
                RuntimeNodeResolverFileRenderResult.FAILED
            }
        }
        val previous = if (target.exists()) runCatching { target.readText() }.getOrNull() else null
        if (previous == rendered) return RuntimeNodeResolverFileRenderResult.UNCHANGED

        // Write through a sibling temp file so a reader never observes a partial
        // list, even if the process is killed mid-write.
        val temp = File(target.parentFile, "${target.name}.tmp")
        return runCatching {
            target.parentFile?.mkdirs()
            temp.writeText(rendered)
            check(temp.renameTo(target)) {
                "Could not atomically replace ${target.path}"
            }
            RuntimeNodeResolverFileRenderResult.CHANGED
        }.getOrElse {
            temp.delete()
            RuntimeNodeResolverFileRenderResult.FAILED
        }
    }

    /**
     * Deletes runtime-owned paths whose contents depend on the generated list.
     *
     * A failed or escaping declaration is a hard failure: starting with stale
     * resolver state is less predictable than refusing to start the node.
     */
    fun resetDeclaredPaths(
        workingDirectory: File,
        spec: RuntimeNodeResolverFile,
    ): Boolean {
        val root = runCatching { workingDirectory.canonicalFile }.getOrNull() ?: return false
        for (resetPath in spec.resetPaths) {
            val target = resolveInside(workingDirectory, resetPath) ?: return false
            if (target == root) return false
            if (target.exists() && !target.deleteRecursively()) return false
        }
        return true
    }

    /**
     * Expands the system-DNS placeholder and de-duplicates by IP, keeping the
     * first occurrence and its port. Mirrors the upstream resolver-file loader.
     */
    fun buildResolverList(template: String, systemDns: List<String>): String {
        val lines = mutableListOf<String>()
        for (rawLine in template.lineSequence()) {
            val line = rawLine.trim()
            if (line == RuntimeNodeResolverFile.SYSTEM_DNS_PLACEHOLDER) {
                lines.addAll(systemDns)
                continue
            }
            if (line.isEmpty() || line.startsWith("#")) continue
            lines.add(line)
        }

        val seen = mutableSetOf<String>()
        val result = StringBuilder()
        for (line in lines) {
            val entry = line.trim()
            if (entry.isEmpty()) continue
            if (!seen.add(resolverKey(entry))) continue
            result.append(entry).append('\n')
        }
        return result.toString()
    }

    /** De-duplication key: the address without its port. */
    private fun resolverKey(entry: String): String {
        if (entry.startsWith("[")) {
            val end = entry.indexOf(']')
            if (end > 0) return entry.substring(1, end)
        }
        val lastColon = entry.lastIndexOf(':')
        if (lastColon <= 0) return entry
        // A bare IPv6 literal has several colons and no port.
        val head = entry.substring(0, lastColon)
        if (head.contains(':')) return entry
        return head
    }
}

/**
 * Reads the DNS servers of the physical network.
 *
 * Cold start applies the saved runtime-node plan before any network observer is
 * installed, so nodes must be able to ask for the current list themselves
 * rather than waiting to be told.
 */
object SystemDnsReader {
    /**
     * Normalises a DNS list before it is staged into a resolver file.
     *
     * `InetAddress.getHostAddress()` returns a link-local IPv6 address with its
     * zone attached (`fe80::1%wlan0`). Such an entry is dropped rather than
     * stripped: the resolver-file contract is bare addresses on both sides —
     * the Dart parser refuses `%` outright and the de-duplication key here
     * assumes no zone — and a zone-less `fe80::` address is not routable, so
     * keeping one would occupy a resolver slot and lengthen the MTU scan for an
     * address that can never answer. When this empties the list, the render
     * reports [RuntimeNodeResolverFileRenderResult.SYSTEM_DNS_UNAVAILABLE],
     * which is a far more useful outcome than a resolver that never replies.
     */
    fun sanitize(servers: List<String>): List<String> = servers
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.contains('%') }
        .distinct()

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
