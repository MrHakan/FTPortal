package com.mrhakan.ftportal

import android.content.Context
import android.net.Uri
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.FilterInputStream
import java.io.InputStream

class PortalServer(private val context: Context, port: Int) : NanoHTTPD(port) {
    override fun serve(session: IHTTPSession): Response {
        val path = runCatching { Uri.decode(session.uri) }.getOrDefault(session.uri)
        val peer = session.remoteIpAddress.orEmpty().ifBlank { "Web/local peer" }
        val response = when {
            session.method == Method.GET && path == "/" -> newFixedLengthResponse(Response.Status.OK, "text/html; charset=utf-8", html())
            session.method == Method.GET && path == "/api/state" -> newFixedLengthResponse(Response.Status.OK, "application/json; charset=utf-8", stateJson())
            session.method == Method.GET && path == PeerProtocol.INFO_PATH_V1 -> newFixedLengthResponse(
                Response.Status.OK, "application/json; charset=utf-8", PeerProtocol.infoJson(context, PortalService.PORT, PeerProtocol.VERSION_V1)
            ).apply { addHeader("X-FTPortal-Protocol", PeerProtocol.VERSION_V1) }
            session.method == Method.GET && path == PeerProtocol.INFO_PATH_V2 -> newFixedLengthResponse(
                Response.Status.OK, "application/json; charset=utf-8", PeerProtocol.infoJson(context, PortalService.PORT, PeerProtocol.VERSION_V2)
            ).apply { addHeader("X-FTPortal-Protocol", PeerProtocol.VERSION_V2) }
            session.method == Method.POST && path == PeerProtocol.OFFER_PATH_V2 -> receiveOffer(session)
            session.method == Method.GET && path.startsWith(PeerProtocol.TRANSFER_PREFIX_V2) -> offeredDownload(session, path.removePrefix(PeerProtocol.TRANSFER_PREFIX_V2), peer)
            session.method == Method.GET && path.startsWith(PeerProtocol.DOWNLOAD_PREFIX_V1) -> download(path.removePrefix(PeerProtocol.DOWNLOAD_PREFIX_V1), PeerProtocol.VERSION_V1, peer)
            session.method == Method.GET && path.startsWith("/download/") -> download(path.removePrefix("/download/"), null, peer)
            session.method != Method.GET && session.method != Method.POST -> newFixedLengthResponse(Response.Status.METHOD_NOT_ALLOWED, "text/plain; charset=utf-8", "GET or POST only").apply { addHeader("Allow", "GET, POST") }
            else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain; charset=utf-8", "Not found")
        }
        return commonHeaders(response)
    }

    private fun receiveOffer(session: IHTTPSession): Response {
        val contentLength = session.headers["content-length"]?.toLongOrNull() ?: 0L
        if (contentLength > 128 * 1024) return newFixedLengthResponse(Response.Status.PAYLOAD_TOO_LARGE, "text/plain; charset=utf-8", "Offer payload too large")
        val bodyFiles = HashMap<String, String>()
        val parsed = runCatching { session.parseBody(bodyFiles); bodyFiles["postData"].orEmpty() }.getOrNull()
            ?: return newFixedLengthResponse(Response.Status.BAD_REQUEST, "text/plain; charset=utf-8", "Could not parse offer")
        if (parsed.length > 128 * 1024) return newFixedLengthResponse(Response.Status.PAYLOAD_TOO_LARGE, "text/plain; charset=utf-8", "Offer payload too large")
        val offer = PeerOfferStore.receiveIncoming(context, session.remoteIpAddress.orEmpty(), parsed)
            ?: return newFixedLengthResponse(Response.Status.BAD_REQUEST, "text/plain; charset=utf-8", "Invalid or expired offer")
        val result = JSONObject().put("offerId", offer.offerId).put("status", "pending").put("expiresAt", offer.expiresAt).toString()
        return newFixedLengthResponse(Response.Status.OK, "application/json; charset=utf-8", result).apply { addHeader("X-FTPortal-Protocol", PeerProtocol.VERSION_V2) }
    }

    private fun offeredDownload(session: IHTTPSession, remainder: String, peer: String): Response {
        val parts = remainder.split('/', limit = 2)
        if (parts.size != 2) return newFixedLengthResponse(Response.Status.BAD_REQUEST, "text/plain; charset=utf-8", "Invalid transfer path")
        val offerId = parts[0]
        val fileId = parts[1]
        if (!PeerOfferStore.authorizeOutgoing(offerId, fileId, session.headers["authorization"])) {
            return newFixedLengthResponse(Response.Status.UNAUTHORIZED, "text/plain; charset=utf-8", "Offer authorization failed").apply { addHeader("WWW-Authenticate", "Bearer") }
        }
        return download(fileId, PeerProtocol.VERSION_V2, peer) { PeerOfferStore.completeOutgoingFile(offerId, fileId) }
    }

