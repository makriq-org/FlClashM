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
    private class OutputBuffer {
        private val lines = ArrayDeque<String>()
        private var length = 0

        @Synchronized
        fun add(line: String) {
            val boundedLine = line.takeLast(MAX_OUTPUT_LENGTH)
            lines.addLast(boundedLine)
            length += boundedLine.length
            while (lines.size > MAX_OUTPUT_LINES || length > MAX_OUTPUT_LENGTH) {
                length -= lines.removeFirst().length
            }
        }

        @Synchronized
        fun snapshot(): String = lines.joinToString("\n")
    }

    private data class RunningNode(
        val process: Process,
        val startTimeMillis: Long,
        val executablePath: String,
        val arguments: List<String>,
        val output: OutputBuffer,
        val logJob: Job?,
    )

    private val processLock = Mutex()
    private val runningNodes = ConcurrentHashMap<String, RunningNode>()

    suspend fun start(
        nodeId: String,
        executablePath: String,
        workingDirectory: String,
        arguments: List<String> = emptyList(),
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
            if (executable.canWrite()) {
                executable.setExecutable(true, true)
            } else if (!executable.canExecute()) {
                GlobalState.log("runtime node binary is not executable: $executablePath")
                return@withContext 0L
            }

            val runtimeDir = File(workingDirectory)
            if (!runtimeDir.exists()) {
                runtimeDir.mkdirs()
            }

            val started = try {
                ProcessBuilder(listOf(executablePath) + arguments)
                    .directory(runtimeDir)
                    .redirectErrorStream(true)
                    .start()
            } catch (e: Exception) {
                GlobalState.log("Failed to start runtime node `$nodeId`: ${e.message}")
                return@withContext 0L
            }

            val startTimeMillis = System.currentTimeMillis()
            val output = OutputBuffer()
            val logJob = GlobalState.scope.launch(Dispatchers.IO) {
                runCatching {
                    started.inputStream.bufferedReader().useLines { lines ->
                        lines.forEach { line ->
                            if (line.isNotBlank()) {
                                output.add(line)
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
                executablePath = executablePath,
                arguments = arguments,
                output = output,
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

    fun readLastError(nodeId: String): String {
        val running = runningNodes[nodeId] ?: return ""
        if (running.process.isAlive) return ""
        val exitCode = runCatching { running.process.exitValue() }.getOrNull()
        val output = running.output.snapshot().trim()
        val prefix = if (exitCode == null) "runtime node exited" else "runtime node exited with code $exitCode"
        return if (output.isEmpty()) prefix else "$prefix: $output"
    }

    private suspend fun stopInternal(nodeId: String): Long {
        val previous = runningNodes.remove(nodeId)
        if (previous == null) {
            return 0L
        }

        runCatching {
            previous.process.destroy()
            if (!previous.process.waitFor(3, TimeUnit.SECONDS)) {
                previous.process.destroyForcibly()
                previous.process.waitFor(3, TimeUnit.SECONDS)
            }
        }.onFailure {
            GlobalState.log("Failed to stop runtime node `$nodeId`: ${it.message}")
        }
        killMatchingRuntimeProcesses(
            nodeId = nodeId,
            executablePath = previous.executablePath,
            arguments = previous.arguments,
        )

        runCatching { previous.process.outputStream.close() }
        runCatching { previous.process.inputStream.close() }
        runCatching { previous.process.errorStream.close() }
        previous.logJob?.cancelAndJoin()
        return previous.startTimeMillis
    }

    private fun killMatchingRuntimeProcesses(
        nodeId: String,
        executablePath: String,
        arguments: List<String>,
    ) {
        val expected = listOf(executablePath) + arguments
        val selfPid = android.os.Process.myPid()
        val procDir = File("/proc")
        val entries = procDir.listFiles() ?: return
        for (entry in entries) {
            val pid = entry.name.toIntOrNull() ?: continue
            if (pid == selfPid) continue
            val cmdline = readProcessCmdline(pid) ?: continue
            if (cmdline != expected) continue
            runCatching {
                android.os.Process.killProcess(pid)
                waitForProcessExit(pid)
                if (File("/proc/$pid").exists()) {
                    android.os.Process.killProcess(pid)
                    waitForProcessExit(pid)
                }
            }.onFailure {
                GlobalState.log(
                    "Failed to kill runtime node `$nodeId` child process $pid: ${it.message}"
                )
            }
        }
    }

    private fun readProcessCmdline(pid: Int): List<String>? {
        return runCatching {
            File("/proc/$pid/cmdline")
                .readBytes()
                .toString(Charsets.UTF_8)
                .split('\u0000')
                .filter { it.isNotEmpty() }
        }.getOrNull()
    }

    private fun waitForProcessExit(pid: Int) {
        val procPath = File("/proc/$pid")
        val deadline = System.currentTimeMillis() + 1000L
        while (procPath.exists() && System.currentTimeMillis() < deadline) {
            Thread.sleep(50L)
        }
    }

    private const val MAX_OUTPUT_LINES = 20
    private const val MAX_OUTPUT_LENGTH = 4096
}
