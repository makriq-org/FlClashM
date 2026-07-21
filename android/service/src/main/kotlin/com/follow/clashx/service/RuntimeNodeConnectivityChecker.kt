package com.follow.clashx.service

import android.os.SystemClock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.BufferedInputStream
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

data class RuntimeNodeConnectivityCheck(
    val urls: List<URI> = emptyList(),
    val required: Boolean = false,
    val timeoutMillis: Long = 5_000L,
    val startupTimeoutMillis: Long = 30_000L,
    val retryIntervalMillis: Long = 1_000L,
    val requests: Int = 1,
    val concurrency: Int = 1,
    val minSuccessRatio: Double? = null,
) {
    companion object {
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
            return RuntimeNodeConnectivityCheck(
                urls = urls,
                required = value.optBoolean("required", false),
                timeoutMillis = timeout * 1_000L,
                startupTimeoutMillis = startupTimeout * 1_000L,
                retryIntervalMillis = retryInterval * 1_000L,
                requests = requests,
                concurrency = concurrency,
                minSuccessRatio = ratio,
            )
        }
    }
}

object RuntimeNodeConnectivityChecker {
    private val ipv4LiteralPattern = Regex("(?:\\d{1,3}\\.){3}\\d{1,3}")
    private val httpStatusPattern = Regex("^HTTP/\\d\\.\\d [1-5]\\d{2}(?: .*)?$")

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
                    val successCount = if (probe(host, port, checks[index], config.timeoutMillis)) {
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
        val isLiteral = host.contains(':') || host.matches(ipv4LiteralPattern)
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
    ): Boolean = withTimeoutOrNull(timeoutMillis) {
        withContext(Dispatchers.IO) {
            runCatching {
                val addresses = InetAddress.getAllByName(uri.host)
                require(addresses.isNotEmpty() && addresses.all(::isPublicAddress))
                val targetPort = if (uri.port > 0) uri.port else if (uri.scheme == "http") 80 else 443
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
                    socksConnect(rawSocket, addresses.first(), targetPort)
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
                    status?.matches(httpStatusPattern) == true
                } finally {
                    runCatching { socket.close() }
                    if (socket !== rawSocket) runCatching { rawSocket.close() }
                }
            }.getOrDefault(false)
        }
    } ?: false

    private fun socksConnect(socket: Socket, target: InetAddress, port: Int) {
        val input = BufferedInputStream(socket.getInputStream())
        socket.getOutputStream().apply {
            write(byteArrayOf(0x05, 0x01, 0x00))
            flush()
        }
        val greeting = input.readExact(2)
        require(greeting[0] == 0x05.toByte() && greeting[1] == 0x00.toByte())
        val type = if (target is Inet4Address) 0x01 else 0x04
        socket.getOutputStream().apply {
            write(byteArrayOf(0x05, 0x01, 0x00, type.toByte()))
            write(target.address)
            write(byteArrayOf((port shr 8).toByte(), port.toByte()))
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
