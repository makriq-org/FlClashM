package com.follow.clashx.service

import android.app.Service

abstract class Module(protected val service: Service) {
    abstract suspend fun install()
    abstract suspend fun uninstall()
}
