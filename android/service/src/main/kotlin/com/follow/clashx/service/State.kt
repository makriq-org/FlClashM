package com.follow.clashx.service

import com.follow.clashx.common.ServiceDelegate
import com.follow.clashx.service.models.NotificationParams
import com.follow.clashx.service.models.VpnOptions
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex

object State {
    val runLock = Mutex()

    @Volatile var runTime: Long = 0L

    @Volatile var options: VpnOptions? = null

    val notificationParamsFlow = MutableStateFlow(NotificationParams())

    @Volatile var delegate: ServiceDelegate<IBaseService>? = null

    // The FlVpnService instance that currently owns the native Core TUN. Set when
    // a start successfully hands the fd to the core; consulted by a (possibly
    // delayed, not-under-runLock) onDestroy so a dying old instance only tears
    // down the core if it's STILL the owner — a fast off→on hands ownership to a
    // new instance whose tunnel the old onDestroy must not close.
    val tunOwner = AtomicReference<FlVpnService?>(null)
}
