package com.follow.clashx.service

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.util.Base64
import com.follow.clashx.common.GlobalState
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/** Virtual original profiles. Internal journals and executable artifacts are private. */
class FilesProvider : DocumentsProvider() {
    private val roots = arrayOf(DocumentsContract.Root.COLUMN_ROOT_ID, DocumentsContract.Root.COLUMN_FLAGS,
        DocumentsContract.Root.COLUMN_TITLE, DocumentsContract.Root.COLUMN_DOCUMENT_ID)
    private val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED, DocumentsContract.Document.COLUMN_FLAGS,
        DocumentsContract.Document.COLUMN_SIZE)
    private val ioThread by lazy { HandlerThread("backend-documents").apply { start() } }
    private val handler by lazy { Handler(ioThread.looper) }
    override fun onCreate(): Boolean = true

    private fun normalized(id: String): String {
        // Keep previously granted profile document URIs usable after migration.
        val root = requireNotNull(context).filesDir.absolutePath
        return when (id) { root -> "root"; "$root/profiles" -> "profiles"
            else -> if (id.startsWith("$root/profiles/")) "profile:" + id.removePrefix("$root/profiles/").removeSuffix(".yaml") else id }
    }
    private fun profileId(document: String): String = normalized(document).let {
        if (!it.startsWith("profile:") || it.length <= 8) throw FileNotFoundException("Unknown document")
        it.removePrefix("profile:")
    }
    private suspend fun request(method: String, params: JSONObject = JSONObject()): JSONObject {
        BackendHost.initialize()
        val response = BackendHost.command(method, params)
        response.optJSONObject("error")?.let { throw FileNotFoundException(it.optString("message")) }
        return response.optJSONObject("result") ?: JSONObject()
    }
    private suspend fun command(method: String, params: JSONObject): JSONObject {
        var receipt = request(method, params)
        withTimeout(180_000L) {
            while (receipt.optString("status") == "accepted") {
                delay(100)
                receipt = request("operation.get", JSONObject().put("operationId", receipt.getString("operationId")))
            }
        }
        check(receipt.optString("status") == "succeeded") { receipt.optString("error") }
        return receipt
    }
    private fun row(cursor: MatrixCursor, id: String, title: String, size: Long = 0, modified: Long = 0, directory: Boolean = false) {
        cursor.newRow().apply {
            add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, id)
            add(DocumentsContract.Document.COLUMN_MIME_TYPE, if (directory) DocumentsContract.Document.MIME_TYPE_DIR else "application/yaml")
            add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, title)
            add(DocumentsContract.Document.COLUMN_LAST_MODIFIED, modified)
            add(DocumentsContract.Document.COLUMN_FLAGS, if (directory) 0 else DocumentsContract.Document.FLAG_SUPPORTS_WRITE)
            add(DocumentsContract.Document.COLUMN_SIZE, size)
        }
    }
    override fun queryRoots(projection: Array<out String>?): Cursor = MatrixCursor(projection ?: roots).apply {
        newRow().apply {
            add(DocumentsContract.Root.COLUMN_ROOT_ID, "flclashm")
            add(DocumentsContract.Root.COLUMN_FLAGS, DocumentsContract.Root.FLAG_LOCAL_ONLY)
            add(DocumentsContract.Root.COLUMN_TITLE, "FlClashM")
            add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, "root")
        }
    }
    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor = MatrixCursor(projection ?: columns).also { cursor ->
        when (normalized(documentId)) {
            "root" -> row(cursor, "root", "FlClashM", directory = true)
            "profiles" -> row(cursor, "profiles", "profiles", directory = true)
            else -> runBlocking {
                val id = profileId(documentId)
                val record = request("profile.get", JSONObject().put("profileId", id))
                row(cursor, "profile:$id", "$id.yaml", record.getString("source").toByteArray(Charsets.UTF_8).size.toLong())
            }
        }
    }
    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor = MatrixCursor(projection ?: columns).also { cursor ->
        when (normalized(parentDocumentId)) {
            "root" -> row(cursor, "profiles", "profiles", directory = true)
            "profiles" -> runBlocking {
                val catalog = request("snapshot").getJSONObject("catalog").getJSONArray("profiles")
                for (index in 0 until catalog.length()) {
                    val metadata = catalog.getJSONObject(index).getJSONObject("metadata")
                    val id = metadata.getString("id")
                    row(cursor, "profile:$id", "$id.yaml")
                }
            }
            else -> throw FileNotFoundException("Unknown directory")
        }
    }
    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor = runBlocking {
        signal?.throwIfCanceled()
        val id = profileId(documentId)
        val record = request("profile.get", JSONObject().put("profileId", id))
        signal?.throwIfCanceled()
        val revision = record.getLong("revision")
        val temporary = File.createTempFile("profile-", ".yaml", requireNotNull(context).cacheDir)
        temporary.writeText(record.getString("source"), Charsets.UTF_8)
        val flags = ParcelFileDescriptor.parseMode(mode)
        ParcelFileDescriptor.open(temporary, flags, handler) { error ->
            try {
                if (error == null && mode.contains('w')) runBlocking {
                    check(temporary.length() <= 16L * 1024 * 1024) { "Profile exceeds size limit" }
                    val token = request("blob.create").getString("token")
                    try {
                        temporary.inputStream().use { stream ->
                            val bytes = ByteArray(192 * 1024)
                            var offset = 0L
                            while (true) {
                                val count = stream.read(bytes)
                                if (count < 0) break
                                request("blob.append", JSONObject().put("token", token).put("offset", offset)
                                    .put("data", Base64.encodeToString(bytes, 0, count, Base64.NO_WRAP)))
                                offset += count
                            }
                        }
                        command("profile.import.file", JSONObject().put("token", token)
                            .put("metadata", JSONObject().put("id", id)).put("expectedRevision", revision))
                        requireNotNull(context).contentResolver.notifyChange(DocumentsContract.buildDocumentUri(requireNotNull(context).packageName + ".provider.files", "profile:$id"), null)
                    } finally { request("blob.delete", JSONObject().put("token", token)) }
                }
            } catch (failure: Exception) {
                // A stale editor must never overwrite a newer subscription. The
                // authoritative source remains intact if validation/CAS fails.
                GlobalState.log("Document save rejected: ${failure.message}")
            } finally { temporary.delete() }
        }
    }
}
