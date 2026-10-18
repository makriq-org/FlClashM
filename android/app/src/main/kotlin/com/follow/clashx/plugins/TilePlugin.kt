package com.follow.clashx.plugins

import com.follow.clashx.GlobalState
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Compatibility presentation channel. Native actions are submitted directly to Go. */
class TilePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "tile")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) { channel.setMethodCallHandler(null) }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "serviceReady", "updateTile", "updateMode", "updateGlobalModeEnabled" -> { GlobalState.syncStatus(); result.success(null) }
            else -> result.notImplemented()
        }
    }
}
