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
    private let maximumBodyBytes = 256 * 1024
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
            "<a class='file' href='/download/\(file.id)'><b>\(html(file.name))</b><span>\(file.size >= 0 ? "\(file.size) bytes" : "stream")</span></a>"
        }.joined()
        let content = rows.isEmpty ? "<p>No file is currently shared.</p>" : rows
        let body = "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='refresh' content='4'><title>FTPortal iOS</title><style>body{font-family:-apple-system;background:#0d1117;color:#e6edf3;max-width:720px;margin:50px auto;padding:20px}.file{display:flex;justify-content:space-between;padding:18px;margin:10px 0;border:1px solid #30363d;border-radius:12px;color:#58a6ff;text-decoration:none;background:#161b22}.file span,p{color:#8b949e}</style></head><body><h1>FTPortal</h1><p>iOS one-shot host · completed downloads consume the share.</p>\(content)</body></html>"
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

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                try? handle.close()
                PortalStore.shared.release(id)
                connection.cancel()
                return
            }
            self?.sendChunk(connection, handle: handle, id: id, onCompleted: onCompleted)
        })
    }

    private func sendChunk(_ connection: NWConnection, handle: FileHandle, id: String, onCompleted: (() -> Void)?) {
        do {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty {
                try? handle.close()
                PortalStore.shared.consume(id)
                onCompleted?()
                connection.cancel()
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard error == nil else {
                    try? handle.close()
                    PortalStore.shared.release(id)
                    connection.cancel()
                    return
                }
                self?.sendChunk(connection, handle: handle, id: id, onCompleted: onCompleted)
            })
        } catch {
            try? handle.close()
            PortalStore.shared.release(id)
            connection.cancel()
        }
    }

    private func sendText(_ connection: NWConnection, status: String, body: String, extraHeaders: [String: String] = [:]) {
        sendResponse(connection, status: status, contentType: "text/plain; charset=utf-8", data: Data(body.utf8), extraHeaders: extraHeaders)
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
        "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\r\n"
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
