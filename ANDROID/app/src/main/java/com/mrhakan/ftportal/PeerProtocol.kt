package com.mrhakan.ftportal

import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

data class PeerRemoteFile(
    val id: String,
    val name: String,
    val size: Long,
    val mime: String
)

data class PeerLobby(
    val deviceId: String,
    val lobbyId: String,
    val alias: String,
    val platform: String,
    val host: String,
    val peerPort: Int,
    val legacyPort: Int,
    val files: List<PeerRemoteFile>
)

object PeerIdentity {
    private const val PREFS = "ftportal_peer"
    private const val DEVICE_ID = "device_id"

    fun deviceId(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val existing = prefs.getString(DEVICE_ID, null)
        if (!existing.isNullOrBlank()) return existing
        val created = UUID.randomUUID().toString().replace("-", "")
        prefs.edit().putString(DEVICE_ID, created).commit()
        return created
    }

    fun alias(): String {
        val manufacturer = Build.MANUFACTURER.orEmpty().trim()
        val model = Build.MODEL.orEmpty().trim()
        return listOf(manufacturer, model)
            .filter { it.isNotBlank() }
            .joinToString(" ")
            .ifBlank { "Android device" }
    }
}

object PeerProtocol {
    const val VERSION = "ftportal/1"
    const val PEER_PORT = 47171
    const val INFO_PATH = "/api/ftportal/v1/info"
    const val DOWNLOAD_PREFIX = "/api/ftportal/v1/download/"

    fun infoJson(context: Context, legacyPort: Int): String {
        val files = ShareRegistry.all()
        val deviceId = PeerIdentity.deviceId(context)
        val payload = JSONObject()
            .put("protocol", VERSION)
            .put("deviceId", deviceId)
            .put("lobbyId", "lobby-$deviceId")
            .put("alias", PeerIdentity.alias())
            .put("platform", "Android")
            .put("peerPort", PEER_PORT)
            .put("legacyPort", legacyPort)
            .put("lobbyActive", files.isNotEmpty())
            .put("fileCount", files.size)

        val manifest = JSONArray()
        files.forEach { file ->
            manifest.put(
                JSONObject()
                    .put("id", file.id)
                    .put("name", file.name)
                    .put("size", file.size)
                    .put("mime", file.mime)
            )
        }
        payload.put("files", manifest)
        return payload.toString()
    }

    fun parseLobby(host: String, body: String): PeerLobby? = runCatching {
        val json = JSONObject(body)
        if (json.optString("protocol") != VERSION || !json.optBoolean("lobbyActive", false)) return@runCatching null

        val filesJson = json.optJSONArray("files") ?: JSONArray()
        val files = buildList {
            for (index in 0 until filesJson.length()) {
                val file = filesJson.optJSONObject(index) ?: continue
                val id = file.optString("id")
                val name = file.optString("name")
                if (id.isBlank() || name.isBlank()) continue
                add(
                    PeerRemoteFile(
                        id = id,
                        name = name,
                        size = file.optLong("size", -1L),
                        mime = file.optString("mime", "application/octet-stream")
                    )
                )
            }
        }
        if (files.isEmpty()) return@runCatching null

        PeerLobby(
            deviceId = json.getString("deviceId"),
            lobbyId = json.optString("lobbyId", "lobby-${json.getString("deviceId")}"),
            alias = json.optString("alias", host),
            platform = json.optString("platform", "Unknown"),
            host = host,
            peerPort = json.optInt("peerPort", PEER_PORT),
            legacyPort = json.optInt("legacyPort", 0),
            files = files
        )
    }.getOrNull()
}

object PeerDiscovery {
    fun discover(context: Context, completion: (List<PeerLobby>) -> Unit) {
        val ownAddresses = NetworkUrls.ipv4Addresses().toSet()
        val candidates = linkedSetOf<String>()
        ownAddresses.forEach { address ->
            val parts = address.split('.')
            if (parts.size != 4) return@forEach
            val prefix = parts.take(3).joinToString(".")
            for (last in 1..254) {
                val candidate = "$prefix.$last"
                if (candidate !in ownAddresses) candidates += candidate
            }
        }

        if (candidates.isEmpty()) {
            completion(emptyList())
            return
        }

        val ownId = PeerIdentity.deviceId(context)
        val results = ConcurrentHashMap<String, PeerLobby>()
        val remaining = AtomicInteger(candidates.size)
        val pool = Executors.newFixedThreadPool(32)

        candidates.forEach { host ->
            pool.execute {
                try {
                    val lobby = probe(host)
                    if (lobby != null && lobby.deviceId != ownId) {
                        results.putIfAbsent(lobby.deviceId, lobby)
                    }
                } finally {
                    if (remaining.decrementAndGet() == 0) {
                        pool.shutdown()
                        completion(results.values.sortedBy { it.alias.lowercase() })
                    }
                }
            }
        }
    }

    private fun probe(host: String): PeerLobby? = runCatching {
        val connection = (URL("http://$host:${PeerProtocol.PEER_PORT}${PeerProtocol.INFO_PATH}").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 350
            readTimeout = 700
            instanceFollowRedirects = false
            useCaches = false
            setRequestProperty("Accept", "application/json")
            setRequestProperty("X-FTPortal-Client", PeerProtocol.VERSION)
        }
        try {
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return@runCatching null
            val body = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            PeerProtocol.parseLobby(host, body)
        } finally {
            connection.disconnect()
        }
    }.getOrNull()
}
