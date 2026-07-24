package com.follow.clashx.service

import android.os.SystemClock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import com.follow.clashx.common.GlobalState
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.math.ceil
import kotlin.random.Random

data class RuntimeNodeConnectivityCheck(
    val urls: List<URI> = emptyList(),
    val required: Boolean = false,
    val timeoutMillis: Long = 5_000L,
    val startupTimeoutMillis: Long = 30_000L,
    val retryIntervalMillis: Long = 1_000L,
    val requests: Int = 1,
    val concurrency: Int = 1,
    val minSuccessRatio: Double? = null,
    // DoH endpoint used to resolve the probe target, bypassing the system
    // resolver (which answers with mihomo's fake-ip while the tunnel is up).
    // `null` means "use the platform resolver" (the `system` escape hatch).
    val resolver: URI? = DEFAULT_DOH_RESOLVER,
) {
    companion object {
        // Kept in sync with `_defaultByedpiProbeResolver` on the Dart side. The
        // literal-IP host avoids a bootstrap resolution of the resolver itself.
        internal val DEFAULT_DOH_RESOLVER: URI = URI("https://1.1.1.1/dns-query")

        fun fromJson(value: JSONObject?): RuntimeNodeConnectivityCheck {
            if (value == null) return RuntimeNodeConnectivityCheck()
            val urls = buildList {
                val rawUrls = value.optJSONArray("urls")
                if (rawUrls != null) {
                    require(rawUrls.length() <= 16) { "Too many connectivity-check addresses" }
                    for (index in 0 until rawUrls.length()) {
                        val uri = URI(rawUrls.getString(index))
                        require(RuntimeNodeConnectivityChecker.isSafeUri(uri)) {
                            "Unsafe connectivity-check address: $uri"
                        }
                        add(uri)
                    }
                }
            }
            val timeout = value.optInt("timeout", 5)
            val startupTimeout = value.optInt("startup-timeout", 30)
            val retryInterval = value.optInt("retry-interval", 1)
            val requests = value.optInt("requests", 1)
            val concurrency = value.optInt("concurrency", 1)
            val ratio = value.opt("min-success-ratio")?.let {
                require(it is Number) { "min-success-ratio must be a number" }
                it.toDouble()
            }
            require(timeout in 1..60) { "Invalid connectivity-check timeout" }
            require(startupTimeout in 1..300) { "Invalid connectivity-check startup-timeout" }
            require(retryInterval in 1..300) { "Invalid connectivity-check retry-interval" }
            require(requests in 1..32) { "Invalid connectivity-check requests" }
            require(concurrency in 1..16) { "Invalid connectivity-check concurrency" }
            require(ratio == null || ratio > 0.0 && ratio <= 1.0) {
                "Invalid connectivity-check min-success-ratio"
            }
            val resolver = when (val raw = value.optString("resolver", "").trim()) {
                "" -> DEFAULT_DOH_RESOLVER
                else -> if (raw.equals("system", ignoreCase = true)) {
                    null
                } else {
                    runCatching { URI(raw) }
                        .getOrNull()
                        ?.takeIf { it.scheme?.lowercase() == "https" && !it.host.isNullOrEmpty() }
                        ?: DEFAULT_DOH_RESOLVER
                }
            }
            return RuntimeNodeConnectivityCheck(
                urls = urls,
                required = value.optBoolean("required", false),
                timeoutMillis = timeout * 1_000L,
                startupTimeoutMillis = startupTimeout * 1_000L,
                retryIntervalMillis = retryInterval * 1_000L,
                requests = requests,
                concurrency = concurrency,
                minSuccessRatio = ratio,
                resolver = resolver,
            )
        }
    }
}

object RuntimeNodeConnectivityChecker {
    suspend fun checkUntilDeadline(
        nodeId: String,
        host: String,
        port: Int,
        config: RuntimeNodeConnectivityCheck,
    ): Boolean {
        val deadline = SystemClock.elapsedRealtime() + config.startupTimeoutMillis
        do {
            if (RuntimeNodeProcessManager.readStartTime(nodeId) <= 0L) return false
            val checkBudget = deadline - SystemClock.elapsedRealtime()
            if (checkBudget <= 0L) return false
            val passed = withTimeoutOrNull(checkBudget) {
                checkOnce(host, port, config)
            } ?: false
            if (passed) return RuntimeNodeProcessManager.readStartTime(nodeId) > 0L
            val remaining = deadline - SystemClock.elapsedRealtime()
            if (remaining <= 0L) return false
            delay(minOf(config.retryIntervalMillis, remaining))
        } while (true)
    }

