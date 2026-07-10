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

    // Immutable snapshot handed to the Android service that established the
    // currently running VPN. It is published only after handleStart succeeds
    // and cleared when that VPN stops. Do not replace it on core config reload:
    // VpnService.Builder package rules cannot change without re-establishing.
    @Volatile private var appliedOptions: VpnOptions? = null

    fun publishAppliedVpnOptions(options: VpnOptions) {
        appliedOptions = options.copy(
            routeAddress = options.routeAddress.toList(),
            bypassDomain = options.bypassDomain.toList(),
            includePackage = options.includePackage?.toList(),
            excludePackage = options.excludePackage?.toList(),
            accessControl = options.accessControl?.let {
                it.copy(
                    acceptList = it.acceptList.toList(),
                    rejectList = it.rejectList.toList(),
                )
            },
        )
    }

    fun clearAppliedVpnOptions() {
        appliedOptions = null
    }

    fun readAppliedVpnOptions(): VpnOptions? = appliedOptions

    val notificationParamsFlow = MutableStateFlow(NotificationParams())

    @Volatile var delegate: ServiceDelegate<IBaseService>? = null

    // The FlVpnService instance that currently owns the native Core TUN. Set when
    // a start successfully hands the fd to the core; consulted by a (possibly
    // delayed, not-under-runLock) onDestroy so a dying old instance only tears
    // down the core if it's STILL the owner — a fast off→on hands ownership to a
    // new instance whose tunnel the old onDestroy must not close.
    val tunOwner = AtomicReference<FlVpnService?>(null)
}
