package com.mrhakan.ftportal

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

object TrackedPeerOfferReceiver {
    fun downloadAll(context: Context, offer: IncomingPeerOffer, destinationTree: Uri, completion: (PeerReceiveReport) -> Unit) {
        Thread {
            val completed = mutableListOf<String>()
            val failures = mutableListOf<String>()
            val directory = DocumentFile.fromTreeUri(context, destinationTree)
            if (directory == null || !directory.canWrite()) {
                completion(PeerReceiveReport(emptyList(), listOf("Selected folder is not writable")))
                return@Thread
            }
            offer.files.forEach { file ->
                val transferId = TransferCenter.begin(context, TransferDirection.RECEIVE, file.name, offer.senderAlias, file.size)
                var target: DocumentFile? = null
                var connection: HttpURLConnection? = null
                var settled = false
                try {
                    val name = file.name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\r\\n]"), "_").ifBlank { "FTPortal-download" }
                    target = directory.createFile(file.mime.ifBlank { "application/octet-stream" }, name)
                        ?: throw IOException("Could not create $name")
                    connection = (URL("http://${offer.host}:${offer.peerPort}${PeerProtocol.TRANSFER_PREFIX_V2}${offer.offerId}/${file.id}").openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 3000
                        readTimeout = 60_000
                        instanceFollowRedirects = false
                        useCaches = false
                        setRequestProperty("Authorization", "Bearer ${offer.token}")
                        setRequestProperty("X-FTPortal-Client", PeerProtocol.VERSION_V2)
                    }
                    if (connection.responseCode != HttpURLConnection.HTTP_OK) throw IOException("${file.name}: peer rejected the transfer")
                    val output = context.contentResolver.openOutputStream(target.uri, "w") ?: throw IOException("Could not open destination")
                    var received = 0L
                    connection.inputStream.use { input ->
                        output.use { out ->
                            val buffer = ByteArray(128 * 1024)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                out.write(buffer, 0, count)
                                received += count
                                TransferCenter.update(transferId, received)
                            }
                            out.flush()
                        }
                    }
                    if (file.size >= 0 && received != file.size) throw IOException("Expected ${file.size} bytes, received $received")
                    PeerOfferStore.markIncomingFileComplete(offer.offerId, file.id)
                    TransferCenter.finish(context, transferId, true)
                    settled = true
                    completed += file.name
                } catch (error: Exception) {
                    target?.delete()
                    val message = error.message ?: "${file.name}: transfer failed"
                    TransferCenter.finish(context, transferId, false, message)
                    settled = true
                    failures += message
                } finally {
                    if (!settled) TransferCenter.finish(context, transferId, false, "Transfer interrupted")
                    connection?.disconnect()
                }
            }
            completion(PeerReceiveReport(completed, failures))
        }.start()
    }
}
