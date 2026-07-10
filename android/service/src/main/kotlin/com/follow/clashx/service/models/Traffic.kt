package com.follow.clashx.service.models

import com.follow.clashx.common.formatBytes

data class Traffic(val up: Long = 0L, val down: Long = 0L) {
    val speedText: String get() = "${formatBytes(up)}/s ↑  ${formatBytes(down)}/s ↓"
}
