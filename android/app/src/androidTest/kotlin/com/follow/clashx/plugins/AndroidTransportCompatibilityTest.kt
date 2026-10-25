package com.follow.clashx.plugins

import android.graphics.BitmapFactory
import android.os.Looper
import android.util.Base64
import com.follow.clashx.Service
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/** Exercises the actual plugin codecs and Binder/Go path without a Dart isolate.
 * The fake only replaces the Flutter messenger, never the backend or PackageManager. */
@RunWith(AndroidJUnit4::class)
class AndroidTransportCompatibilityTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    private class Messenger : BinaryMessenger {
        val handlers = ConcurrentHashMap<String, BinaryMessenger.BinaryMessageHandler>()
        val backgroundChannels = ConcurrentHashMap.newKeySet<String>()
        val repliesOnMain = ConcurrentHashMap<String, Boolean>()
        private val codec = StandardMethodCodec.INSTANCE
        val sent = ConcurrentLinkedQueue<Pair<String, ByteBuffer>>()
        @Volatile var holdServiceEvents = false
        val heldEvent = CompletableDeferred<Unit>()
        var heldMessages = 0
        override fun makeBackgroundTaskQueue(options: BinaryMessenger.TaskQueueOptions): BinaryMessenger.TaskQueue =
            object : BinaryMessenger.TaskQueue {}
        override fun send(channel: String, message: ByteBuffer?) {
            if (message != null) sent.add(channel to message.duplicate().apply { flip() })
        }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            send(channel, message)
            if (holdServiceEvents && channel == "com.makriq.flclash/service" && callback != null) {
                heldMessages++
                heldEvent.complete(Unit)
                // Simulate a busy Dart isolate: leave the event unacknowledged.
            } else callback?.reply(null)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?, queue: BinaryMessenger.TaskQueue?) {
            if (handler == null) backgroundChannels.remove(channel) else if (queue != null) backgroundChannels.add(channel)
            setMessageHandler(channel, handler)
        }
        suspend fun call(channel: String, method: String, arguments: Any? = null): Any? {
            val result = CompletableDeferred<Any?>()
            val message = codec.encodeMethodCall(MethodCall(method, arguments)).apply { flip() }
            val handler = checkNotNull(handlers[channel]) { "No handler for $channel" }
            val invoke = {
                handler.onMessage(message) { reply ->
                    repliesOnMain[channel] = Looper.myLooper() == Looper.getMainLooper()
                    try {
                        reply?.flip()
                        result.complete(reply?.let(codec::decodeEnvelope))
                    } catch (error: Throwable) { result.completeExceptionally(error) }
                }
            }
            if (channel in backgroundChannels) withContext(Dispatchers.Default) { invoke() }
            else withContext(Dispatchers.Main) { invoke() }
            return withTimeout(20_000) { result.await() }
        }
    }

    // The constructor's unused engine/surface arguments are null. The plugin only
    // reads applicationContext and messenger; no engine or native runtime is faked.
    private fun binding(messenger: Messenger): FlutterPlugin.FlutterPluginBinding =
        FlutterPlugin.FlutterPluginBinding::class.java.constructors.single().newInstance(
            context, null, messenger, null, null, null, null,
        ) as FlutterPlugin.FlutterPluginBinding

    @Test fun newAppChannelReturnsFileIconsAndLegacyChannelKeepsBase64(): Unit = runBlocking {
        val messenger = Messenger()
        val binding = binding(messenger)
        val plugin = AppPlugin()
        instrumentation.runOnMainSync { plugin.onAttachedToEngine(binding) }
        try {
            val args = mapOf("packageName" to context.packageName)
            val path = messenger.call("com.makriq.flclash/app", "getPackageIcon", args) as String
            assertTrue(File(path).canonicalPath.startsWith(context.cacheDir.canonicalPath + File.separator))
            val bitmap = BitmapFactory.decodeFile(path)
            assertNotNull(bitmap)
            assertEquals(128, bitmap.width)
            assertEquals(128, bitmap.height)
            bitmap.recycle()
            val encoded = messenger.call("app", "getPackageIcon", args) as String
            val bytes = Base64.decode(encoded, Base64.NO_WRAP)
            assertNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.also { it.recycle() })
            assertEquals(messenger.call("app", "getAndroidId"), messenger.call("com.makriq.flclash/app", "getAndroidId"))
            assertEquals(messenger.call("app", "isInstalledAppsPermissionGranted"),
                messenger.call("com.makriq.flclash/app", "isInstalledAppsPermissionGranted"))
        } finally {
            instrumentation.runOnMainSync { plugin.onDetachedFromEngine(binding) }
            assertTrue(messenger.handlers.isEmpty())
        }
    }

    @Test fun batteryChannelPublishesTheCurrentStateAndUnregistersOnDetach(): Unit = runBlocking {
        val messenger = Messenger()
        val binding = binding(messenger)
        val plugin = BatteryPlugin()
        instrumentation.runOnMainSync { plugin.onAttachedToEngine(binding) }
        try {
            messenger.call("com.makriq.flclash/battery/optimization", "listen")
            val event = messenger.sent.single { it.first == "com.makriq.flclash/battery/optimization" }
            assertTrue(StandardMethodCodec.INSTANCE.decodeEnvelope(event.second) is Boolean)
            // No activity: the request completes without claiming an exemption.
            assertNull(messenger.call("com.makriq.flclash/battery", "requestIgnoreOptimizations"))
            messenger.call("com.makriq.flclash/battery/optimization", "cancel")
        } finally {
            instrumentation.runOnMainSync { plugin.onDetachedFromEngine(binding) }
            assertTrue(messenger.handlers.isEmpty())
        }
    }

    @Test fun coreAliasCarriesTheSameV1SnapshotAsLegacyTransport(): Unit = runBlocking {
        val messenger = Messenger()
        val binding = binding(messenger)
        val plugin = ServicePlugin()
        instrumentation.runOnMainSync { plugin.onAttachedToEngine(binding) }
        try {
            assertTrue("com.makriq.flclash/core" in messenger.backgroundChannels)
            assertEquals("", messenger.call("com.makriq.flclash/service", "init", mapOf("eventEncoding" to "utf8")))
            fun request(id: String) = JSONObject().put("id", id).put("method", "backend")
                .put("data", JSONObject().put("apiVersion", 1).put("operationId", id).put("method", "snapshot")).toString()
            val old = JSONObject(messenger.call("com.makriq.flclash/service", "invokeAction", request("old-snapshot")) as String)
            val bytes = messenger.call("com.makriq.flclash/core", "invokeMethod", request("new-snapshot")) as ByteArray
            val new = JSONObject(String(bytes, Charsets.UTF_8))
            assertFalse(messenger.repliesOnMain.getValue("com.makriq.flclash/core"))
            assertEquals(0, old.getInt("code"))
            assertEquals(0, new.getInt("code"))
            assertEquals(1, new.getJSONObject("data").getInt("apiVersion"))
            val previous = old.getJSONObject("data").getJSONObject("result").getJSONObject("runtime")
            val current = new.getJSONObject("data").getJSONObject("result").getJSONObject("runtime")
            assertEquals(previous.getString("instanceId"), current.getString("instanceId"))
            val forbidden = JSONObject().put("id", "forbidden-direct-write").put("method", "setupConfig")
                .put("data", JSONObject()).toString()
            val denied = messenger.call("com.makriq.flclash/core", "invokeMethod", forbidden) as ByteArray
            assertEquals(-1, JSONObject(String(denied, Charsets.UTF_8)).getInt("code"))
            messenger.holdServiceEvents = true
            Service.backendCommand("runtime.stop")
            withTimeout(10_000) { messenger.heldEvent.await() }
            // A second explicit Stop and its receipt must finish while Dart has
            // still not processed the first event. Only one event is in flight.
            withTimeout(10_000) { Service.backendCommand("runtime.stop") }
            assertFalse(Service.backend("snapshot").getJSONObject("runtime").getBoolean("desiredRunning"))
            withContext(Dispatchers.Main) { assertEquals(1, messenger.heldMessages) }
        } finally {
            instrumentation.runOnMainSync { plugin.onDetachedFromEngine(binding) }
            assertTrue(messenger.handlers.isEmpty())
        }
    }
}
