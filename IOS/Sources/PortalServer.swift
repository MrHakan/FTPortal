import Foundation
import Network
import Darwin

final class PortalServer {
    static let legacyPort: UInt16 = 8080
    static let peerPort: UInt16 = UInt16(PeerProtocol.peerPort)

    private var legacyListener: NWListener?
    private var peerListener: NWListener?
    private let queue = DispatchQueue(label: "ftportal.listener")
    private let maximumHeaderBytes = 64 * 1024
    // The browser fallback intentionally has a bounded in-memory request body.
    // Native v2 transfers remain the unrestricted route for larger files.
    private let maximumBodyBytes = 32 * 1024 * 1024 + 128 * 1024
    private let maximumBrowserUploadBytes = 32 * 1024 * 1024
    private let headerSeparator = Data("\r\n\r\n".utf8)

    func start() throws {
        if legacyListener != nil || peerListener != nil { return }

        let legacy = try makeListener(port: Self.legacyPort, serviceType: "_http._tcp")
        legacyListener = legacy
        legacy.start(queue: queue)

        do {
            let peer = try makeListener(port: Self.peerPort, serviceType: "_ftportal._tcp")
            peerListener = peer
            peer.start(queue: queue)
        } catch {
            print("FTPortal peer listener could not start: \(error)")
        }
    }

    func stop() {
        peerListener?.cancel()
        peerListener = nil
        legacyListener?.cancel()
        legacyListener = nil
    }

