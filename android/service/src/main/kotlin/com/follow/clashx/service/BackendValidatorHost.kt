package com.follow.clashx.service

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Process
import android.os.RemoteException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

/** Binding, cancellation and process lifetime only; validation is implemented in Go. */
internal class BackendValidatorHost(private val context: Context) {
    private val lock = Mutex()
    private class ConnectionLost(message: String) : IllegalStateException(message)

    suspend fun validate(path: String) = lock.withLock {
        // Serialize binding callbacks and teardown on Android's main dispatcher.
        // The native parser still runs asynchronously in the private process.
        withContext(Dispatchers.Main.immediate) {
            withTimeout(60_000L) {
                try {
                    validateOnce(path)
                } catch (_: ConnectionLost) {
                    // Android can deliver a dying service from a previous host
                    // instance. Retry IPC once, never retry a parser rejection.
                    validateOnce(path)
                } catch (_: RemoteException) {
                    validateOnce(path)
                }
            }
        }
    }

    private suspend fun validateOnce(path: String) {
        val connected = CompletableDeferred<IBackendValidator>()
        val result = CompletableDeferred<String>()
        val died = CompletableDeferred<Unit>()
        var validatorPid = 0
        var validatorBinder: IBinder? = null
        var closed = false
        fun disconnected(message: String) {
            val error = ConnectionLost(message)
            connected.completeExceptionally(error)
            result.completeExceptionally(error)
        }
        val death = IBinder.DeathRecipient {
            died.complete(Unit)
            disconnected("validator died")
        }
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                if (closed) return
                try {
                    checkNotNull(binder) { "validator returned no binder" }
                    validatorBinder = binder
                    binder.linkToDeath(death, 0)
                    val validator = IBackendValidator.Stub.asInterface(binder)
                    validatorPid = validator.pid
                    connected.complete(validator)
                } catch (error: Exception) {
                    connected.completeExceptionally(error)
                }
            }
            override fun onServiceDisconnected(name: ComponentName?) = disconnected("validator disconnected")
            override fun onBindingDied(name: ComponentName?) = disconnected("validator binding died")
            override fun onNullBinding(name: ComponentName?) = disconnected("validator returned no binding")
        }
        val intent = Intent(context, BackendValidatorService::class.java)
        try {
            check(context.bindService(intent, connection, Context.BIND_AUTO_CREATE)) { "validator bind failed" }
            // A process killed before its first onServiceConnected callback may
            // produce no disconnect callback at all. Release that binding and
            // let the bounded IPC retry create a new service instance.
            val validator = withTimeoutOrNull(10_000L) { connected.await() }
                ?: throw ConnectionLost("validator connection timed out")
            validator.validate(path, object : ICallbackInterface.Stub() {
                override fun onResult(data: ByteArray, isSuccess: Boolean, ack: IAckInterface?) {
                    // Never let a malformed IPC response throw on a Binder thread
                    // and leave the operation waiting until its outer timeout.
                    runCatching {
                        check(isSuccess) { "validator request failed" }
                        val envelope = JSONObject(data.toString(Charsets.UTF_8))
                        check(envelope.getInt("code") == 0) { "validator request failed" }
                        envelope.getString("data")
                    }.fold(result::complete, result::completeExceptionally)
                }
            })
            val error = result.await()
            check(error.isEmpty()) { error }
        } finally {
            // Unbind BEFORE killing: BIND_AUTO_CREATE must not restart the dying
            // process and hand that stale binding to the next validation.
            closed = true
            connected.cancel()
            runCatching { context.unbindService(connection) }
            if (validatorPid > 0 && validatorPid != Process.myPid()) {
                Process.killProcess(validatorPid)
                // Keep the serialization slot through death, including cancellation.
                // A failed teardown must fail closed instead of reusing parser state.
                withContext(NonCancellable) {
                    try {
                        withTimeout(5_000L) { died.await() }
                    } finally {
                        // Retain a strong Binder reference through death. Android
                        // otherwise unlinks the recipient on the last strong ref,
                        // so a successful parse can lose its teardown notification.
                        runCatching { validatorBinder?.unlinkToDeath(death, 0) }
                    }
                }
            } else {
                runCatching { validatorBinder?.unlinkToDeath(death, 0) }
            }
        }
    }
}
