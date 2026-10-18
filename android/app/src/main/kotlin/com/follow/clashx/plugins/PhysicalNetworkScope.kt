package com.follow.clashx.plugins

import android.content.Context

internal object PhysicalNetworkScope {
    fun read(context: Context): String = com.follow.clashx.common.PhysicalNetworkScope.read(context)
}
