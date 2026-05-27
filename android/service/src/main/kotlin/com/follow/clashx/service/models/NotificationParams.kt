package com.follow.clashx.service.models

import android.os.Parcelable
import kotlinx.parcelize.Parcelize

@Parcelize
data class NotificationParams(
    val title: String = "FlClashX",
    val stopText: String = "Stop",
    val onlyStatisticsProxy: Boolean = false,
) : Parcelable
