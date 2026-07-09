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
        // Report STOPPED only when nothing is running anymore: a delayed destroy
        // of a superseded instance (fast off→on) sees the new tunnel's runTime
        // and must not clobber the state it just published. Replaces the old
        // SERVICE_DESTROYED broadcast (whose late delivery needed exactly this
        // discriminator on the receiving side).
        if (State.runTime == 0L) StateHub.publish(StateHub.STOPPED)
    }
}
