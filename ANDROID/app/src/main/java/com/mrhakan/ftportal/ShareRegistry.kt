package com.mrhakan.ftportal

import android.net.Uri
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

data class SharedFile(
    val id: String,
    val uri: Uri,
    val name: String,
    val mime: String,
    val size: Long
)

object ShareRegistry {
    private val files = ConcurrentHashMap<String, SharedFile>()

    fun add(uri: Uri, name: String, mime: String, size: Long): SharedFile {
        val file = SharedFile(UUID.randomUUID().toString().replace("-", ""), uri, name, mime, size)
        files[file.id] = file
        return file
    }

    fun get(id: String): SharedFile? = files[id]
    fun all(): List<SharedFile> = files.values.sortedBy { it.name.lowercase() }
    fun consume(id: String) { files.remove(id) }
    fun clear() { files.clear() }
}