    suspend fun checkOnce(
        host: String,
        port: Int,
        config: RuntimeNodeConnectivityCheck,
    ): Boolean = coroutineScope {
        val checks = buildList {
            for (url in config.urls) repeat(config.requests) { add(url) }
        }
        if (checks.isEmpty()) return@coroutineScope false
        val next = AtomicInteger(0)
        val successes = AtomicInteger(0)
        val completed = AtomicInteger(0)
        val requiredSuccesses = config.minSuccessRatio
            ?.let { ceil(it * checks.size).toInt() }
            ?: 1
        val decided = AtomicBoolean(false)
        List(minOf(config.concurrency, checks.size)) {
            async(Dispatchers.IO) {
                while (!decided.get()) {
                    val index = next.getAndIncrement()
                    if (index >= checks.size) break
                    val successCount = if (probe(host, port, checks[index], config.timeoutMillis, config.resolver)) {
                        successes.incrementAndGet()
                    } else {
                        successes.get()
                    }
                    val completedCount = completed.incrementAndGet()
                    if (successCount >= requiredSuccesses ||
                        successCount + checks.size - completedCount < requiredSuccesses
                    ) {
                        decided.set(true)
                    }
                }
            }
        }.awaitAll()
        successes.get() >= requiredSuccesses
    }

    internal fun isSafeUri(uri: URI): Boolean {
        val scheme = uri.scheme?.lowercase()
        val host = uri.host?.lowercase()?.removeSuffix(".") ?: return false
        if ((scheme != "http" && scheme != "https") ||
            uri.userInfo != null || uri.fragment != null ||
            uri.port == 0 || uri.port > 65535
        ) return false
        if (host == "localhost" || host.endsWith(".localhost") ||
            host.endsWith(".local") || host.endsWith(".internal") ||
            host.endsWith(".home.arpa")
        ) return false
        val isLiteral = host.contains(':') || host.matches(Regex("(?:\\d{1,3}\\.){3}\\d{1,3}"))
        return if (isLiteral) {
            runCatching { InetAddress.getByName(host) }
                .getOrNull()
                ?.let(::isPublicAddress)
                ?: false
        } else true
    }

    internal fun isPublicAddress(address: InetAddress): Boolean {
        val bytes = address.address.map { it.toInt() and 0xff }
        return when (address) {
            is Inet4Address -> {
                val first = bytes[0]
                val second = bytes[1]
                first != 0 && first != 10 && first != 127 && first < 224 &&
                    !(first == 100 && second in 64..127) &&
                    !(first == 169 && second == 254) &&
                    !(first == 172 && second in 16..31) &&
                    !(first == 192 && second == 0 && (bytes[2] == 0 || bytes[2] == 2)) &&
                    !(first == 192 && second == 168) &&
                    !(first == 192 && second == 88 && bytes[2] == 99) &&
                    !(first == 198 && second in 18..19) &&
                    !(first == 198 && second == 51 && bytes[2] == 100) &&
                    !(first == 203 && second == 0 && bytes[2] == 113)
            }
            is Inet6Address -> {
                (bytes[0] and 0xe0) == 0x20 &&
                    !address.isAnyLocalAddress && !address.isLoopbackAddress &&
                    !address.isLinkLocalAddress && !address.isSiteLocalAddress &&
                    !address.isMulticastAddress &&
                    !(bytes[0] == 0x20 && bytes[1] == 0x01 &&
                        bytes[2] == 0x0d && bytes[3] == 0xb8)
            }
            else -> false
        }
    }

