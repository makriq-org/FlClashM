package com.follow.clashx.core

import java.net.InetSocketAddress

data object Core {

    // --- TUN lifecycle --------------------------------------------------------

    private external fun nativeStartTun(fd: Int, cb: TunInterface): Boolean

    fun startTun(
        fd: Int,
        protect: (Int) -> Boolean,
        resolverProcess: (protocol: Int, source: InetSocketAddress, target: InetSocketAddress, uid: Int) -> String,
    ): Boolean {
        val cb = object : TunInterface {
            override fun protect(fd: Int) {
                protect(fd)
            }

            override fun resolverProcess(protocol: Int, source: String, target: String, uid: Int): String {
                return resolverProcess(
                    protocol,
                    parseInetSocketAddress(source),
                    parseInetSocketAddress(target),
                    uid,
                )
            }
        }
        return nativeStartTun(fd, cb)
    }

    external fun stopTun()

    // --- Action dispatch ------------------------------------------------------

    external fun invokeAction(data: String, cb: InvokeInterface)

    /**
     * One-shot initialization entry. [cb] is invoked once with the setup result
     * (JSON string) and then released on the native side.
     */
    external fun quickStart(
        initParams: String,
        params: String,
        stateParams: String,
        cb: InvokeInterface,
    )

    // --- Event stream ---------------------------------------------------------

    external fun setEventListener(cb: InvokeInterface?)

    // --- State / config mutators ---------------------------------------------

    external fun setState(state: String)
    external fun updateDns(dns: String)
    external fun resetConnections()

    // --- Getters --------------------------------------------------------------

    external fun getTraffic(): String
    external fun getTotalTraffic(): String
    external fun getRunTime(): String
    external fun getCurrentProfileName(): String
    external fun getAndroidVpnOptions(): String
    external fun getConfig(s: String): String

    // --- External listener (mixed-port etc.) ---------------------------------

    external fun startListener()
    external fun stopListener()

    // --- Helpers --------------------------------------------------------------

    private fun parseInetSocketAddress(address: String): InetSocketAddress {
        val lastColon = address.lastIndexOf(':')
        if (lastColon < 0) return InetSocketAddress.createUnresolved(address, 0)

        val host: String
        val port: Int
        if (address.startsWith("[")) {
            // IPv6: [::1]:port
            val closeBracket = address.indexOf(']')
            host = address.substring(1, closeBracket)
            port = address.substring(closeBracket + 2).toIntOrNull() ?: 0
        } else {
            host = address.substring(0, lastColon)
            port = address.substring(lastColon + 1).toIntOrNull() ?: 0
        }
        return InetSocketAddress.createUnresolved(host, port)
    }

    @Volatile
    private var nativeLoaded = false

    init {
        try {
            System.loadLibrary("core")
            nativeLoaded = true
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.e("Core", "Failed to load native library: ${e.message}")
        }
    }
}