    private func makeListener(port: UInt16, serviceType: String) throws -> NWListener {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "FTPortal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server port"])
        }
        let listener = try NWListener(using: .tcp, on: endpointPort)
        listener.service = NWListener.Service(name: "FTPortal-\(PeerIdentity.alias())", type: serviceType)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("FTPortal listener \(port) failed: \(error)") }
        }
        return listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var next = buffer
            if let data { next.append(data) }

            if let headerRange = next.range(of: self.headerSeparator) {
                let headerLength = headerRange.lowerBound
                if headerLength > self.maximumHeaderBytes {
                    self.sendText(connection, status: "431 Request Header Fields Too Large", body: "Header too large")
                    return
                }
                let headerData = Data(next.prefix(headerLength))
                let bodyLength = self.contentLength(in: headerData)
                guard bodyLength >= 0, bodyLength <= self.maximumBodyBytes else {
                    self.sendText(connection, status: "413 Payload Too Large", body: "Request body too large")
                    return
                }
                let required = headerRange.upperBound + bodyLength
                if next.count >= required {
                    self.route(connection, request: Data(next.prefix(required)))
                    return
                }
            } else if next.count >= self.maximumHeaderBytes {
                self.sendText(connection, status: "431 Request Header Fields Too Large", body: "Header too large")
                return
            }

            if next.count > self.maximumHeaderBytes + self.maximumBodyBytes + self.headerSeparator.count {
                self.sendText(connection, status: "413 Payload Too Large", body: "Request too large")
                return
            }
            if error != nil || complete {
                connection.cancel()
                return
            }
            self.receiveRequest(connection, buffer: next)
        }
    }

    private func contentLength(in headerData: Data) -> Int {
        guard let text = String(data: headerData, encoding: .utf8) else { return -1 }
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? -1
            }
        }
        return 0
    }

    private func route(_ connection: NWConnection, request: Data) {
        guard let headerRange = request.range(of: headerSeparator) else {
            sendText(connection, status: "400 Bad Request", body: "Bad request")
            return
        }
        let headerData = Data(request.prefix(headerRange.lowerBound))
        let body = Data(request.suffix(from: headerRange.upperBound))
        guard
            let text = String(data: headerData, encoding: .utf8),
            let first = text.components(separatedBy: "\r\n").first
        else {
            sendText(connection, status: "400 Bad Request", body: "Bad request")
            return
        }

        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            sendText(connection, status: "400 Bad Request", body: "Bad request line")
            return
        }
        let method = String(parts[0]).uppercased()
        let headers = parseHeaders(text)
        let rawTarget = String(parts[1])
        let rawPath = String(rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let path = rawPath.removingPercentEncoding ?? rawPath

        guard LocalNetworkGuard.isAllowed(remoteHost(connection)) else {
            sendText(connection, status: "403 Forbidden", body: "Client is outside the active local network")
            return
        }

        if method == "GET" && path == "/" {
            sendHtml(connection)
        } else if method == "GET" && path == "/api/state" {
            sendState(connection)
        } else if method == "POST" && path == "/upload" {
            receiveBrowserUpload(connection, body: body, contentType: headers["content-type"])
        } else if method == "GET" && path == PeerProtocol.infoPathV1 {
            sendResponse(
                connection,
                status: "200 OK",
                contentType: "application/json; charset=utf-8",
                data: PeerProtocol.infoData(legacyPort: Int(Self.legacyPort), version: PeerProtocol.versionV1),
                extraHeaders: ["X-FTPortal-Protocol": PeerProtocol.versionV1]
            )
        } else if method == "GET" && path == PeerProtocol.infoPathV2 {
            sendResponse(
                connection,
                status: "200 OK",
                contentType: "application/json; charset=utf-8",
                data: PeerProtocol.infoData(legacyPort: Int(Self.legacyPort), version: PeerProtocol.versionV2),
                extraHeaders: ["X-FTPortal-Protocol": PeerProtocol.versionV2]
            )
        } else if method == "POST" && path == PeerProtocol.offerPathV2 {
            receiveOffer(connection, body: body)
        } else if method == "GET" && path.hasPrefix(PeerProtocol.transferPrefixV2) {
            sendOfferedFile(connection, path: path, authorization: headers["authorization"])
        } else if method == "GET" && path.hasPrefix(PeerProtocol.downloadPrefixV1) {
            sendFile(
                connection,
                id: String(path.dropFirst(PeerProtocol.downloadPrefixV1.count)),
                protocolVersion: PeerProtocol.versionV1
            )
        } else if method == "GET" && path.hasPrefix("/download/") {
            sendFile(connection, id: String(path.dropFirst("/download/".count)), protocolVersion: nil)
        } else if method != "GET" && method != "POST" {
            sendText(connection, status: "405 Method Not Allowed", body: "GET or POST only", extraHeaders: ["Allow": "GET, POST"])
        } else {
            sendText(connection, status: "404 Not Found", body: "Not found")
        }
    }

    private func receiveOffer(_ connection: NWConnection, body: Data) {
        guard body.count <= 128 * 1024 else {
            sendText(connection, status: "413 Payload Too Large", body: "Offer payload too large")
            return
        }
        let host = remoteHost(connection)
        guard !host.isEmpty, let offer = PeerOfferStore.shared.receiveIncoming(remoteHost: host, data: body) else {
            sendText(connection, status: "400 Bad Request", body: "Invalid or expired offer")
            return
        }
        let response: [String: Any] = [
            "offerId": offer.offerId,
            "status": "pending",
            "expiresAt": offer.expiresAt
        ]
        let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
        sendResponse(
            connection,
            status: "200 OK",
            contentType: "application/json; charset=utf-8",
            data: data,
            extraHeaders: ["X-FTPortal-Protocol": PeerProtocol.versionV2]
        )
    }

    private func receiveBrowserUpload(_ connection: NWConnection, body: Data, contentType: String?) {
        guard body.count <= maximumBrowserUploadBytes + 128 * 1024 else {
            sendJsonError(connection, status: "413 Payload Too Large", message: "File is too large for this iOS browser portal")
            return
        }
        guard let upload = parseBrowserUpload(body: body, contentType: contentType) else {
            sendJsonError(connection, status: "400 Bad Request", message: "Could not read the uploaded file")
            return
        }

        let transferId = TransferCenter.shared.begin(
            direction: .receive,
            fileName: upload.name,
            peer: remoteHost(connection),
            totalBytes: Int64(upload.data.count)
        )
        var destination: URL?
        var written = 0
        do {
            destination = try browserUploadDestination(for: upload.name)
            FileManager.default.createFile(atPath: destination!.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination!)
            defer { try? handle.close() }

            let chunkSize = 128 * 1024
            while written < upload.data.count {
                let end = min(upload.data.count, written + chunkSize)
                try handle.write(contentsOf: upload.data.subdata(in: written..<end))
                written = end
                TransferCenter.shared.update(id: transferId, bytes: Int64(written))
            }
            try handle.synchronize()
            TransferCenter.shared.finish(id: transferId, success: true)
            let response: [String: Any] = [
                "ok": true,
                "name": upload.name,
                "bytes": written,
                "destination": "FTPortal Files"
            ]
            let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{\"ok\":true}".utf8)
            sendResponse(connection, status: "200 OK", contentType: "application/json; charset=utf-8", data: data)
        } catch {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            TransferCenter.shared.finish(id: transferId, success: false, detail: "Could not save the uploaded file")
            sendJsonError(connection, status: "500 Internal Server Error", message: "Could not save the uploaded file")
        }
    }

    private func parseBrowserUpload(body: Data, contentType: String?) -> (name: String, data: Data)? {
        guard let contentType,
              contentType.lowercased().hasPrefix("multipart/form-data"),
              let boundaryPart = contentType.components(separatedBy: ";").first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("boundary=") })
        else { return nil }

        var boundary = boundaryPart.trimmingCharacters(in: .whitespaces).dropFirst("boundary=".count)
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") { boundary.removeFirst(); boundary.removeLast() }
        guard !boundary.isEmpty, boundary.count <= 200 else { return nil }

        let opening = Data("--\(boundary)\r\n".utf8)
        let separator = Data("\r\n\r\n".utf8)
        let closing = Data("\r\n--\(boundary)".utf8)
        guard body.starts(with: opening),
              let headerRange = body.range(of: separator, options: [], in: opening.count..<body.count),
              let headerText = String(data: body.subdata(in: opening.count..<headerRange.lowerBound), encoding: .utf8),
              headerText.contains("name=\"file\"") || headerText.contains("name=file"),
              let fileName = multipartFilename(in: headerText)
        else { return nil }

        let payloadStart = headerRange.upperBound
        guard let payloadEnd = body.range(of: closing, options: [], in: payloadStart..<body.count)?.lowerBound,
              payloadEnd >= payloadStart
        else { return nil }
        return (safeFileName(fileName), body.subdata(in: payloadStart..<payloadEnd))
    }

    private func multipartFilename(in headers: String) -> String? {
        let lower = headers.lowercased()
        guard let range = lower.range(of: "filename=") else { return nil }
        let remainder = headers[range.upperBound...]
        if remainder.first == "\"" {
            let value = remainder.dropFirst()
            guard let end = value.firstIndex(of: "\"") else { return nil }
            return String(value[..<end])
        }
        return String(remainder.prefix { $0 != ";" && $0 != "\r" && $0 != "\n" })
    }

    private func safeFileName(_ submittedName: String) -> String {
        let leaf = submittedName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let forbidden = CharacterSet(charactersIn: "\u{0000}\r\n<>:\\|?*/")
        let clean = leaf.unicodeScalars.map { forbidden.contains($0) || CharacterSet.controlCharacters.contains($0) ? "_" : String($0) }.joined().trimmingCharacters(in: .whitespaces)
        if clean.isEmpty || clean == "." || clean == ".." { return "received-file" }
        return String(clean.prefix(180))
    }

    private func browserUploadDestination(for fileName: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("FTPortal Files", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let direct = root.appendingPathComponent(fileName, isDirectory: false)
        if !FileManager.default.fileExists(atPath: direct.path) { return direct }

        let nsName = fileName as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        for index in 2...9999 {
            let candidate = root.appendingPathComponent("\(stem) (\(index))\(ext.isEmpty ? "" : ".\(ext)")", isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return root.appendingPathComponent("\(UUID().uuidString)-\(fileName)", isDirectory: false)
    }

    private func sendOfferedFile(_ connection: NWConnection, path: String, authorization: String?) {
        let remainder = String(path.dropFirst(PeerProtocol.transferPrefixV2.count))
        let parts = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            sendText(connection, status: "400 Bad Request", body: "Invalid transfer path")
            return
        }
        let offerId = String(parts[0])
        let fileId = String(parts[1])
        guard PeerOfferStore.shared.authorizeOutgoing(offerId: offerId, fileId: fileId, authorization: authorization) else {
            sendText(connection, status: "401 Unauthorized", body: "Offer authorization failed", extraHeaders: ["WWW-Authenticate": "Bearer"])
            return
        }
        sendFile(
            connection,
            id: fileId,
            protocolVersion: PeerProtocol.versionV2,
            onCompleted: { PeerOfferStore.shared.completeOutgoingFile(offerId: offerId, fileId: fileId) }
        )
    }

    private func parseHeaders(_ headerText: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return headers
    }

    private func remoteHost(_ connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            return String(describing: host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        default:
            return ""
        }
    }

    private func sendHtml(_ connection: NWConnection) {
        let rows = PortalStore.shared.all().map { file in
            "<div class='file-row'><div class='file-copy'><strong>\(html(file.name))</strong><span>\(formatBytes(file.size)) · ONE-SHOT</span></div><a class='receive-button' href='/download/\(file.id)'>RECEIVE</a></div>"
        }.joined()
        let content = rows.isEmpty
            ? "<div class='empty-state'><div class='empty-icon'>↓</div><strong>No file waiting</strong><span>Share a file from the FTPortal app and refresh this page.</span></div>"
            : rows
        let body = """
<!doctype html><html lang='en'><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1,viewport-fit=cover'>
<meta name='theme-color' content='#0d0f12'><title>FTPortal</title><style>
:root{--bg:#0d0f12;--card:#141720;--border:#1e2330;--accent:#4f8ef7;--accent2:#8e6cf7;--text:#e8ecf5;--muted:#5a6480;--ok:#4ff78e}
*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}header{position:sticky;top:0;z-index:2;background:rgba(20,23,32,.92);backdrop-filter:blur(8px);border-bottom:1px solid var(--border);padding:14px 24px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap}.brand{display:flex;align-items:center;gap:11px}.brand .icon{font-size:24px}.brand h1{font-size:16px;letter-spacing:.5px}.host-chip{display:flex;align-items:center;gap:8px;background:var(--bg);border:1px solid var(--border);padding:6px 12px;border-radius:20px;font-size:13px;color:var(--muted)}.dot{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 6px var(--ok)}main{max-width:1100px;margin:0 auto;padding:24px}.portal-grid{display:grid;grid-template-columns:1fr 1fr;gap:22px}.panel{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:20px;overflow:hidden}.panel-title{display:flex;align-items:center;gap:10px;margin-bottom:8px}.panel-icon{width:32px;height:32px;display:grid;place-items:center;border-radius:9px;background:rgba(79,142,247,.15);color:var(--accent);font-size:18px;font-weight:700}.panel h3{font-size:13px;text-transform:uppercase;letter-spacing:1.5px;color:var(--muted)}.panel-sub{margin:0 0 16px;color:var(--muted);font-size:13px;line-height:1.5}.file-list{display:flex;flex-direction:column;gap:8px}.file-row{display:flex;align-items:center;gap:12px;padding:10px 13px;background:var(--bg);border:1px solid var(--border);border-radius:10px}.file-copy{min-width:0;flex:1}.file-copy strong{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px}.file-copy span{display:block;color:var(--muted);font-size:11px;margin-top:4px}.receive-button,.tx-button{border:0;text-decoration:none;border-radius:9px;padding:10px 13px;font-size:12px;font-weight:600;cursor:pointer}.receive-button{color:var(--accent);border:1px solid var(--border);background:transparent}.receive-button:hover{border-color:var(--accent)}.empty-state{min-height:146px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;border:2px dashed var(--border);border-radius:12px;color:var(--muted);padding:18px}.empty-state strong{color:var(--text);font-size:14px;margin:6px 0}.empty-state span{font-size:12px;line-height:1.45;max-width:270px}.empty-icon{font-size:26px;color:var(--muted)}.drop-zone{min-height:146px;border:2px dashed var(--border);border-radius:12px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:18px;cursor:pointer;color:var(--muted);transition:all .2s}.drop-zone.active{border-color:var(--accent);background:rgba(79,142,247,.06);color:var(--text)}.drop-zone .arrow{font-size:28px;color:var(--accent);margin-bottom:7px}.drop-zone strong{font-size:14px;color:var(--text)}.drop-zone span{font-size:12px;margin-top:5px;max-width:270px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tx-button{width:100%;margin-top:12px;padding:12px 16px;color:#fff;background:var(--accent)}.tx-button:hover{filter:brightness(1.1)}.tx-button:disabled{opacity:.5;cursor:not-allowed}.progress-wrap{display:none;margin-top:14px}.progress-line{height:8px;border-radius:30px;background:var(--bg);border:1px solid var(--border);overflow:hidden}.progress-bar{height:100%;width:0;background:linear-gradient(90deg,var(--accent),var(--accent2));transition:width .12s}.progress-meta{display:flex;justify-content:space-between;color:var(--muted);font-size:11px;margin-top:7px}.result{min-height:18px;color:var(--ok);font-size:12px;margin-top:10px}.foot{text-align:center;color:var(--muted);font-size:11px;margin-top:22px}@media(max-width:680px){header{padding:12px 14px}main{padding:14px}.portal-grid{grid-template-columns:1fr}.panel{padding:16px}}
</style></head><body>
<header><div class='brand'><span class='icon'>📁</span><h1>LOCAL FILE PORTAL</h1></div><div class='host-chip'><span class='dot'></span><b>iPhone/iPad host</b></div></header>
<main><section class='portal-grid'>
  <article class='panel'><div class='panel-title'><div class='panel-icon'>↓</div><h3>RECEIVE FILE</h3></div><p class='panel-sub'>Choose a one-shot file shared by this iPhone or iPad.</p><div class='file-list'>\(content)</div></article>
  <article class='panel'><div class='panel-title'><div class='panel-icon'>↑</div><h3>TRANSMIT FILE</h3></div><p class='panel-sub'>Send one file directly to this iPhone or iPad (up to 32 MB).</p><input id='txFile' type='file' hidden><label id='dropZone' class='drop-zone' for='txFile'><div class='arrow'>↑</div><strong>Choose or drop a file</strong><span id='fileName'>Nothing selected</span></label><button id='txButton' class='tx-button' type='button' disabled>TRANSMIT FILE</button><div id='progressWrap' class='progress-wrap'><div class='progress-line'><div id='progressBar' class='progress-bar'></div></div><div class='progress-meta'><span id='progressText'>0%</span><span id='progressSize'></span></div></div><div id='result' class='result'></div></article>
</section><div class='foot'>LOCAL NETWORK · NO CLOUD · ONE-SHOT LINKS</div></main>
<script>(function(){var input=document.getElementById('txFile'),zone=document.getElementById('dropZone'),button=document.getElementById('txButton'),name=document.getElementById('fileName'),wrap=document.getElementById('progressWrap'),bar=document.getElementById('progressBar'),text=document.getElementById('progressText'),size=document.getElementById('progressSize'),result=document.getElementById('result'),selected=null;function fmt(bytes){if(bytes<1024)return bytes+' B';if(bytes<1048576)return(bytes/1024).toFixed(1)+' KB';return(bytes/1048576).toFixed(1)+' MB'}function choose(file){selected=file||null;name.textContent=selected?selected.name+' · '+fmt(selected.size):'Nothing selected';button.disabled=!selected;result.textContent=''}input.addEventListener('change',function(){choose(input.files&&input.files[0])});['dragenter','dragover'].forEach(function(ev){zone.addEventListener(ev,function(e){e.preventDefault();zone.classList.add('active')})});['dragleave','drop'].forEach(function(ev){zone.addEventListener(ev,function(e){e.preventDefault();zone.classList.remove('active')})});zone.addEventListener('drop',function(e){if(e.dataTransfer&&e.dataTransfer.files&&e.dataTransfer.files[0])choose(e.dataTransfer.files[0])});button.addEventListener('click',function(){if(!selected)return;if(selected.size>33554432){result.textContent='iOS browser uploads are limited to 32 MB';return}var data=new FormData();data.append('file',selected,selected.name);var xhr=new XMLHttpRequest();xhr.open('POST','/upload',true);button.disabled=true;wrap.style.display='block';result.textContent='';xhr.upload.onprogress=function(e){if(!e.lengthComputable)return;var p=Math.min(100,Math.round(e.loaded/e.total*100));bar.style.width=p+'%';text.textContent=p+'%';size.textContent=fmt(e.loaded)+' / '+fmt(e.total)};xhr.onload=function(){button.disabled=false;if(xhr.status>=200&&xhr.status<300){bar.style.width='100%';text.textContent='100%';result.textContent='Received by iPhone/iPad · FTPortal Files';selected=null;input.value='';name.textContent='Nothing selected';button.disabled=true}else{var msg='Transfer failed';try{msg=JSON.parse(xhr.responseText).error||msg}catch(ignore){}result.textContent=msg}};xhr.onerror=function(){button.disabled=false;result.textContent='Connection interrupted'};xhr.send(data)})})();</script>
</body></html>
"""
        sendResponse(connection, status: "200 OK", contentType: "text/html; charset=utf-8", data: Data(body.utf8))
    }

    private func sendState(_ connection: NWConnection) {
        let files = PortalStore.shared.all()
        let data = (try? JSONEncoder().encode(["files": files])) ?? Data("{\"files\":[]}".utf8)
        sendResponse(connection, status: "200 OK", contentType: "application/json; charset=utf-8", data: data)
    }

    private func sendFile(
        _ connection: NWConnection,
        id: String,
        protocolVersion: String?,
        onCompleted: (() -> Void)? = nil
    ) {
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isHexDigit }) else {
            sendText(connection, status: "400 Bad Request", body: "Invalid share id")
            return
        }
        guard let (meta, url) = PortalStore.shared.claim(id) else {
            sendText(connection, status: "410 Gone", body: "Share already consumed, busy, or unavailable")
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            PortalStore.shared.release(id)
            sendText(connection, status: "404 Not Found", body: "Source file unavailable")
            return
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? meta.size
        guard size >= 0 else {
            try? handle.close()
            PortalStore.shared.release(id)
            sendText(connection, status: "500 Internal Server Error", body: "Could not determine source length")
            return
        }

        var header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(meta.mime)\r\n" +
            "Content-Length: \(size)\r\n" +
            "Content-Disposition: \(attachmentDisposition(meta.name))\r\n" +
            securityHeaders() +
            "X-FTPortal-One-Shot: true\r\n"
        if let protocolVersion { header += "X-FTPortal-Protocol: \(protocolVersion)\r\n" }
        header += "Connection: close\r\n\r\n"
        let transferId = TransferCenter.shared.begin(
            direction: .send,
            fileName: meta.name,
            peer: remoteHost(connection),
            totalBytes: size
        )

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                try? handle.close()
                PortalStore.shared.release(id)
                TransferCenter.shared.finish(id: transferId, success: false, detail: "Connection interrupted")
                connection.cancel()
                return
            }
            self?.sendChunk(connection, handle: handle, id: id, transferId: transferId, expected: size, transferred: 0, onCompleted: onCompleted)
        })
    }

    private func sendChunk(
        _ connection: NWConnection,
        handle: FileHandle,
        id: String,
        transferId: String,
        expected: Int64,
        transferred: Int64,
        onCompleted: (() -> Void)?
    ) {
        do {
            let remaining = expected >= 0 ? max(0, expected - transferred) : Int64(256 * 1024)
            let readSize = Int(min(Int64(256 * 1024), remaining))
            let chunk = readSize == 0 ? Data() : (try handle.read(upToCount: readSize) ?? Data())
            if chunk.isEmpty {
                try? handle.close()
                guard expected < 0 || transferred == expected else {
                    PortalStore.shared.release(id)
                    TransferCenter.shared.finish(id: transferId, success: false, detail: "Source changed during transfer")
                    connection.cancel()
                    return
                }
                PortalStore.shared.consume(id)
                onCompleted?()
                TransferCenter.shared.finish(id: transferId, success: true)
                connection.cancel()
                return
            }
            let nextTransferred = transferred + Int64(chunk.count)
            TransferCenter.shared.update(id: transferId, bytes: nextTransferred)
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard error == nil else {
                    try? handle.close()
                    PortalStore.shared.release(id)
                    TransferCenter.shared.finish(id: transferId, success: false, detail: "Connection interrupted")
                    connection.cancel()
                    return
                }
                self?.sendChunk(connection, handle: handle, id: id, transferId: transferId, expected: expected, transferred: nextTransferred, onCompleted: onCompleted)
            })
        } catch {
            try? handle.close()
            PortalStore.shared.release(id)
            TransferCenter.shared.finish(id: transferId, success: false, detail: "Source I/O error")
            connection.cancel()
        }
    }

    private func sendText(_ connection: NWConnection, status: String, body: String, extraHeaders: [String: String] = [:]) {
        sendResponse(connection, status: status, contentType: "text/plain; charset=utf-8", data: Data(body.utf8), extraHeaders: extraHeaders)
    }

    private func sendJsonError(_ connection: NWConnection, status: String, message: String) {
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": String(message.prefix(240))])) ?? Data("{\"ok\":false}".utf8)
        sendResponse(connection, status: status, contentType: "application/json; charset=utf-8", data: data)
    }

    private func sendResponse(
        _ connection: NWConnection,
        status: String,
        contentType: String,
        data: Data,
        extraHeaders: [String: String] = [:]
    ) {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\n"
        header += securityHeaders()
        for (name, value) in extraHeaders { header += "\(name): \(value)\r\n" }
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func securityHeaders() -> String {
        "Cache-Control: no-store\r\n" +
        "X-Content-Type-Options: nosniff\r\n" +
        "Referrer-Policy: no-referrer\r\n" +
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'self'\r\n"
    }

    private func attachmentDisposition(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "!#$&+-.^_`|~")
        let encoded = clean.addingPercentEncoding(withAllowedCharacters: allowed) ?? "download"
        return "attachment; filename=\"download\"; filename*=UTF-8''\(encoded)"
    }

    private func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        switch bytes {
        case ..<0: return "STREAM"
        case 0..<1024: return "\(bytes) B"
        case 0..<(1024 * 1024): return String(format: "%.1f KB", Double(bytes) / 1024)
        case 0..<(1024 * 1024 * 1024): return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        default: return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }

    static func localIPv4() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var values: [String] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let flags = Int32(item.pointee.ifa_flags)
            let interface = String(cString: item.pointee.ifa_name)
            let isLocalInterface = interface.hasPrefix("en") || interface.hasPrefix("bridge")
            if flags & IFF_UP != 0,
               flags & IFF_LOOPBACK == 0,
               isLocalInterface,
               let address = item.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(address.pointee.sa_len)
                if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    values.append(String(cString: host))
                }
            }
            current = item.pointee.ifa_next
        }
        return Array(Set(values)).sorted()
    }
}
