package com.mrhakan.ftportal

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.FilterInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.URLConnection

class PortalServer(private val context: Context, port: Int) : NanoHTTPD(port) {
    companion object {
        private const val MAX_UPLOAD_BYTES = 8L * 1024L * 1024L * 1024L
    }

    override fun serve(session: IHTTPSession): Response {
        val path = runCatching { Uri.decode(session.uri) }.getOrDefault(session.uri)
        val peer = session.remoteIpAddress.orEmpty().ifBlank { "Web/local peer" }
        if (!LocalNetworkGuard.isAllowed(session.remoteIpAddress.orEmpty())) {
            return commonHeaders(jsonError(Response.Status.FORBIDDEN, "Client is outside the active local network"))
        }
        val response = when {
            session.method == Method.GET && path in setOf("/", "/dashboard", "/lobby") -> newFixedLengthResponse(Response.Status.OK, "text/html; charset=utf-8", portalHtml())
            session.method == Method.GET && path == "/qr.js" -> newFixedLengthResponse(Response.Status.OK, "application/javascript; charset=utf-8", assetText("qr.js") ?: "/* QR unavailable */")
            session.method == Method.GET && path == "/api/portal" -> newFixedLengthResponse(Response.Status.OK, "application/json; charset=utf-8", portalJson())
            session.method == Method.GET && path == "/api/state" -> newFixedLengthResponse(Response.Status.OK, "application/json; charset=utf-8", stateJson())
            session.method == Method.POST && path == "/upload" -> receiveBrowserUpload(session, peer)
            session.method == Method.GET && path == PeerProtocol.INFO_PATH_V1 -> newFixedLengthResponse(
                Response.Status.OK, "application/json; charset=utf-8", PeerProtocol.infoJson(context, PortalService.webPort(), PeerProtocol.VERSION_V1)
            ).apply { addHeader("X-FTPortal-Protocol", PeerProtocol.VERSION_V1) }
            session.method == Method.GET && path == PeerProtocol.INFO_PATH_V2 -> newFixedLengthResponse(
                Response.Status.OK, "application/json; charset=utf-8", PeerProtocol.infoJson(context, PortalService.webPort(), PeerProtocol.VERSION_V2)
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

    private fun receiveBrowserUpload(session: IHTTPSession, peer: String): Response {
        val announcedLength = session.headers["content-length"]?.toLongOrNull() ?: -1L
        // Content-Length also includes the multipart envelope; the uploaded
        // file itself is still checked against MAX_UPLOAD_BYTES below.
        if (announcedLength > MAX_UPLOAD_BYTES + 1024 * 1024) {
            return jsonError(Response.Status.PAYLOAD_TOO_LARGE, "File is too large for this portal")
        }

        val bodyFiles = HashMap<String, String>()
        val parsed = runCatching { session.parseBody(bodyFiles) }
        if (parsed.isFailure) {
            return jsonError(Response.Status.BAD_REQUEST, parsed.exceptionOrNull()?.message ?: "Could not parse upload")
        }

        val uploaded = bodyFiles.entries.firstOrNull { (key, value) ->
            key != "postData" && value.isNotBlank() && File(value).isFile
        } ?: return jsonError(Response.Status.BAD_REQUEST, "No file was included")

        val tempFile = File(uploaded.value)
        if (tempFile.length() > MAX_UPLOAD_BYTES) {
            return jsonError(Response.Status.PAYLOAD_TOO_LARGE, "File is too large for this portal")
        }

        val submittedName = session.parameters[uploaded.key]?.firstOrNull().orEmpty()
        val safeName = safeFileName(submittedName)
        val mime = URLConnection.guessContentTypeFromName(safeName) ?: "application/octet-stream"
        val transferId = TransferCenter.begin(context, TransferDirection.RECEIVE, safeName, peer, tempFile.length())

        return runCatching {
            val destination = saveIncomingFile(tempFile, safeName, mime) { bytes ->
                TransferCenter.update(transferId, bytes)
            }
            TransferCenter.finish(context, transferId, true, "Saved to $destination")
            newFixedLengthResponse(
                Response.Status.OK,
                "application/json; charset=utf-8",
                JSONObject()
                    .put("ok", true)
                    .put("name", safeName)
                    .put("bytes", tempFile.length())
                    .put("destination", destination)
                    .toString()
            )
        }.getOrElse { error ->
            TransferCenter.finish(context, transferId, false, error.message ?: error.javaClass.simpleName)
            jsonError(Response.Status.INTERNAL_ERROR, error.message ?: "Could not save the uploaded file")
        }
    }

    private fun saveIncomingFile(tempFile: File, fileName: String, mime: String, progress: (Long) -> Unit): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/FTPortal")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("Android could not create the Downloads entry")

            try {
                val output = resolver.openOutputStream(uri, "w") ?: error("Android could not open the destination")
                output.use { out -> copyWithProgress(tempFile, out, progress) }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                return "Downloads/FTPortal/$fileName"
            } catch (error: Throwable) {
                runCatching { resolver.delete(uri, null, null) }
                throw error
            }
        }

        val base = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: context.filesDir
        val folder = File(base, "FTPortal").apply { mkdirs() }
        val target = uniqueFile(folder, fileName)
        FileOutputStream(target).use { out -> copyWithProgress(tempFile, out, progress) }
        return target.absolutePath
    }

    private fun copyWithProgress(source: File, output: OutputStream, progress: (Long) -> Unit) {
        source.inputStream().use { input ->
            val buffer = ByteArray(128 * 1024)
            var copied = 0L
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
                copied += count
                progress(copied)
            }
            output.flush()
        }
    }

