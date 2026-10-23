package com.follow.clashx.service

import com.follow.clashx.service.models.VpnOptions

interface IBaseService {
    suspend fun handleStart(options: VpnOptions)
    suspend fun handleStop()

    var destroyed: Boolean

    fun handleCreate() {
        destroyed = false
    }

    fun handleDestroy() {
        if (destroyed) return
        destroyed = true

    }
}