    private suspend fun probe(
        socksHost: String,
        socksPort: Int,
        uri: URI,
        timeoutMillis: Long,
        resolver: URI?,
    ): Boolean = withTimeoutOrNull(timeoutMillis) {
        withContext(Dispatchers.IO) {
            runCatching {
                val targetPort = if (uri.port > 0) uri.port else if (uri.scheme == "http") 80 else 443
                // With a DoH resolver we hand byedpi a clean real IP; the system
                // resolver would return mihomo's fake-ip. With `system` we pass the
                // host name and let byedpi resolve it over the underlying network.
                val socksTarget = resolveSocksTarget(uri.host, resolver, timeoutMillis)
                    ?: return@runCatching false
                val rawSocket = Socket()
                var socket: Socket = rawSocket
                try {
                    rawSocket.apply {
                        connect(
                            InetSocketAddress(socksHost, socksPort),
                            timeoutMillis.toInt(),
                        )
                        soTimeout = timeoutMillis.toInt()
                    }
                    socksConnect(rawSocket, socksTarget, targetPort)
                    if (uri.scheme == "https") {
                        val tlsSocket = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                            .createSocket(rawSocket, uri.host, targetPort, true) as SSLSocket
                        socket = tlsSocket
                        tlsSocket.apply {
                            soTimeout = timeoutMillis.toInt()
                            sslParameters = sslParameters.apply {
                                endpointIdentificationAlgorithm = "HTTPS"
                            }
                            startHandshake()
                        }
                    }
                    val target = (uri.rawPath?.takeIf(String::isNotEmpty) ?: "/") +
                        (uri.rawQuery?.let { query -> "?$query" } ?: "")
                    val defaultPort = if (uri.scheme == "http") 80 else 443
                    val authority = if (uri.port > 0 && targetPort != defaultPort) {
                        "${uri.host}:$targetPort"
                    } else uri.host
                    socket.getOutputStream().write(
                        "HEAD $target HTTP/1.1\r\nHost: $authority\r\nConnection: close\r\n\r\n"
                            .toByteArray(StandardCharsets.US_ASCII),
                    )
                    socket.getOutputStream().flush()
                    val status = BufferedInputStream(socket.getInputStream())
                        .bufferedReader()
                        .readLine()
                    status?.matches(Regex("^HTTP/\\d\\.\\d [1-5]\\d{2}(?: .*)?$")) == true
                } finally {
                    runCatching { socket.close() }
                    if (socket !== rawSocket) runCatching { rawSocket.close() }
                }
            }.getOrDefault(false)
        }
    } ?: false

    private fun socksConnect(socket: Socket, targetHost: String, port: Int) {
        val input = BufferedInputStream(socket.getInputStream())
        socket.getOutputStream().apply {
            write(byteArrayOf(0x05, 0x01, 0x00))
            flush()
        }
        val greeting = input.readExact(2)
        require(greeting[0] == 0x05.toByte() && greeting[1] == 0x00.toByte())
        socket.getOutputStream().apply {
            write(buildSocksConnectRequest(targetHost, port))
            flush()
        }
        val header = input.readExact(4)
        require(header[0] == 0x05.toByte() && header[1] == 0x00.toByte())
        when (header[3].toInt() and 0xff) {
            0x01 -> input.readExact(4)
            0x03 -> input.readExact(input.readExact(1)[0].toInt() and 0xff)
            0x04 -> input.readExact(16)
            else -> error("Unknown SOCKS address type")
        }
        input.readExact(2)
    }

    internal fun buildSocksConnectRequest(targetHost: String, port: Int): ByteArray {
        require(port in 1..65535) { "Invalid SOCKS target port" }
        val literal = parseLiteralAddress(targetHost)
        if (literal != null) {
            require(isPublicAddress(literal)) { "Unsafe SOCKS target address" }
            val type = if (literal is Inet4Address) 0x01 else 0x04
            return byteArrayOf(0x05, 0x01, 0x00, type.toByte()) +
                literal.address +
                byteArrayOf((port shr 8).toByte(), port.toByte())
        }

        val host = targetHost.toByteArray(StandardCharsets.UTF_8)
        require(host.isNotEmpty() && host.size <= 255) {
            "Invalid SOCKS target host name"
        }
        return byteArrayOf(0x05, 0x01, 0x00, 0x03, host.size.toByte()) +
            host +
            byteArrayOf((port shr 8).toByte(), port.toByte())
    }

