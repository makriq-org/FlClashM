package com.follow.clashx.service

import com.follow.clashx.common.BroadcastAction
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.sendInternalBroadcast
import com.follow.clashx.service.models.VpnOptions

interface IBaseService {
    suspend fun handleStart(options: VpnOptions)
    suspend fun handleStop()

    var destroyed: Boolean

    fun handleCreate() {
        destroyed = false
        GlobalState.application.sendInternalBroadcast(BroadcastAction.SERVICE_CREATED.action)
    }

    fun handleDestroy() {
        if (destroyed) return
        destroyed = true
        GlobalState.application.sendInternalBroadcast(BroadcastAction.SERVICE_DESTROYED.action)
    }
}
