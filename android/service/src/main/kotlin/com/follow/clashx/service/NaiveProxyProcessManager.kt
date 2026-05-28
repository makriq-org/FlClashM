package com.follow.clashx.service

import com.follow.clashx.common.GlobalState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.TimeUnit

object NaiveProxyProcessManager {
    @Volatile private var process: Process? = null
    @Volatile private var startTimeMillis: Long = 0L
    private var logJob: Job? = null

    suspend fun start(executablePath: String, workingDirectory: String): Long =
        withContext(Dispatchers.IO) {
            val running = process
            if (running?.isAlive == true && startTimeMillis > 0L) {
                return@withContext startTimeMillis
            }

            stopInternal()

            val executable = File(executablePath)
            if (!executable.exists()) {
                GlobalState.log("naiveproxy binary is missing: $executablePath")
                return@withContext 0L
            }
            executable.setExecutable(true, true)

            val runtimeDir = File(workingDirectory)
            if (!runtimeDir.exists()) {
                runtimeDir.mkdirs()
            }

            val started = try {
                ProcessBuilder(executablePath)
                    .directory(runtimeDir)
                    .redirectErrorStream(true)
                    .start()
            } catch (e: Exception) {
                GlobalState.log("Failed to start naiveproxy: ${e.message}")
                return@withContext 0L
            }

            process = started
            startTimeMillis = System.currentTimeMillis()
            logJob = GlobalState.scope.launch(Dispatchers.IO) {
                runCatching {
                    started.inputStream.bufferedReader().useLines { lines ->
                        lines.forEach { line ->
                            if (line.isNotBlank()) {
                                GlobalState.log("[naiveproxy] $line")
                            }
                        }
                    }
                }.onFailure {
                    if (started.isAlive) {
                        GlobalState.log("naiveproxy log reader failed: ${it.message}")
                    }
                }
            }

            startTimeMillis
        }

    suspend fun stop(): Long = withContext(Dispatchers.IO) {
        stopInternal()
    }

    fun readStartTime(): Long =
        if (process?.isAlive == true && startTimeMillis > 0L) startTimeMillis else 0L

    private suspend fun stopInternal(): Long {
        val previous = process
        val previousStartTime = startTimeMillis
        val previousLogJob = logJob
        process = null
        startTimeMillis = 0L
        logJob = null

        if (previous != null) {
            runCatching {
                previous.outputStream.close()
                previous.inputStream.close()
                previous.errorStream.close()
                previous.destroy()
                if (!previous.waitFor(3, TimeUnit.SECONDS)) {
                    previous.destroyForcibly()
                    previous.waitFor(3, TimeUnit.SECONDS)
                }
            }.onFailure {
                GlobalState.log("Failed to stop naiveproxy: ${it.message}")
            }
        }

        previousLogJob?.cancelAndJoin()

        return previousStartTime
    }
}
