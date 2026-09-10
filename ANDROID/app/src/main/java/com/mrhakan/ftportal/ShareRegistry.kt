package com.mrhakan.ftportal

import android.content.Context
import android.content.Intent
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Process-safe share metadata for the Android host.
 * The source file itself is never copied into FTPortal storage.
 */
object ShareRegistry {
    private const val PREFS = "ftportal_shares"
    private const val KEY_ENTRIES = "entries"

    private val lock = Any()
    private val files = LinkedHashMap<String, SharedFile>()
    private val claimed = HashSet<String>()
    private var appContext: Context? = null
    @Volatile private var initialized = false

    fun initialize(context: Context) {
        if (initialized) return
        synchronized(lock) {
            if (initialized) return
            val applicationContext = context.applicationContext
            appContext = applicationContext
            val prefs = applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val raw = prefs.getString(KEY_ENTRIES, null)
            if (!raw.isNullOrBlank()) {
                runCatching {
                    val array = JSONArray(raw)
                    for (index in 0 until array.length()) {
                        val item = array.getJSONObject(index)
                        val file = SharedFile(
                            id = item.getString("id"),
                            uri = Uri.parse(item.getString("uri")),
                            name = item.getString("name"),
                            mime = item.optString("mime", "application/octet-stream"),
                            size = item.optLong("size", -1L)
                        )
                        files[file.id] = file
                    }
                }.onFailure {
                    files.clear()
                    prefs.edit().remove(KEY_ENTRIES).commit()
                }
            }
            initialized = true
        }
    }

    fun add(uri: Uri, name: String, mime: String, size: Long): SharedFile = synchronized(lock) {
        ensureInitialized()
        val file = SharedFile(UUID.randomUUID().toString().replace("-", ""), uri, name, mime, size)
        files[file.id] = file
        persistLocked()
        file
    }

    /** Atomically reserves a one-shot share for exactly one active transfer. */
    fun claim(id: String): SharedFile? = synchronized(lock) {
        ensureInitialized()
        val file = files[id] ?: return@synchronized null
        if (!claimed.add(id)) return@synchronized null
        file
    }

    /** Makes an interrupted/failed one-shot transfer available again. */
    fun release(id: String) {
        synchronized(lock) { claimed.remove(id) }
    }

    /** Claimed files are hidden from discovery until completed or released. */
    fun all(): List<SharedFile> = synchronized(lock) {
        ensureInitialized()
        files.values
            .filterNot { claimed.contains(it.id) }
            .sortedBy { it.name.lowercase() }
    }

    fun consume(id: String) = remove(id)

    fun remove(id: String) {
        var removed: SharedFile? = null
        var releasePermission = false
        var context: Context? = null
        synchronized(lock) {
            ensureInitialized()
            claimed.remove(id)
            removed = files.remove(id)
            if (removed != null) {
                releasePermission = files.values.none { it.uri == removed!!.uri }
                persistLocked()
                context = appContext
            }
        }
        if (releasePermission && context != null && removed != null) {
            releasePermission(context!!, removed!!.uri)
        }
    }

    /** Removes only idle/pending shares. Active transfer claims are left untouched. */
    fun clearPending() {
        val removed: List<SharedFile>
        val releasableUris: List<Uri>
        val context: Context?
        synchronized(lock) {
            ensureInitialized()
            val pendingIds = files.keys.filterNot { claimed.contains(it) }
            removed = pendingIds.mapNotNull { files.remove(it) }
            val remainingUris = files.values.map { it.uri }.toSet()
            releasableUris = removed.map { it.uri }.distinct().filterNot { remainingUris.contains(it) }
            if (removed.isNotEmpty()) persistLocked()
            context = appContext
        }
        if (context != null) releasableUris.forEach { releasePermission(context, it) }
    }

    private fun persistLocked() {
        val context = appContext ?: return
        val array = JSONArray()
        files.values.forEach { file ->
            array.put(
                JSONObject()
                    .put("id", file.id)
                    .put("uri", file.uri.toString())
                    .put("name", file.name)
                    .put("mime", file.mime)
                    .put("size", file.size)
            )
        }
        // Keep one-shot consumption durable before the persisted URI grant is released.
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_ENTRIES, array.toString())
            .commit()
    }

    private fun releasePermission(context: Context, uri: Uri) {
        runCatching {
            context.contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun ensureInitialized() {
        check(initialized) { "ShareRegistry.initialize(context) must be called before use" }
    }
}

data class SharedFile(
    val id: String,
    val uri: Uri,
    val name: String,
    val mime: String,
    val size: Long
)
