package com.mrhakan.ftportal

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap

data class PeerOfferFile(
    val id: String,
    val name: String,
    val size: Long,
    val mime: String
)

data class IncomingPeerOffer(
    val offerId: String,
    val senderDeviceId: String,
    val senderAlias: String,
    val senderPlatform: String,
    val host: String,
    val peerPort: Int,
    val token: String,
    val verificationCode: String,
    val expiresAt: Long,
    val files: List<PeerOfferFile>
)

data class PreparedPeerOffer(
    val offerId: String,
    val token: String,
    val verificationCode: String,
    val expiresAt: Long,
    val files: List<PeerOfferFile>
)

data class PeerReceiveReport(
    val completed: List<String>,
    val failures: List<String>
)

private data class OutgoingPeerGrant(
    val token: String,
    val expiresAt: Long,
    val fileIds: MutableSet<String>
)

object PeerOfferStore {
    private const val OFFER_TTL_MS = 5 * 60 * 1000L
    private const val MAX_CLOCK_WINDOW_MS = 10 * 60 * 1000L
    private const val MAX_INCOMING_OFFERS = 20
    private const val MAX_FILES_PER_OFFER = 128

    private val incoming = ConcurrentHashMap<String, IncomingPeerOffer>()
    private val outgoing = ConcurrentHashMap<String, OutgoingPeerGrant>()
    private val random = SecureRandom()

    fun prepareOutgoing(files: List<SharedFile>): PreparedPeerOffer {
        require(files.isNotEmpty()) { "No pending files to offer" }
        require(files.size <= MAX_FILES_PER_OFFER) { "Too many files in one offer" }
        require(files.all { it.size >= 0 }) { "All v2 offer files must have a known size" }
        cleanup()

        val offerId = randomHex(16)
        val token = randomHex(32)
        val verificationCode = random.nextInt(1_000_000).toString().padStart(6, '0')
        val expiresAt = System.currentTimeMillis() + OFFER_TTL_MS
        val manifest = files.map { PeerOfferFile(it.id, it.name, it.size, it.mime) }
        val fileIds = ConcurrentHashMap.newKeySet<String>().apply { addAll(manifest.map { it.id }) }
        outgoing[offerId] = OutgoingPeerGrant(token, expiresAt, fileIds)
        return PreparedPeerOffer(offerId, token, verificationCode, expiresAt, manifest)
    }

    fun cancelOutgoing(offerId: String) {
        outgoing.remove(offerId)
    }

    fun receiveIncoming(context: Context, remoteHost: String, body: String): IncomingPeerOffer? {
        cleanup()
        val json = runCatching { JSONObject(body) }.getOrNull() ?: return null
        if (json.optString("protocol") != PeerProtocol.VERSION_V2) return null

        val offerId = json.optString("offerId").lowercase()
        val token = json.optString("token").lowercase()
        val senderDeviceId = json.optString("senderDeviceId")
        val senderAlias = json.optString("senderAlias").take(120)
        val senderPlatform = json.optString("senderPlatform").take(40)
        val verificationCode = json.optString("verificationCode")
        val expiresAt = json.optLong("expiresAt", 0L)
        val peerPort = json.optInt("peerPort", PeerProtocol.PEER_PORT)
        val now = System.currentTimeMillis()

        if (!isHex(offerId, 32) || !isHex(token, 64)) return null
        if (senderDeviceId.isBlank() || senderDeviceId == PeerIdentity.deviceId(context)) return null
        if (!verificationCode.matches(Regex("^[0-9]{6}$"))) return null
        if (expiresAt <= now || expiresAt > now + MAX_CLOCK_WINDOW_MS) return null
        if (peerPort !in 1..65535 || remoteHost.isBlank()) return null

        val filesJson = json.optJSONArray("files") ?: return null
        if (filesJson.length() !in 1..MAX_FILES_PER_OFFER) return null
        val files = buildList {
            for (index in 0 until filesJson.length()) {
                val item = filesJson.optJSONObject(index) ?: continue
                val id = item.optString("id")
                val name = item.optString("name")
                val mime = item.optString("mime", "application/octet-stream").take(128)
                val size = item.optLong("size", -1L)
                if (id.isBlank() || id.length > 64 || id.any { !it.isLetterOrDigit() } || name.isBlank() || name.length > 255 || size < 0) continue
                add(PeerOfferFile(id, name, size, mime.ifBlank { "application/octet-stream" }))
            }
        }
        if (files.size != filesJson.length() || files.map { it.id.lowercase() }.toSet().size != files.size) return null

        if (incoming.size >= MAX_INCOMING_OFFERS && !incoming.containsKey(offerId)) return null
        val offer = IncomingPeerOffer(
            offerId = offerId,
            senderDeviceId = senderDeviceId,
            senderAlias = senderAlias.ifBlank { remoteHost },
            senderPlatform = senderPlatform.ifBlank { "Unknown" },
            host = remoteHost,
            peerPort = peerPort,
            token = token,
            verificationCode = verificationCode,
            expiresAt = expiresAt,
            files = files
        )
        incoming[offerId] = offer
        return offer
    }

    fun incoming(): List<IncomingPeerOffer> {
        cleanup()
        return incoming.values.sortedBy { it.senderAlias.lowercase() }
    }

    fun decline(offerId: String) {
        incoming.remove(offerId)
    }

    fun markIncomingFileComplete(offerId: String, fileId: String) {
        incoming.computeIfPresent(offerId) { _, offer ->
            val remaining = offer.files.filterNot { it.id == fileId }
            if (remaining.isEmpty()) null else offer.copy(files = remaining)
        }
    }

