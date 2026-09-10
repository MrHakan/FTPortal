import Foundation
import Network
import Darwin

final class PortalServer {
    static let port: UInt16 = 8080
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ftportal.listener")

    func start() throws {
        if listener != nil { return }
        let p = NWEndpoint.Port(rawValue: Self.port)!
        let newListener = try NWListener(using: .tcp, on: p)
        newListener.service = NWListener.Service(name: "FTPortal", type: "_http._tcp")
        newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        newListener.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("FTPortal listener failed: \(error)") }
        }
        newListener.start(queue: queue)
        listener = newListener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if error != nil || complete { connection.cancel(); return }
            if next.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.route(connection, request: next)
            } else if next.count < 262144 {
                self.receiveHeader(connection, buffer: next)
            } else {
                self.sendText(connection, status: "413 Payload Too Large", body: "Header too large")
            }
        }
    }

    private func route(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8), let first = text.components(separatedBy: "\r\n").first else {
            sendText(connection, status: "400 Bad Request", body: "Bad request")
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendText(connection, status: "405 Method Not Allowed", body: "GET only")
            return
        }
        let path = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        if path == "/" { sendHtml(connection) }
        else if path == "/api/state" { sendState(connection) }
        else if path.hasPrefix("/download/") { sendFile(connection, id: String(path.dropFirst("/download/".count))) }
        else { sendText(connection, status: "404 Not Found", body: "Not found") }
    }

    private func sendHtml(_ connection: NWConnection) {
        let rows = PortalStore.shared.all().map { file in
            "<a class='file' href='/download/\(file.id)'><b>\(html(file.name))</b><span>\(file.size >= 0 ? "\(file.size) bytes" : "stream")</span></a>"
        }.joined()
        let content = rows.isEmpty ? "<p>No file is currently shared.</p>" : rows
        let body = "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='refresh' content='4'><title>FTPortal iOS</title><style>body{font-family:-apple-system;background:#0d1117;color:#e6edf3;max-width:720px;margin:50px auto;padding:20px}.file{display:flex;justify-content:space-between;padding:18px;margin:10px 0;border:1px solid #30363d;border-radius:12px;color:#58a6ff;text-decoration:none;background:#161b22}.file span,p{color:#8b949e}</style></head><body><h1>FTPortal</h1><p>iOS one-shot host · a completed download consumes the share.</p>\(content)</body></html>"
        sendResponse(connection, status: "200 OK", contentType: "text/html; charset=utf-8", data: Data(body.utf8))
    }

    private func sendState(_ connection: NWConnection) {
        let files = PortalStore.shared.all()
        let data = (try? JSONEncoder().encode(["files": files])) ?? Data("{\"files\":[]}".utf8)
        sendResponse(connection, status: "200 OK", contentType: "application/json", data: data)
    }

    private func sendFile(_ connection: NWConnection, id: String) {
        guard let (meta, url) = PortalStore.shared.item(id) else {
            sendText(connection, status: "410 Gone", body: "Share already consumed or unavailable")
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            sendText(connection, status: "404 Not Found", body: "Source file unavailable")
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? meta.size
        guard size >= 0 else {
            try? handle.close()
            sendText(connection, status: "500 Internal Server Error", body: "Could not determine source length")
            return
        }
        let safeName = meta.name.replacingOccurrences(of: "\"", with: "'")
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\nContent-Disposition: attachment; filename=\"\(safeName)\"\r\nCache-Control: no-store\r\nX-FTPortal-One-Shot: true\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            self?.sendChunk(connection, handle: handle, id: id)
        })
    }

    private func sendChunk(_ connection: NWConnection, handle: FileHandle, id: String) {
        do {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty {
                try? handle.close()
                PortalStore.shared.consume(id)
                connection.cancel()
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                if error != nil { try? handle.close(); connection.cancel(); return }
                self?.sendChunk(connection, handle: handle, id: id)
            })
        } catch {
            try? handle.close()
            connection.cancel()
        }
    }

    private func sendText(_ connection: NWConnection, status: String, body: String) {
        sendResponse(connection, status: status, contentType: "text/plain; charset=utf-8", data: Data(body.utf8))
    }

    private func sendResponse(_ connection: NWConnection, status: String, contentType: String, data: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func localIPv4() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var values: [String] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let flags = Int32(item.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(addr.pointee.sa_len)
                if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    values.append(String(cString: host))
                }
            }
            current = item.pointee.ifa_next
        }
        return Array(Set(values)).sorted()
    }
}
