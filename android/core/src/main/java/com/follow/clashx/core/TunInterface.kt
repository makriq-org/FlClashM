package com.follow.clashx.core

import androidx.annotation.Keep

@Keep
interface TunInterface {
    fun protect(fd: Int)
    fun resolverProcess(protocol: Int, source: String, target: String, uid: Int): String

    /** JSON owner answer used by the in-TUN app isolation guard. */
    fun connectionOwner(protocol: Int, source: String, target: String, uid: Int): String
}