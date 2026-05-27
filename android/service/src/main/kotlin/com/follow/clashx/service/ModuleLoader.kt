package com.follow.clashx.service

import android.app.Service

class ModuleLoader(private val service: Service) {
    private val modules = mutableListOf<Module>()

    fun install(factory: (Service) -> Module) {
        modules.add(factory(service))
    }

    @Volatile private var started = false

    suspend fun start() {
        if (started) stop()
        started = true
        modules.forEach { it.install() }
    }

    suspend fun stop() {
        if (!started) return
        started = false
        modules.asReversed().forEach {
            runCatching { it.uninstall() }
        }
    }
}

fun Service.moduleLoader(block: ModuleLoader.() -> Unit): ModuleLoader =
    ModuleLoader(this).apply(block)