    private fun download(id: String, protocolHeader: String?, peer: String, onCompleted: (() -> Unit)? = null): Response {
        if (id.isBlank() || id.length > 64 || id.any { !it.isLetterOrDigit() }) return newFixedLengthResponse(Response.Status.BAD_REQUEST, "text/plain; charset=utf-8", "Invalid share id")
        val entry = ShareRegistry.claim(id)
            ?: return newFixedLengthResponse(Response.Status.GONE, "text/plain; charset=utf-8", "Share already consumed, busy, or unavailable")
        val source = runCatching { context.contentResolver.openInputStream(entry.uri) }.getOrNull()
        if (source == null) {
            ShareRegistry.release(entry.id)
            return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain; charset=utf-8", "Source file unavailable")
        }

        val transferId = TransferCenter.begin(context, TransferDirection.SEND, entry.name, peer, entry.size)
        val tracked = CompletionInputStream(
            source = source,
            expected = entry.size,
            onProgress = { bytes -> TransferCenter.update(transferId, bytes) },
            completed = {
                ShareRegistry.consume(entry.id)
                onCompleted?.invoke()
                TransferCenter.finish(context, transferId, true)
            },
            interrupted = {
                ShareRegistry.release(entry.id)
                TransferCenter.finish(context, transferId, false, "Connection interrupted")
            }
        )
        val response = if (entry.size >= 0) newFixedLengthResponse(Response.Status.OK, entry.mime, tracked, entry.size)
        else newChunkedResponse(Response.Status.OK, entry.mime, tracked)
        response.addHeader("Content-Disposition", "attachment; filename=\"download\"; filename*=UTF-8''${Uri.encode(entry.name)}")
        response.addHeader("X-FTPortal-One-Shot", "true")
        if (protocolHeader != null) response.addHeader("X-FTPortal-Protocol", protocolHeader)
        return response
    }

    private fun stateJson(): String {
        val files = JSONArray()
        ShareRegistry.all().forEach { file ->
            files.put(JSONObject().put("id", file.id).put("name", file.name).put("size", file.size).put("mime", file.mime))
        }
        return JSONObject().put("files", files).toString()
    }

    private fun html(): String {
        val rows = ShareRegistry.all().joinToString("\n") {
            "<a class='file' href='/download/${it.id}'><b>${htmlEsc(it.name)}</b><span>${if (it.size >= 0) "${it.size} bytes" else "stream"}</span></a>"
        }.ifBlank { "<p class='empty'>No file is currently shared.</p>" }
        return """<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='refresh' content='4'><title>FTPortal Android</title><style>body{font-family:sans-serif;background:#0d1117;color:#e6edf3;max-width:720px;margin:50px auto;padding:20px}.file{display:flex;justify-content:space-between;padding:18px;margin:10px 0;border:1px solid #30363d;border-radius:12px;color:#58a6ff;text-decoration:none;background:#161b22}.file span,.empty{color:#8b949e}h1{margin-bottom:4px}</style></head><body><h1>FTPortal</h1><p>Android one-shot host · completed downloads consume the share.</p>$rows</body></html>"""
    }

    private fun commonHeaders(response: Response): Response = response.apply {
        addHeader("Cache-Control", "no-store")
        addHeader("X-Content-Type-Options", "nosniff")
        addHeader("Referrer-Policy", "no-referrer")
        addHeader("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'")
    }

    private fun htmlEsc(value: String) = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;")
}

private class CompletionInputStream(
    source: InputStream,
    private val expected: Long,
    private val onProgress: (Long) -> Unit,
    private val completed: () -> Unit,
    private val interrupted: () -> Unit
) : FilterInputStream(source) {
    private var transferred = 0L
    private var reachedEof = false
    private var settled = false

    override fun read(): Int {
        val value = super.read()
        if (value >= 0) { transferred++; onProgress(transferred) } else { reachedEof = true; settleIfComplete() }
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val count = super.read(buffer, offset, length)
        if (count > 0) { transferred += count; onProgress(transferred) }
        else if (count < 0) { reachedEof = true; settleIfComplete() }
        return count
    }

    override fun close() {
        if (!settled) {
            val complete = if (expected >= 0) transferred >= expected else reachedEof
            settled = true
            if (complete) completed() else interrupted()
        }
        super.close()
    }

    private fun settleIfComplete() {
        if (settled) return
        val complete = if (expected >= 0) transferred >= expected else reachedEof
        if (complete) { settled = true; completed() }
    }
}
