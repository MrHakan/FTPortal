package com.mrhakan.ftportal

import android.content.Context
import fi.iki.elonen.NanoHTTPD
import java.io.FilterInputStream
import java.io.InputStream
import java.net.URLDecoder

class PortalServer(private val context: Context, port: Int) : NanoHTTPD(port) {
    override fun serve(session: IHTTPSession): Response {
        val raw = URLDecoder.decode(session.uri, "UTF-8")
        return when {
            raw == "/" -> newFixedLengthResponse(Response.Status.OK, "text/html; charset=utf-8", html())
            raw == "/api/state" -> newFixedLengthResponse(Response.Status.OK, "application/json", stateJson())
            raw.startsWith("/download/") -> download(raw.removePrefix("/download/"))
            else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "Not found")
        }.apply { addHeader("Cache-Control", "no-store") }
    }

    private fun download(id: String): Response {
        val entry = ShareRegistry.get(id)
            ?: return newFixedLengthResponse(Response.Status.GONE, "text/plain", "Share already consumed or unavailable")
        val source = context.contentResolver.openInputStream(entry.uri)
            ?: return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "Source file unavailable")
        val tracked = CompletionInputStream(source, entry.size) { ShareRegistry.consume(entry.id) }
        val response = if (entry.size >= 0) {
            newFixedLengthResponse(Response.Status.OK, entry.mime, tracked, entry.size)
        } else {
            newChunkedResponse(Response.Status.OK, entry.mime, tracked)
        }
        response.addHeader("Content-Disposition", "attachment; filename=\"${entry.name.replace("\"", "'")}\"")
        response.addHeader("X-FTPortal-One-Shot", "true")
        return response
    }

    private fun stateJson(): String = ShareRegistry.all().joinToString(prefix = "{\"files\":[", postfix = "]}") {
        "{\"id\":\"${esc(it.id)}\",\"name\":\"${esc(it.name)}\",\"size\":${it.size}}"
    }

    private fun html(): String {
        val rows = ShareRegistry.all().joinToString("\n") {
            "<a class='file' href='/download/${it.id}'><b>${htmlEsc(it.name)}</b><span>${if (it.size >= 0) "${it.size} bytes" else "stream"}</span></a>"
        }.ifBlank { "<p class='empty'>No file is currently shared.</p>" }
        return """<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='refresh' content='4'><title>FTPortal Android</title><style>body{font-family:sans-serif;background:#0d1117;color:#e6edf3;max-width:720px;margin:50px auto;padding:20px}.file{display:flex;justify-content:space-between;padding:18px;margin:10px 0;border:1px solid #30363d;border-radius:12px;color:#58a6ff;text-decoration:none;background:#161b22}.file span,.empty{color:#8b949e}h1{margin-bottom:4px}</style></head><body><h1>FTPortal</h1><p>Android one-shot host · download consumes the share.</p>$rows</body></html>"""
    }

    private fun esc(value: String) = value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
    private fun htmlEsc(value: String) = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}

private class CompletionInputStream(
    source: InputStream,
    private val expected: Long,
    private val completed: () -> Unit
) : FilterInputStream(source) {
    private var transferred = 0L
    private var fired = false

    override fun read(): Int {
        val value = super.read()
        if (value >= 0) transferred++ else finishIfComplete()
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val count = super.read(buffer, offset, length)
        if (count > 0) transferred += count else if (count < 0) finishIfComplete()
        return count
    }

    override fun close() {
        if (expected >= 0 && transferred >= expected) finishIfComplete()
        super.close()
    }

    private fun finishIfComplete() {
        if (!fired && (expected < 0 || transferred >= expected)) {
            fired = true
            completed()
        }
    }
}