    private fun parseLiteralAddress(host: String): InetAddress? {
        val candidate = host.removePrefix("[").removeSuffix("]")
        val isLiteral = candidate.contains(':') ||
            candidate.matches(Regex("(?:\\d{1,3}\\.){3}\\d{1,3}"))
        if (!isLiteral) return null
        return InetAddress.getByName(candidate)
    }

    // Returns the address string to hand byedpi over SOCKS, or null when a DoH
    // resolver was configured but produced no usable public address (probe fails).
    private fun resolveSocksTarget(host: String, resolver: URI?, timeoutMillis: Long): String? {
        // `system` escape hatch, or an already-literal host: pass it straight
        // through — byedpi resolves the name, or buildSocksConnectRequest guards
        // the literal.
        if (resolver == null || parseLiteralAddress(host) != null) return host
        val target = dohResolve(resolver, host, timeoutMillis).firstOrNull(::isPublicAddress)
        if (target == null) {
            GlobalState.log("byedpi probe: DoH $resolver returned no usable address for $host")
        }
        return target?.hostAddress
    }

    // Minimal RFC 8484 DoH client (POST application/dns-message). Runs on a direct
    // socket which, sharing the app UID, bypasses the tunnel just like byedpi's own
    // outbound — so it sidesteps mihomo's fake-ip DNS without needing protect().
    private fun dohResolve(resolver: URI, host: String, timeoutMillis: Long): List<InetAddress> {
        val dohHost = resolver.host ?: return emptyList()
        val dohPort = if (resolver.port > 0) resolver.port else 443
        val timeout = timeoutMillis.toInt().coerceAtLeast(1)
        val (queryId, query) = buildDnsQuery(host)
        val rawSocket = Socket()
        return try {
            rawSocket.connect(InetSocketAddress(dohHost, dohPort), timeout)
            rawSocket.soTimeout = timeout
            val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                .createSocket(rawSocket, dohHost, dohPort, true) as SSLSocket
            tls.soTimeout = timeout
            tls.sslParameters = tls.sslParameters.apply {
                endpointIdentificationAlgorithm = "HTTPS"
            }
            tls.startHandshake()
            val path = (resolver.rawPath?.takeIf(String::isNotEmpty) ?: "/dns-query") +
                (resolver.rawQuery?.let { "?$it" } ?: "")
            val request = ByteArrayOutputStream().apply {
                write(
                    (
                        "POST $path HTTP/1.1\r\n" +
                            "Host: $dohHost\r\n" +
                            "Accept: application/dns-message\r\n" +
                            "Content-Type: application/dns-message\r\n" +
                            "Content-Length: ${query.size}\r\n" +
                            "Connection: close\r\n\r\n"
                        ).toByteArray(StandardCharsets.US_ASCII),
                )
                write(query)
            }.toByteArray()
            tls.getOutputStream().apply {
                write(request)
                flush()
            }
            val response = tls.getInputStream().readBytes()
            runCatching { tls.close() }
            val body = httpBody(response) ?: return emptyList()
            parseDnsAnswers(body, queryId)
        } catch (error: Throwable) {
            GlobalState.log("byedpi probe: DoH resolve of $host via $resolver failed: ${error.message}")
            emptyList()
        } finally {
            runCatching { rawSocket.close() }
        }
    }

    internal fun buildDnsQuery(host: String): Pair<Int, ByteArray> {
        val id = Random.nextInt(0x10000)
        val out = ByteArrayOutputStream()
        out.write(id ushr 8); out.write(id and 0xff)
        out.write(0x01); out.write(0x00) // flags: RD=1
        out.write(0x00); out.write(0x01) // QDCOUNT=1
        out.write(0x00); out.write(0x00) // ANCOUNT
        out.write(0x00); out.write(0x00) // NSCOUNT
        out.write(0x00); out.write(0x00) // ARCOUNT
        for (label in host.removeSuffix(".").split('.')) {
            val bytes = label.toByteArray(StandardCharsets.US_ASCII)
            require(bytes.isNotEmpty() && bytes.size <= 63) { "Invalid DNS label" }
            out.write(bytes.size)
            out.write(bytes)
        }
        out.write(0x00) // root label
        out.write(0x00); out.write(0x01) // QTYPE=A
        out.write(0x00); out.write(0x01) // QCLASS=IN
        return id to out.toByteArray()
    }

