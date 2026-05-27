package com.follow.clashx.extensions

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.drawable.Drawable
import android.util.Base64
import androidx.core.graphics.drawable.toBitmap
import com.follow.clashx.TempActivity
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

suspend fun Drawable.getBase64(): String {
    val drawable = this
    return withContext(Dispatchers.IO) {
        val bitmap = drawable.toBitmap()
        val byteArrayOutputStream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, byteArrayOutputStream)
        bitmap.recycle()
        Base64.encodeToString(byteArrayOutputStream.toByteArray(), Base64.NO_WRAP)
    }
}

fun Context.wrapAction(action: String): String = "$packageName.action.$action"

fun Context.getActionIntent(action: String): Intent =
    Intent(this, TempActivity::class.java)
        .setAction(wrapAction(action))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)

suspend fun <T> MethodChannel.awaitResult(
    method: String,
    arguments: Any? = null,
): T? = withContext(Dispatchers.Main) {
    suspendCancellableCoroutine { continuation ->
        invokeMethod(method, arguments, object : MethodChannel.Result {
            @Suppress("UNCHECKED_CAST")
            override fun success(result: Any?) = continuation.resume(result as T)
            override fun error(code: String, message: String?, details: Any?) = continuation.resume(null)
            override fun notImplemented() = continuation.resume(null)
        })
    }
}