    fun authorizeOutgoing(offerId: String, fileId: String, authorization: String?): Boolean {
        cleanup()
        val grant = outgoing[offerId] ?: return false
        if (!grant.fileIds.contains(fileId)) return false
        val prefix = "Bearer "
        if (authorization == null || !authorization.startsWith(prefix, ignoreCase = true)) return false
        val supplied = authorization.substring(prefix.length).trim().lowercase()
        return MessageDigest.isEqual(grant.token.toByteArray(), supplied.toByteArray())
    }

    fun completeOutgoingFile(offerId: String, fileId: String) {
        val grant = outgoing[offerId] ?: return
        grant.fileIds.remove(fileId)
        if (grant.fileIds.isEmpty()) outgoing.remove(offerId, grant)
    }

    private fun cleanup() {
        val now = System.currentTimeMillis()
        incoming.entries.removeIf { it.value.expiresAt <= now }
        outgoing.entries.removeIf { it.value.expiresAt <= now || it.value.fileIds.isEmpty() }
    }

    private fun isHex(value: String, length: Int): Boolean =
        value.length == length && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

    private fun randomHex(bytes: Int): String {
        val data = ByteArray(bytes)
        random.nextBytes(data)
        return data.joinToString("") { "%02x".format(it) }
    }
}

object PeerOfferClient {
    fun send(context: Context, lobby: PeerLobby, files: List<SharedFile>): PreparedPeerOffer {
        require(lobby.supportsOffers) { "This lobby only supports the v1 pull flow" }
        val prepared = PeerOfferStore.prepareOutgoing(files)
        val payload = JSONObject()
            .put("protocol", PeerProtocol.VERSION_V2)
            .put("offerId", prepared.offerId)
            .put("senderDeviceId", PeerIdentity.deviceId(context))
            .put("senderAlias", PeerIdentity.alias())
            .put("senderPlatform", "Android")
            .put("peerPort", PeerProtocol.PEER_PORT)
            .put("token", prepared.token)
            .put("verificationCode", prepared.verificationCode)
            .put("expiresAt", prepared.expiresAt)
        val filesJson = JSONArray()
        prepared.files.forEach { file ->
            filesJson.put(
                JSONObject()
                    .put("id", file.id)
                    .put("name", file.name)
                    .put("size", file.size)
                    .put("mime", file.mime)
            )
        }
        payload.put("files", filesJson)

        var connection: HttpURLConnection? = null
        try {
            connection = (URL("http://${lobby.host}:${lobby.peerPort}${PeerProtocol.OFFER_PATH_V2}").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 3000
                readTimeout = 5000
                instanceFollowRedirects = false
                useCaches = false
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("Accept", "application/json")
                setRequestProperty("X-FTPortal-Client", PeerProtocol.VERSION_V2)
            }
            val bytes = payload.toString().toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            val code = connection.responseCode
            if (code !in 200..299) throw IOException("Peer rejected offer with HTTP $code")
            return prepared
        } catch (error: Exception) {
            PeerOfferStore.cancelOutgoing(prepared.offerId)
            throw error
        } finally {
            connection?.disconnect()
        }
    }
}

object PeerOfferReceiver {
    fun downloadAll(
        context: Context,
        offer: IncomingPeerOffer,
        destinationTree: Uri,
        completion: (PeerReceiveReport) -> Unit
    ) {
        Thread {
            val completed = mutableListOf<String>()
            val failures = mutableListOf<String>()
            val directory = DocumentFile.fromTreeUri(context, destinationTree)
            if (directory == null || !directory.canWrite()) {
                completion(PeerReceiveReport(emptyList(), listOf("Selected folder is not writable")))
                return@Thread
            }

            offer.files.forEach { file ->
                var target: DocumentFile? = null
                var connection: HttpURLConnection? = null
                try {
                    val name = safeFileName(file.name)
                    target = directory.createFile(file.mime.ifBlank { "application/octet-stream" }, name)
                        ?: throw IOException("Could not create $name")
                    connection = (URL(
                        "http://${offer.host}:${offer.peerPort}${PeerProtocol.TRANSFER_PREFIX_V2}${offer.offerId}/${file.id}"
                    ).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 3000
                        readTimeout = 60_000
                        instanceFollowRedirects = false
                        useCaches = false
                        setRequestProperty("Authorization", "Bearer ${offer.token}")
                        setRequestProperty("X-FTPortal-Client", PeerProtocol.VERSION_V2)
                    }
                    val code = connection.responseCode
                    if (code != HttpURLConnection.HTTP_OK) throw IOException("${file.name}: peer returned HTTP $code")

                    val output = context.contentResolver.openOutputStream(target.uri, "w")
                        ?: throw IOException("Could not open destination for ${file.name}")
                    var received = 0L
                    connection.inputStream.use { input ->
                        output.use { out ->
                            val buffer = ByteArray(128 * 1024)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                out.write(buffer, 0, count)
                                received += count
                            }
                            out.flush()
                        }
                    }
                    if (file.size >= 0 && received != file.size) {
                        throw IOException("${file.name}: expected ${file.size} bytes, received $received")
                    }
                    completed += file.name
                    PeerOfferStore.markIncomingFileComplete(offer.offerId, file.id)
                } catch (error: Exception) {
                    runCatching { target?.delete() }
                    failures += (error.message ?: "${file.name}: transfer failed")
                } finally {
                    connection?.disconnect()
                }
            }
            completion(PeerReceiveReport(completed, failures))
        }.start()
    }

    private fun safeFileName(name: String): String {
        val leaf = name.substringAfterLast('/').substringAfterLast('\\').trim()
        return leaf.replace(Regex("[\\r\\n]"), "_").ifBlank { "FTPortal-download" }
    }
}