    internal fun parseDnsAnswers(msg: ByteArray, expectedId: Int): List<InetAddress> {
        if (msg.size < 12) return emptyList()
        if (u16(msg, 0) != expectedId) return emptyList()
        if (msg[3].toInt() and 0x0f != 0) return emptyList() // RCODE != NOERROR
        val questions = u16(msg, 4)
        val answers = u16(msg, 6)
        var pos = 12
        repeat(questions) { pos = skipName(msg, pos) + 4 } // + QTYPE + QCLASS
        val result = mutableListOf<InetAddress>()
        repeat(answers) {
            pos = skipName(msg, pos)
            if (pos + 10 > msg.size) return result
            val type = u16(msg, pos)
            val rdlength = u16(msg, pos + 8)
            pos += 10
            if (pos + rdlength > msg.size) return result
            if (type == 1 && rdlength == 4) {
                result.add(InetAddress.getByAddress(msg.copyOfRange(pos, pos + 4)))
            }
            pos += rdlength
        }
        return result
    }

    private fun skipName(msg: ByteArray, start: Int): Int {
        var pos = start
        while (pos < msg.size) {
            val len = msg[pos].toInt() and 0xff
            if (len == 0) return pos + 1
            if (len and 0xc0 == 0xc0) return pos + 2 // compression pointer ends the name
            pos += len + 1
        }
        return pos
    }

    private fun u16(data: ByteArray, offset: Int): Int =
        ((data[offset].toInt() and 0xff) shl 8) or (data[offset + 1].toInt() and 0xff)

    private fun httpBody(response: ByteArray): ByteArray? {
        val separator = indexOfSequence(response, CRLF_CRLF, 0) ?: return null
        val header = String(response, 0, separator, StandardCharsets.US_ASCII)
        val lines = header.split("\r\n")
        val status = lines.firstOrNull() ?: return null
        if (!status.matches(Regex("^HTTP/\\d\\.\\d 200(?: .*)?$"))) return null
        val chunked = lines.drop(1).any { line ->
            val colon = line.indexOf(':')
            colon > 0 &&
                line.substring(0, colon).trim().equals("Transfer-Encoding", ignoreCase = true) &&
                line.substring(colon + 1).trim().equals("chunked", ignoreCase = true)
        }
        val body = response.copyOfRange(separator + 4, response.size)
        return if (chunked) dechunk(body) else body
    }

    private fun dechunk(data: ByteArray): ByteArray? {
        val out = ByteArrayOutputStream()
        var pos = 0
        while (pos < data.size) {
            val lineEnd = indexOfSequence(data, CRLF, pos) ?: return null
            val size = String(data, pos, lineEnd - pos, StandardCharsets.US_ASCII)
                .substringBefore(';').trim().toIntOrNull(16) ?: return null
            pos = lineEnd + 2
            if (size == 0) break
            if (pos + size > data.size) return null
            out.write(data, pos, size)
            pos += size + 2 // skip the chunk's trailing CRLF
        }
        return out.toByteArray()
    }

    private fun indexOfSequence(data: ByteArray, seq: ByteArray, from: Int): Int? {
        if (seq.isEmpty() || data.size < seq.size) return null
        var i = from.coerceAtLeast(0)
        while (i <= data.size - seq.size) {
            var match = true
            for (j in seq.indices) {
                if (data[i + j] != seq[j]) {
                    match = false
                    break
                }
            }
            if (match) return i
            i++
        }
        return null
    }

    private val CRLF = "\r\n".toByteArray(StandardCharsets.US_ASCII)
    private val CRLF_CRLF = "\r\n\r\n".toByteArray(StandardCharsets.US_ASCII)

    private fun BufferedInputStream.readExact(size: Int): ByteArray {
        val result = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = read(result, offset, size - offset)
            require(count > 0) { "Unexpected end of SOCKS response" }
            offset += count
        }
        return result
    }
}
