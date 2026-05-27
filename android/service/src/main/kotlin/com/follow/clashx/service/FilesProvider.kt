package com.follow.clashx.service

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import com.follow.clashx.common.GlobalState
import java.io.File

class FilesProvider : DocumentsProvider() {

    private val defaultRootColumns = arrayOf(
        DocumentsContract.Root.COLUMN_ROOT_ID,
        DocumentsContract.Root.COLUMN_MIME_TYPES,
        DocumentsContract.Root.COLUMN_FLAGS,
        DocumentsContract.Root.COLUMN_ICON,
        DocumentsContract.Root.COLUMN_TITLE,
        DocumentsContract.Root.COLUMN_SUMMARY,
        DocumentsContract.Root.COLUMN_DOCUMENT_ID,
        DocumentsContract.Root.COLUMN_AVAILABLE_BYTES,
    )

    private val defaultDocumentColumns = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_FLAGS,
        DocumentsContract.Document.COLUMN_SIZE,
    )

    private val rootDir: File
        get() = GlobalState.application.filesDir

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: defaultRootColumns)
        cursor.newRow().apply {
            add(DocumentsContract.Root.COLUMN_ROOT_ID, "flclashx")
            add(DocumentsContract.Root.COLUMN_FLAGS, DocumentsContract.Root.FLAG_LOCAL_ONLY)
            add(DocumentsContract.Root.COLUMN_TITLE, "FlClashX")
            add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, docIdOf(rootDir))
            add(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES, rootDir.usableSpace)
        }
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentColumns)
        includeFile(cursor, fileOf(documentId))
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentColumns)
        fileOf(parentDocumentId).listFiles()?.forEach { includeFile(cursor, it) }
        return cursor
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        return ParcelFileDescriptor.open(fileOf(documentId), ParcelFileDescriptor.parseMode(mode))
    }

    private fun docIdOf(file: File): String = file.absolutePath

    private fun fileOf(docId: String): File {
        val file = File(docId).canonicalFile
        val root = rootDir.canonicalFile
        require(file.path.startsWith(root.path + File.separator) || file == root) {
            "Path outside root directory"
        }
        return file
    }

    private fun includeFile(cursor: MatrixCursor, file: File) {
        val mime = if (file.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream"
        var flags = 0
        if (file.isDirectory && file.canWrite()) flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
        if (file.canWrite()) flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        cursor.newRow().apply {
            add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, docIdOf(file))
            add(DocumentsContract.Document.COLUMN_MIME_TYPE, mime)
            add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, file.name)
            add(DocumentsContract.Document.COLUMN_LAST_MODIFIED, file.lastModified())
            add(DocumentsContract.Document.COLUMN_FLAGS, flags)
            add(DocumentsContract.Document.COLUMN_SIZE, if (file.isFile) file.length() else 0L)
        }
    }
}
