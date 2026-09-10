package com.mrhakan.ftportal

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.max
import kotlin.math.min

enum class TransferDirection { SEND, RECEIVE }

data class TransferSnapshot(
    val id: String,
    val direction: TransferDirection,
    val fileName: String,
    val peer: String,
    val bytesTransferred: Long,
    val totalBytes: Long,
    val progressPercent: Int?,
    val bytesPerSecond: Double,
    val etaSeconds: Long?,
    val startedAt: Long
)

data class TransferHistoryEntry(
    val id: String,
    val direction: TransferDirection,
    val fileName: String,
    val peer: String,
    val bytesTransferred: Long,
    val totalBytes: Long,
    val startedAt: Long,
    val finishedAt: Long,
    val success: Boolean,
    val detail: String?
)

private data class MutableTransfer(
    val id: String,
    val direction: TransferDirection,
    val fileName: String,
    val peer: String,
    val totalBytes: Long,
    val startedAt: Long,
    var bytesTransferred: Long = 0L,
    var lastSampleAt: Long = startedAt,
    var lastSampleBytes: Long = 0L,
    var smoothedBytesPerSecond: Double = 0.0
)

object TransferCenter {
    private const val PREFS = "ftportal-transfer-history"
    private const val KEY_HISTORY = "history"
    private const val MAX_HISTORY = 100

    private val active = ConcurrentHashMap<String, MutableTransfer>()
    private val historyLock = Any()
    @Volatile private var cachedHistory: MutableList<TransferHistoryEntry>? = null

    fun initialize(context: Context) {
        if (cachedHistory != null) return
        synchronized(historyLock) {
            if (cachedHistory == null) cachedHistory = loadHistory(context.applicationContext)
        }
    }

    fun begin(
        context: Context,
        direction: TransferDirection,
        fileName: String,
        peer: String,
        totalBytes: Long
    ): String {
        initialize(context)
        val id = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        active[id] = MutableTransfer(
            id = id,
            direction = direction,
            fileName = fileName.ifBlank { "Unnamed file" },
            peer = peer.ifBlank { "Local network peer" },
            totalBytes = totalBytes,
            startedAt = now
        )
        return id
    }

    fun update(id: String, absoluteBytes: Long) {
        val transfer = active[id] ?: return
        val now = System.currentTimeMillis()
        synchronized(transfer) {
            val bytes = max(0L, absoluteBytes)
            val deltaBytes = bytes - transfer.lastSampleBytes
            val deltaMs = now - transfer.lastSampleAt
            transfer.bytesTransferred = bytes
            if (deltaBytes >= 0L && deltaMs >= 180L) {
                val instant = deltaBytes.toDouble() * 1000.0 / deltaMs.toDouble()
                transfer.smoothedBytesPerSecond = if (transfer.smoothedBytesPerSecond <= 0.0) {
                    instant
                } else {
                    transfer.smoothedBytesPerSecond * 0.72 + instant * 0.28
                }
                transfer.lastSampleAt = now
                transfer.lastSampleBytes = bytes
            }
        }
    }

    fun finish(context: Context, id: String, success: Boolean, detail: String? = null) {
        initialize(context)
        val transfer = active.remove(id) ?: return
        val snapshot = synchronized(transfer) {
            TransferHistoryEntry(
                id = transfer.id,
                direction = transfer.direction,
                fileName = transfer.fileName,
                peer = transfer.peer,
                bytesTransferred = transfer.bytesTransferred,
                totalBytes = transfer.totalBytes,
                startedAt = transfer.startedAt,
                finishedAt = System.currentTimeMillis(),
                success = success,
                detail = detail?.take(240)
            )
        }
        synchronized(historyLock) {
            val history = cachedHistory ?: mutableListOf<TransferHistoryEntry>().also { cachedHistory = it }
            history.add(0, snapshot)
            while (history.size > MAX_HISTORY) history.removeAt(history.lastIndex)
            persistHistory(context.applicationContext, history)
        }
    }

    fun active(): List<TransferSnapshot> = active.values.map { transfer ->
        synchronized(transfer) {
            val total = transfer.totalBytes
            val bytes = transfer.bytesTransferred
            val speed = transfer.smoothedBytesPerSecond
            val percent = if (total > 0L) {
                ((min(bytes, total).toDouble() / total.toDouble()) * 100.0).toInt().coerceIn(0, 100)
            } else null
            val eta = if (total > 0L && speed > 1.0 && bytes < total) {
                ((total - bytes).toDouble() / speed).toLong().coerceAtLeast(0L)
            } else null
            TransferSnapshot(
                id = transfer.id,
                direction = transfer.direction,
                fileName = transfer.fileName,
                peer = transfer.peer,
                bytesTransferred = bytes,
                totalBytes = total,
                progressPercent = percent,
                bytesPerSecond = speed,
                etaSeconds = eta,
                startedAt = transfer.startedAt
            )
        }
    }.sortedBy { it.startedAt }

    fun history(context: Context): List<TransferHistoryEntry> {
        initialize(context)
        synchronized(historyLock) { return cachedHistory.orEmpty().toList() }
    }

    fun clearHistory(context: Context) {
        initialize(context)
        synchronized(historyLock) {
            cachedHistory?.clear()
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().remove(KEY_HISTORY).apply()
        }
    }

    private fun loadHistory(context: Context): MutableList<TransferHistoryEntry> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_HISTORY, null)
            ?: return mutableListOf()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return mutableListOf()
        val result = mutableListOf<TransferHistoryEntry>()
        for (index in 0 until min(array.length(), MAX_HISTORY)) {
            val item = array.optJSONObject(index) ?: continue
            val direction = runCatching { TransferDirection.valueOf(item.optString("direction")) }.getOrNull() ?: continue
            result += TransferHistoryEntry(
                id = item.optString("id").ifBlank { UUID.randomUUID().toString() },
                direction = direction,
                fileName = item.optString("fileName").ifBlank { "Unnamed file" },
                peer = item.optString("peer").ifBlank { "Local network peer" },
                bytesTransferred = item.optLong("bytesTransferred", 0L),
                totalBytes = item.optLong("totalBytes", -1L),
                startedAt = item.optLong("startedAt", 0L),
                finishedAt = item.optLong("finishedAt", 0L),
                success = item.optBoolean("success", false),
                detail = item.optString("detail").takeIf { it.isNotBlank() }
            )
        }
        return result
    }

    private fun persistHistory(context: Context, history: List<TransferHistoryEntry>) {
        val array = JSONArray()
        history.take(MAX_HISTORY).forEach { entry ->
            array.put(
                JSONObject()
                    .put("id", entry.id)
                    .put("direction", entry.direction.name)
                    .put("fileName", entry.fileName)
                    .put("peer", entry.peer)
                    .put("bytesTransferred", entry.bytesTransferred)
                    .put("totalBytes", entry.totalBytes)
                    .put("startedAt", entry.startedAt)
                    .put("finishedAt", entry.finishedAt)
                    .put("success", entry.success)
                    .put("detail", entry.detail ?: "")
            )
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_HISTORY, array.toString()).apply()
    }
}
