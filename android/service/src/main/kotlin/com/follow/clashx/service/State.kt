package com.follow.clashx.service

import android.content.Intent
import com.follow.clashx.common.ServiceDelegate
import com.follow.clashx.service.models.NotificationParams
import com.follow.clashx.service.models.VpnOptions
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex

object State {
    val runLock = Mutex()

    @Volatile var runTime: Long = 0L

    @Volatile var options: VpnOptions? = null

    val notificationParamsFlow = MutableStateFlow(NotificationParams())

    @Volatile var delegate: ServiceDelegate<IBaseService>? = null

    @Volatile var intent: Intent? = null
}
