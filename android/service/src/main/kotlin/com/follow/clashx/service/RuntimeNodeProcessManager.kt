package com.follow.clashx.service

import com.follow.clashx.common.GlobalState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

object RuntimeNodeProcessManager {
    private data class RunningNode(
        val process: Process,
        val startTimeMillis: Long,
        val logJob: Job?,
    )

    private val processLock = Mutex()
    private val runningNodes = ConcurrentHashMap<String, RunningNode>()

    suspend fun start(
        nodeId: String,
        executablePath: String,
        workingDirectory: String,
    ): Long = processLock.withLock {
        withContext(Dispatchers.IO) {
            val running = runningNodes[nodeId]
            if (running?.process?.isAlive == true && running.startTimeMillis > 0L) {
                return@withContext running.startTimeMillis
            }

            stopInternal(nodeId)

            val executable = File(executablePath)
            if (!executable.exists()) {
                GlobalState.log("runtime node binary is missing: $executablePath")
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
                GlobalState.log("Failed to start runtime node `$nodeId`: ${e.message}")
                return@withContext 0L
            }

            val startTimeMillis = System.currentTimeMillis()
            val logJob = GlobalState.scope.launch(Dispatchers.IO) {
                runCatching {
                    started.inputStream.bufferedReader().useLines { lines ->
                        lines.forEach { line ->
                            if (line.isNotBlank()) {
                                GlobalState.log("[runtime-node:$nodeId] $line")
                            }
                        }
                    }
                }.onFailure {
                    if (started.isAlive) {
                        GlobalState.log("runtime node `$nodeId` log reader failed: ${it.message}")
                    }
                }
            }

            runningNodes[nodeId] = RunningNode(
                process = started,
                startTimeMillis = startTimeMillis,
                logJob = logJob,
            )
            startTimeMillis
        }
    }

    suspend fun stop(nodeId: String): Long = processLock.withLock {
        withContext(Dispatchers.IO) {
            stopInternal(nodeId)
        }
    }

    suspend fun stopAll(): Unit = processLock.withLock {
        withContext(Dispatchers.IO) {
            for (nodeId in runningNodes.keys.toList()) {
                stopInternal(nodeId)
            }
        }
    }

    fun readStartTime(nodeId: String): Long {
        val running = runningNodes[nodeId] ?: return 0L
        return if (running.process.isAlive && running.startTimeMillis > 0L) {
            running.startTimeMillis
        } else {
            0L
        }
    }

    private suspend fun stopInternal(nodeId: String): Long {
        val previous = runningNodes.remove(nodeId)
        if (previous == null) {
            return 0L
        }

        runCatching {
            previous.process.outputStream.close()
            previous.process.inputStream.close()
            previous.process.errorStream.close()
            previous.process.destroy()
            if (!previous.process.waitFor(3, TimeUnit.SECONDS)) {
                previous.process.destroyForcibly()
                previous.process.waitFor(3, TimeUnit.SECONDS)
            }
        }.onFailure {
            GlobalState.log("Failed to stop runtime node `$nodeId`: ${it.message}")
        }

        previous.logJob?.cancelAndJoin()
        return previous.startTimeMillis
    }
}
