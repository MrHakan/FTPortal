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
        if (session.method != Method.GET) {
            return commonHeaders(
                newFixedLengthResponse(Response.Status.METHOD_NOT_ALLOWED, "text/plain; charset=utf-8", "GET only")
            ).apply { addHeader("Allow", "GET") }
        }

        val path = runCatching { Uri.decode(session.uri) }.getOrDefault(session.uri)
        val response = when {
            path == "/" -> newFixedLengthResponse(Response.Status.OK, "text/html; charset=utf-8", html())
            path == "/api/state" -> newFixedLengthResponse(Response.Status.OK, "application/json; charset=utf-8", stateJson())
            path.startsWith("/download/") -> download(path.removePrefix("/download/"))
            else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain; charset=utf-8", "Not found")
        }
        return commonHeaders(response)
    }

    private fun download(id: String): Response {
        val entry = ShareRegistry.claim(id)
            ?: return newFixedLengthResponse(Response.Status.GONE, "text/plain; charset=utf-8", "Share already consumed, busy, or unavailable")

        val source = runCatching { context.contentResolver.openInputStream(entry.uri) }.getOrNull()
        if (source == null) {
            ShareRegistry.release(entry.id)
            return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain; charset=utf-8", "Source file unavailable")
        }

        val tracked = CompletionInputStream(
            source = source,
            expected = entry.size,
            completed = { ShareRegistry.consume(entry.id) },
            interrupted = { ShareRegistry.release(entry.id) }
        )
        val response = if (entry.size >= 0) {
            newFixedLengthResponse(Response.Status.OK, entry.mime, tracked, entry.size)
        } else {
            newChunkedResponse(Response.Status.OK, entry.mime, tracked)
        }
        response.addHeader(
            "Content-Disposition",
            "attachment; filename=\"download\"; filename*=UTF-8''${Uri.encode(entry.name)}"
        )
        response.addHeader("X-FTPortal-One-Shot", "true")
        return response
    }

    private fun stateJson(): String {
        val files = JSONArray()
        ShareRegistry.all().forEach { file ->
            files.put(
                JSONObject()
                    .put("id", file.id)
                    .put("name", file.name)
                    .put("size", file.size)
                    .put("mime", file.mime)
            )
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

    private fun htmlEsc(value: String) = value
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&#39;")
}

private class CompletionInputStream(
    source: InputStream,
    private val expected: Long,
    private val completed: () -> Unit,
    private val interrupted: () -> Unit
) : FilterInputStream(source) {
    private var transferred = 0L
    private var reachedEof = false
    private var settled = false

    override fun read(): Int {
        val value = super.read()
        if (value >= 0) {
            transferred++
        } else {
            reachedEof = true
            settleIfComplete()
        }
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val count = super.read(buffer, offset, length)
        if (count > 0) {
            transferred += count
        } else if (count < 0) {
            reachedEof = true
            settleIfComplete()
        }
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
        if (complete) {
            settled = true
            completed()
        }
    }
}