    private fun uniqueFile(folder: File, requested: String): File {
        val direct = File(folder, requested)
        if (!direct.exists()) return direct
        val dot = requested.lastIndexOf('.')
        val stem = if (dot > 0) requested.substring(0, dot) else requested
        val ext = if (dot > 0) requested.substring(dot) else ""
        for (index in 2..9999) {
            val candidate = File(folder, "$stem ($index)$ext")
            if (!candidate.exists()) return candidate
        }
        return File(folder, "${System.currentTimeMillis()}-$requested")
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

    private fun portalJson(): String {
        val files = JSONArray()
        ShareRegistry.all().forEach { file ->
            files.put(JSONObject().put("id", file.id).put("name", file.name).put("size", file.size).put("mime", file.mime))
        }
        val port = PortalService.webPort()
        val urls = JSONArray()
        NetworkUrls.urls(port).forEach { url ->
            urls.put(JSONObject().put("url", "$url/dashboard").put("kind", "Local network").put("adapter", "active"))
        }
        return JSONObject().put("platform", "Android")
            .put("alias", PeerIdentity.alias())
            .put("maxUploadBytes", MAX_UPLOAD_BYTES)
            .put("lobbyActive", ShareRegistry.all().isNotEmpty() && PortalService.peerAvailable())
            .put("files", files).put("addresses", urls).toString()
    }

    private fun assetText(name: String): String? = runCatching {
        context.assets.open(name).bufferedReader(Charsets.UTF_8).use { it.readText() }
    }.getOrNull()

    private fun portalHtml(): String = assetText("portal.html") ?: html()

    private fun html(): String {
        val receiveRows = ShareRegistry.all().joinToString("\n") { file ->
            val size = if (file.size >= 0) formatBytes(file.size) else "STREAM"
            """<div class='file-row'><div class='file-copy'><strong>${htmlEsc(file.name)}</strong><span>$size · ONE-SHOT</span></div><a class='receive-button' href='/download/${file.id}'>RECEIVE</a></div>"""
        }.ifBlank {
            """<div class='empty-state'><div class='empty-icon'>↓</div><strong>No file waiting</strong><span>Share a file from the FTPortal app and refresh this page.</span></div>"""
        }

        return """<!doctype html>
<html lang='en'><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1,viewport-fit=cover'>
<meta name='theme-color' content='#0d0f12'><title>FTPortal</title><style>
:root{--bg:#0d0f12;--card:#141720;--border:#1e2330;--accent:#4f8ef7;--accent2:#8e6cf7;--text:#e8ecf5;--muted:#5a6480;--ok:#4ff78e;--err:#f74f6a}
*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}header{position:sticky;top:0;z-index:2;background:rgba(20,23,32,.92);backdrop-filter:blur(8px);border-bottom:1px solid var(--border);padding:14px 24px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap}.brand{display:flex;align-items:center;gap:11px}.brand .icon{font-size:24px}.brand h1{font-size:16px;letter-spacing:.5px}.host-chip{display:flex;align-items:center;gap:8px;background:var(--bg);border:1px solid var(--border);padding:6px 12px;border-radius:20px;font-size:13px;color:var(--muted)}.dot{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 6px var(--ok)}main{max-width:1100px;margin:0 auto;padding:24px}.portal-grid{display:grid;grid-template-columns:1fr 1fr;gap:22px}.panel{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:20px;overflow:hidden}.panel-title{display:flex;align-items:center;gap:10px;margin-bottom:8px}.panel-icon{width:32px;height:32px;display:grid;place-items:center;border-radius:9px;background:rgba(79,142,247,.15);color:var(--accent);font-size:18px;font-weight:700}.panel h3{font-size:13px;text-transform:uppercase;letter-spacing:1.5px;color:var(--muted)}.panel-sub{margin:0 0 16px;color:var(--muted);font-size:13px;line-height:1.5}.file-list{display:flex;flex-direction:column;gap:8px}.file-row{display:flex;align-items:center;gap:12px;padding:10px 13px;background:var(--bg);border:1px solid var(--border);border-radius:10px}.file-copy{min-width:0;flex:1}.file-copy strong{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px}.file-copy span{display:block;color:var(--muted);font-size:11px;margin-top:4px}.receive-button,.tx-button{border:0;text-decoration:none;border-radius:9px;padding:10px 13px;font-size:12px;font-weight:600;cursor:pointer}.receive-button{color:var(--accent);border:1px solid var(--border);background:transparent}.receive-button:hover{border-color:var(--accent)}.empty-state{min-height:146px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;border:2px dashed var(--border);border-radius:12px;color:var(--muted);padding:18px}.empty-state strong{color:var(--text);font-size:14px;margin:6px 0}.empty-state span{font-size:12px;line-height:1.45;max-width:270px}.empty-icon{font-size:26px;color:var(--muted)}.drop-zone{min-height:146px;border:2px dashed var(--border);border-radius:12px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:18px;cursor:pointer;color:var(--muted);transition:all .2s}.drop-zone.active{border-color:var(--accent);background:rgba(79,142,247,.06);color:var(--text)}.drop-zone .arrow{font-size:28px;color:var(--accent);margin-bottom:7px}.drop-zone strong{font-size:14px;color:var(--text)}.drop-zone span{font-size:12px;margin-top:5px;max-width:270px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tx-button{width:100%;margin-top:12px;padding:12px 16px;color:#fff;background:var(--accent)}.tx-button:hover{filter:brightness(1.1)}.tx-button:disabled{opacity:.5;cursor:not-allowed}.progress-wrap{display:none;margin-top:14px}.progress-line{height:8px;border-radius:30px;background:var(--bg);border:1px solid var(--border);overflow:hidden}.progress-bar{height:100%;width:0;background:linear-gradient(90deg,var(--accent),var(--accent2));transition:width .12s}.progress-meta{display:flex;justify-content:space-between;color:var(--muted);font-size:11px;margin-top:7px}.result{min-height:18px;color:var(--ok);font-size:12px;margin-top:10px}.foot{text-align:center;color:var(--muted);font-size:11px;margin-top:22px}@media(max-width:680px){header{padding:12px 14px}main{padding:14px}.portal-grid{grid-template-columns:1fr}.panel{padding:16px}}
</style></head><body>
<header><div class='brand'><span class='icon'>📁</span><h1>LOCAL FILE PORTAL</h1></div><div class='host-chip'><span class='dot'></span><b>Android host</b></div></header>
<main><section class='portal-grid'>
    <article class='panel'>
      <div class='panel-title'><div class='panel-icon'>↓</div><h3>RECEIVE FILE</h3></div>
      <p class='panel-sub'>Choose a one-shot file shared by this Android host.</p>
      <div class='file-list'>$receiveRows</div>
    </article>
    <article class='panel'>
      <div class='panel-title'><div class='panel-icon'>↑</div><h3>TRANSMIT FILE</h3></div>
      <p class='panel-sub'>Send one file directly to this Android device.</p>
      <input id='txFile' type='file' hidden>
      <label id='dropZone' class='drop-zone' for='txFile'><div class='arrow'>↑</div><strong>Choose or drop a file</strong><span id='fileName'>Nothing selected</span></label>
      <button id='txButton' class='tx-button' type='button' disabled>TRANSMIT FILE</button>
      <div id='progressWrap' class='progress-wrap'><div class='progress-line'><div id='progressBar' class='progress-bar'></div></div><div class='progress-meta'><span id='progressText'>0%</span><span id='progressSize'></span></div></div>
      <div id='result' class='result'></div>
    </article>
  </section><div class='foot'>LOCAL NETWORK · NO CLOUD · ONE-SHOT LINKS</div></main>
<script>
(function(){
  var input=document.getElementById('txFile');
  var zone=document.getElementById('dropZone');
  var button=document.getElementById('txButton');
  var name=document.getElementById('fileName');
  var wrap=document.getElementById('progressWrap');
  var bar=document.getElementById('progressBar');
  var text=document.getElementById('progressText');
  var size=document.getElementById('progressSize');
  var result=document.getElementById('result');
  var selected=null;
  function fmt(bytes){if(bytes<1024)return bytes+' B';if(bytes<1048576)return(bytes/1024).toFixed(1)+' KB';if(bytes<1073741824)return(bytes/1048576).toFixed(1)+' MB';return(bytes/1073741824).toFixed(2)+' GB'}
  function choose(file){selected=file||null;name.textContent=selected?selected.name+' · '+fmt(selected.size):'Nothing selected';button.disabled=!selected;result.textContent='';}
  input.addEventListener('change',function(){choose(input.files&&input.files[0]);});
  ['dragenter','dragover'].forEach(function(ev){zone.addEventListener(ev,function(e){e.preventDefault();zone.classList.add('active');});});
  ['dragleave','drop'].forEach(function(ev){zone.addEventListener(ev,function(e){e.preventDefault();zone.classList.remove('active');});});
  zone.addEventListener('drop',function(e){if(e.dataTransfer&&e.dataTransfer.files&&e.dataTransfer.files[0])choose(e.dataTransfer.files[0]);});
  button.addEventListener('click',function(){
    if(!selected)return;
    var data=new FormData();data.append('file',selected,selected.name);
    var xhr=new XMLHttpRequest();xhr.open('POST','/upload',true);button.disabled=true;wrap.style.display='block';result.textContent='';
    xhr.upload.onprogress=function(e){if(!e.lengthComputable)return;var p=Math.min(100,Math.round(e.loaded/e.total*100));bar.style.width=p+'%';text.textContent=p+'%';size.textContent=fmt(e.loaded)+' / '+fmt(e.total);};
    xhr.onload=function(){
      button.disabled=false;
      if(xhr.status>=200&&xhr.status<300){bar.style.width='100%';text.textContent='100%';result.textContent='Received by Android · Downloads/FTPortal';selected=null;input.value='';name.textContent='Nothing selected';button.disabled=true;}
      else{var msg='Transfer failed';try{msg=JSON.parse(xhr.responseText).error||msg}catch(ignore){}result.textContent=msg;}
    };
    xhr.onerror=function(){button.disabled=false;result.textContent='Connection interrupted';};
    xhr.send(data);
  });
})();
</script>
</body>
</html>"""
    }

    private fun jsonError(status: Response.Status, message: String): Response = newFixedLengthResponse(
        status,
        "application/json; charset=utf-8",
        JSONObject().put("ok", false).put("error", message.take(240)).toString()
    )

    private fun safeFileName(name: String): String {
        val leaf = name.substringAfterLast('/').substringAfterLast('\\').trim()
        return leaf
            .replace(Regex("[\\u0000-\\u001f<>:\"/\\\\|?*]"), "_")
            .take(180)
            .ifBlank { "received-file" }
    }

    private fun formatBytes(bytes: Long): String = when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024L * 1024L -> "%.1f KB".format(bytes / 1024.0)
        bytes < 1024L * 1024L * 1024L -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
        else -> "%.2f GB".format(bytes / (1024.0 * 1024.0 * 1024.0))
    }

