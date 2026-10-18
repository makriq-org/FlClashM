package com.follow.clashx.service

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Process
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger

/** Binding, cancellation and process lifetime only; validation is implemented in Go. */
internal class BackendValidatorHost(private val context: Context) {
    private val lock = Mutex()

    suspend fun validate(path: String) = lock.withLock {
        withTimeout(60_000L) {
            val connected = CompletableDeferred<IBackendValidator>()
            val validatorPid = AtomicInteger()
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                    val validator = IBackendValidator.Stub.asInterface(binder)
                    // Record the private host PID before resuming the coroutine;
                    // cancellation can otherwise lose the process between binding
                    // and the first resumed instruction.
                    validatorPid.set(validator.pid)
                    if (!connected.complete(validator)) terminate()
                }
                override fun onServiceDisconnected(name: ComponentName?) {
                    connected.completeExceptionally(IllegalStateException("validator disconnected"))
                }
                override fun onBindingDied(name: ComponentName?) = onServiceDisconnected(name)
                override fun onNullBinding(name: ComponentName?) = onServiceDisconnected(name)
                fun terminate() {
                    val pid = validatorPid.get()
                    if (pid > 0 && pid != Process.myPid()) Process.killProcess(pid)
                }
            }
            val intent = Intent(context, BackendValidatorService::class.java)
            check(context.bindService(intent, connection, Context.BIND_AUTO_CREATE)) { "validator bind failed" }
            try {
                val validator = connected.await()
                val result = CompletableDeferred<String>()
                validator.asBinder().linkToDeath({ result.completeExceptionally(IllegalStateException("validator died")) }, 0)
                validator.validate(path, object : ICallbackInterface.Stub() {
                    override fun onResult(data: ByteArray, isSuccess: Boolean, ack: IAckInterface?) {
                        val envelope = JSONObject(data.toString(Charsets.UTF_8))
                        if (envelope.optInt("code", -1) != 0) {
                            result.completeExceptionally(IllegalStateException("validator request failed"))
                        } else result.complete(envelope.optString("data", "invalid validator result"))
                    }
                })
                val error = result.await()
                check(error.isEmpty()) { error }
            } finally {
                // Always use a fresh parser process. No process-global parser
                // state survives an aborted or successful compilation.
                connected.cancel()
                connection.terminate()
                runCatching { context.unbindService(connection) }
            }
        }
    }
}
