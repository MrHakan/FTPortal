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
        val response = when {
            session.method == Method.GET && path == "/" -> newFixedLengthResponse(Response.Status.OK, "text/html; charset=utf-8", html())
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
        if (announcedLength > MAX_UPLOAD_BYTES) {
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

    private fun html(): String {
        val receiveRows = ShareRegistry.all().joinToString("\n") { file ->
            val size = if (file.size >= 0) formatBytes(file.size) else "STREAM"
            """<div class='file-row'><div class='file-copy'><strong>${htmlEsc(file.name)}</strong><span>$size · ONE-SHOT</span></div><a class='receive-button' href='/download/${file.id}'>RECEIVE</a></div>"""
        }.ifBlank {
            """<div class='empty-state'><div class='empty-icon'>↓</div><strong>No file waiting</strong><span>Share a file from the FTPortal app and refresh this page.</span></div>"""
        }

        return """<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1,viewport-fit=cover'>
<meta name='theme-color' content='#07111f'>
<title>FTPortal</title>
<style>
:root{--bg:#050b13;--surface:rgba(11,24,40,.86);--line:rgba(91,149,218,.26);--blue:#58a6ff;--cyan:#3de2ff;--text:#eef6ff;--muted:#8da3bb;--ok:#46e6a6}
*{box-sizing:border-box}html,body{margin:0;min-height:100%;background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,-apple-system,sans-serif}body{min-height:100vh;overflow-x:hidden}.grid-bg{position:fixed;inset:0;pointer-events:none;background-image:linear-gradient(rgba(60,139,226,.055) 1px,transparent 1px),linear-gradient(90deg,rgba(60,139,226,.055) 1px,transparent 1px),radial-gradient(circle at 50% -10%,rgba(33,119,255,.2),transparent 40%);background-size:38px 38px,38px 38px,100% 100%;mask-image:linear-gradient(to bottom,#000,transparent 80%)}
.shell{position:relative;z-index:1;width:min(920px,100%);margin:0 auto;padding:max(28px,env(safe-area-inset-top)) 20px max(32px,env(safe-area-inset-bottom))}.topbar{display:flex;align-items:center;justify-content:space-between;margin-bottom:42px}.brand{display:flex;gap:13px;align-items:center}.mark{width:48px;height:48px;border:1px solid rgba(83,174,255,.55);border-radius:15px;display:grid;place-items:center;font-size:24px;font-weight:800;background:linear-gradient(145deg,rgba(45,100,255,.3),rgba(14,212,255,.12));box-shadow:0 0 32px rgba(26,134,255,.16)}.brand h1{font-size:24px;margin:0;letter-spacing:-.5px}.brand small{display:block;color:var(--muted);font-size:12px;letter-spacing:.14em;margin-top:2px}.status{display:flex;align-items:center;gap:7px;padding:8px 11px;border:1px solid rgba(70,230,166,.22);border-radius:999px;background:rgba(34,167,118,.08);color:#95f3cf;font-size:12px;font-weight:700}.dot{width:7px;height:7px;border-radius:50%;background:var(--ok);box-shadow:0 0 12px var(--ok)}
.intro{text-align:center;margin:0 auto 34px;max-width:650px}.eyebrow{color:var(--cyan);font-size:11px;letter-spacing:.24em;font-weight:800}.intro h2{font-size:clamp(34px,7vw,58px);line-height:1;margin:10px 0 13px;letter-spacing:-2px}.intro p{margin:0;color:var(--muted);font-size:15px}.portal-grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}.panel{position:relative;overflow:hidden;border:1px solid var(--line);border-radius:24px;padding:22px;background:linear-gradient(145deg,var(--surface),rgba(7,15,26,.88));box-shadow:0 18px 60px rgba(0,0,0,.25)}.panel:before{content:'';position:absolute;inset:0 0 auto;height:1px;background:linear-gradient(90deg,transparent,rgba(77,181,255,.8),transparent)}.panel-title{display:flex;align-items:center;gap:12px;margin-bottom:7px}.panel-icon{width:42px;height:42px;border-radius:13px;display:grid;place-items:center;background:rgba(52,126,255,.12);border:1px solid rgba(88,166,255,.2);color:var(--blue);font-size:21px;font-weight:800}.panel h3{margin:0;font-size:19px;letter-spacing:.03em}.panel-sub{margin:0 0 20px;color:var(--muted);font-size:13px;line-height:1.5}.file-list{display:grid;gap:10px}.file-row{display:flex;align-items:center;gap:12px;padding:13px;border:1px solid rgba(100,139,185,.18);border-radius:16px;background:rgba(255,255,255,.025)}.file-copy{min-width:0;flex:1}.file-copy strong{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:14px}.file-copy span{display:block;color:var(--muted);font-size:10px;letter-spacing:.08em;margin-top:5px}.receive-button,.tx-button{border:0;text-decoration:none;border-radius:12px;padding:11px 13px;font-size:11px;letter-spacing:.08em;font-weight:800;cursor:pointer}.receive-button{color:#cce5ff;border:1px solid rgba(88,166,255,.32);background:rgba(57,131,255,.12)}.empty-state{min-height:154px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;border:1px dashed rgba(120,156,197,.22);border-radius:17px;color:var(--muted);padding:18px}.empty-state strong{color:#c7d7e8;font-size:14px;margin:5px 0}.empty-state span{font-size:12px;line-height:1.4;max-width:250px}.empty-icon{font-size:28px;color:#5f87b4}
.drop-zone{min-height:154px;border:1px dashed rgba(61,226,255,.35);border-radius:17px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:18px;cursor:pointer;background:rgba(35,180,255,.035);transition:.18s ease}.drop-zone.active{border-color:var(--cyan);background:rgba(35,180,255,.09);transform:translateY(-1px)}.drop-zone .arrow{font-size:30px;color:var(--cyan);margin-bottom:6px}.drop-zone strong{font-size:14px}.drop-zone span{color:var(--muted);font-size:12px;margin-top:5px;max-width:270px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tx-button{width:100%;margin-top:12px;padding:14px;color:#00111a;background:linear-gradient(90deg,#55a5ff,#3de2ff);box-shadow:0 8px 28px rgba(42,170,255,.16)}.tx-button:disabled{opacity:.38;cursor:not-allowed}.progress-wrap{display:none;margin-top:14px}.progress-line{height:7px;border-radius:999px;background:#132235;overflow:hidden}.progress-bar{height:100%;width:0;background:linear-gradient(90deg,var(--blue),var(--cyan));transition:width .12s linear}.progress-meta{display:flex;justify-content:space-between;color:var(--muted);font-size:11px;margin-top:7px}.result{min-height:18px;color:#9ed7ff;font-size:12px;margin-top:10px}.foot{text-align:center;color:#526a83;font-size:10px;letter-spacing:.17em;margin-top:28px}
@media(max-width:680px){.shell{padding-left:15px;padding-right:15px}.topbar{margin-bottom:34px}.brand small{display:none}.status{padding:7px 9px}.portal-grid{grid-template-columns:1fr}.panel{padding:18px;border-radius:20px}.intro{text-align:left;margin-bottom:25px}.intro h2{letter-spacing:-1.4px}.intro p{font-size:14px}}
</style>
</head>
<body>
<div class='grid-bg'></div>
<main class='shell'>
  <header class='topbar'>
    <div class='brand'><div class='mark'>⇄</div><div><h1>FTPortal</h1><small>LOCAL TRANSFER</small></div></div>
    <div class='status'><span class='dot'></span>ONLINE</div>
  </header>
  <section class='intro'><div class='eyebrow'>DIRECT · LOCAL · SIMPLE</div><h2>Move files. No cloud.</h2><p>Two actions, one local portal.</p></section>
  <section class='portal-grid'>
    <article class='panel'>
      <div class='panel-title'><div class='panel-icon'>↓</div><h3>RECEIVE FILE</h3></div>
      <p class='panel-sub'>Files waiting on the Android host.</p>
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
  </section>
  <div class='foot'>FTPORTAL · PRIVATE LAN TRANSFER</div>
</main>
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
        addHeader("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'self'")
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