    private fun commonHeaders(response: Response): Response = response.apply {
        addHeader("Cache-Control", "no-store")
        addHeader("X-Content-Type-Options", "nosniff")
        addHeader("Referrer-Policy", "no-referrer")
        addHeader("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'")
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
        if (expected >= 0 && transferred >= expected) {
            reachedEof = true
            settleIfComplete()
            return -1
        }
        val value = super.read()
        if (value >= 0) { transferred++; onProgress(transferred) } else { reachedEof = true; settleIfComplete() }
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        val permittedLength = if (expected >= 0) {
            val remaining = expected - transferred
            if (remaining <= 0) {
                reachedEof = true
                settleIfComplete()
                return -1
            }
            minOf(length.toLong(), remaining).toInt()
        } else {
            length
        }
        val count = super.read(buffer, offset, permittedLength)
        if (count > 0) { transferred += count; onProgress(transferred) }
        else if (count < 0) { reachedEof = true; settleIfComplete() }
        return count
    }

    override fun close() {
        if (!settled) {
            val complete = if (expected >= 0) transferred == expected else reachedEof
            settled = true
            if (complete) completed() else interrupted()
        }
        super.close()
    }

    private fun settleIfComplete() {
        if (settled) return
        val complete = if (expected >= 0) transferred == expected else reachedEof
        if (complete) { settled = true; completed() }
    }
}
