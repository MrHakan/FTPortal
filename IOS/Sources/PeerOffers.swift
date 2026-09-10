import Foundation

struct PeerOfferFile: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let size: Int64
    let mime: String
}

struct PeerOfferWire: Codable {
    let protocolName: String
    let offerId: String
    let senderDeviceId: String
    let senderAlias: String
    let senderPlatform: String
    let peerPort: Int
    let token: String
    let verificationCode: String
    let expiresAt: Int64
    let files: [PeerOfferFile]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case offerId, senderDeviceId, senderAlias, senderPlatform, peerPort, token, verificationCode, expiresAt, files
    }
}

struct IncomingPeerOffer: Identifiable, Hashable {
    var id: String { offerId }
    let offerId: String
    let senderDeviceId: String
    let senderAlias: String
    let senderPlatform: String
    let host: String
    let peerPort: Int
    let token: String
    let verificationCode: String
    let expiresAt: Int64
    let files: [PeerOfferFile]
}

struct PeerOfferReceiveResult {
    let urls: [URL]
    let directory: URL?
    let failures: [String]
}

private struct OutgoingPeerGrant {
    let token: String
    let expiresAt: Int64
    var fileIds: Set<String>
}

final class PeerOfferStore {
    static let shared = PeerOfferStore()

    private let lock = NSLock()
    private var incomingById: [String: IncomingPeerOffer] = [:]
    private var outgoingById: [String: OutgoingPeerGrant] = [:]
    private let offerTTL: Int64 = 5 * 60 * 1000
    private let maximumClockWindow: Int64 = 10 * 60 * 1000
    private let maximumIncomingOffers = 20
    private let maximumFilesPerOffer = 128

    private init() {}

    func prepareOutgoing(files: [SharedFile]) throws -> PeerOfferWire {
        guard !files.isEmpty else { throw offerError("No pending files to offer") }
        guard files.count <= maximumFilesPerOffer else { throw offerError("Too many files in one offer") }

        let now = nowMilliseconds()
        let offerId = randomHex(bytes: 16)
        let token = randomHex(bytes: 32)
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let expiresAt = now + offerTTL
        let manifest = files.map { PeerOfferFile(id: $0.id, name: $0.name, size: $0.size, mime: $0.mime) }
        let wire = PeerOfferWire(
            protocolName: PeerProtocol.versionV2,
            offerId: offerId,
            senderDeviceId: PeerIdentity.deviceId(),
            senderAlias: PeerIdentity.alias(),
            senderPlatform: "iOS",
            peerPort: PeerProtocol.peerPort,
            token: token,
            verificationCode: code,
            expiresAt: expiresAt,
            files: manifest
        )

        lock.lock()
        cleanupLocked(now: now)
        outgoingById[offerId] = OutgoingPeerGrant(token: token, expiresAt: expiresAt, fileIds: Set(manifest.map(\.id)))
        lock.unlock()
        return wire
    }

    func cancelOutgoing(_ offerId: String) {
        lock.lock()
        outgoingById.removeValue(forKey: offerId)
        lock.unlock()
    }

    func receiveIncoming(remoteHost: String, data: Data) -> IncomingPeerOffer? {
        guard let wire = try? JSONDecoder().decode(PeerOfferWire.self, from: data) else { return nil }
        let now = nowMilliseconds()
        guard wire.protocolName == PeerProtocol.versionV2 else { return nil }
        guard isHex(wire.offerId, length: 32), isHex(wire.token, length: 64) else { return nil }
        guard !wire.senderDeviceId.isEmpty, wire.senderDeviceId != PeerIdentity.deviceId() else { return nil }
        guard wire.verificationCode.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else { return nil }
        guard wire.expiresAt > now, wire.expiresAt <= now + maximumClockWindow else { return nil }
        guard wire.peerPort > 0, wire.peerPort <= 65_535, !remoteHost.isEmpty else { return nil }
        guard !wire.files.isEmpty, wire.files.count <= maximumFilesPerOffer else { return nil }

        let files = wire.files.filter {
            !$0.id.isEmpty && $0.id.count <= 64 && $0.id.allSatisfy(\.isLetterOrNumber) && !$0.name.isEmpty && $0.name.count <= 255
        }
        guard !files.isEmpty else { return nil }

        let offer = IncomingPeerOffer(
            offerId: wire.offerId.lowercased(),
            senderDeviceId: wire.senderDeviceId,
            senderAlias: String(wire.senderAlias.prefix(120)).isEmpty ? remoteHost : String(wire.senderAlias.prefix(120)),
            senderPlatform: String(wire.senderPlatform.prefix(40)).isEmpty ? "Unknown" : String(wire.senderPlatform.prefix(40)),
            host: remoteHost,
            peerPort: wire.peerPort,
            token: wire.token.lowercased(),
            verificationCode: wire.verificationCode,
            expiresAt: wire.expiresAt,
            files: files
        )

        lock.lock()
        cleanupLocked(now: now)
        guard incomingById[offer.offerId] != nil || incomingById.count < maximumIncomingOffers else {
            lock.unlock()
            return nil
        }
        incomingById[offer.offerId] = offer
        lock.unlock()
        return offer
    }

    func incoming() -> [IncomingPeerOffer] {
        lock.lock()
        cleanupLocked(now: nowMilliseconds())
        let values = incomingById.values.sorted {
            $0.senderAlias.localizedCaseInsensitiveCompare($1.senderAlias) == .orderedAscending
        }
        lock.unlock()
        return values
    }

    func decline(_ offerId: String) {
        lock.lock()
        incomingById.removeValue(forKey: offerId)
        lock.unlock()
    }

    func markIncomingFileComplete(offerId: String, fileId: String) {
        lock.lock()
        if let offer = incomingById[offerId] {
            let remaining = offer.files.filter { $0.id != fileId }
            if remaining.isEmpty {
                incomingById.removeValue(forKey: offerId)
            } else {
                incomingById[offerId] = IncomingPeerOffer(
                    offerId: offer.offerId,
                    senderDeviceId: offer.senderDeviceId,
                    senderAlias: offer.senderAlias,
                    senderPlatform: offer.senderPlatform,
                    host: offer.host,
                    peerPort: offer.peerPort,
                    token: offer.token,
                    verificationCode: offer.verificationCode,
                    expiresAt: offer.expiresAt,
                    files: remaining
                )
            }
        }
        lock.unlock()
    }

    func authorizeOutgoing(offerId: String, fileId: String, authorization: String?) -> Bool {
        let now = nowMilliseconds()
        lock.lock()
        cleanupLocked(now: now)
        guard let grant = outgoingById[offerId], grant.fileIds.contains(fileId) else {
            lock.unlock()
            return false
        }
        lock.unlock()

        guard let authorization else { return false }
        let components = authorization.split(separator: " ", maxSplits: 1)
        guard components.count == 2, components[0].lowercased() == "bearer" else { return false }
        return String(components[1]).lowercased() == grant.token.lowercased()
    }

    func completeOutgoingFile(offerId: String, fileId: String) {
        lock.lock()
        if var grant = outgoingById[offerId] {
            grant.fileIds.remove(fileId)
            if grant.fileIds.isEmpty { outgoingById.removeValue(forKey: offerId) }
            else { outgoingById[offerId] = grant }
        }
        lock.unlock()
    }

    private func cleanupLocked(now: Int64) {
        incomingById = incomingById.filter { $0.value.expiresAt > now }
        outgoingById = outgoingById.filter { $0.value.expiresAt > now && !$0.value.fileIds.isEmpty }
    }

    private func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max)) }.joined()
    }

    private func isHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy { $0.isHexDigit }
    }

    private func offerError(_ message: String) -> NSError {
        NSError(domain: "FTPortal.PeerOffer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum PeerOfferClient {
    static func send(lobby: PeerLobby, files: [SharedFile]) async throws -> PeerOfferWire {
        guard lobby.supportsOffers else {
            throw NSError(domain: "FTPortal.PeerOffer", code: 2, userInfo: [NSLocalizedDescriptionKey: "This lobby only supports the v1 pull flow."])
        }
        let wire = try PeerOfferStore.shared.prepareOutgoing(files: files)
        do {
            guard let url = URL(string: "http://\(lobby.host):\(lobby.peerPort)\(PeerProtocol.offerPathV2)") else {
                throw NSError(domain: "FTPortal.PeerOffer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid peer URL"])
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(PeerProtocol.versionV2, forHTTPHeaderField: "X-FTPortal-Client")
            request.httpBody = try JSONEncoder().encode(wire)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NSError(domain: "FTPortal.PeerOffer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Peer rejected offer with HTTP \(status)"])
            }
            return wire
        } catch {
            PeerOfferStore.shared.cancelOutgoing(wire.offerId)
            throw error
        }
    }
}

enum PeerOfferReceiver {
    static func receiveAll(_ offer: IncomingPeerOffer) async -> PeerOfferReceiveResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FTPortal-Offer-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return PeerOfferReceiveResult(urls: [], directory: nil, failures: [error.localizedDescription])
        }

        var urls: [URL] = []
        var failures: [String] = []
        for file in offer.files {
            do {
                guard let url = URL(string: "http://\(offer.host):\(offer.peerPort)\(PeerProtocol.transferPrefixV2)\(offer.offerId)/\(file.id)") else {
                    throw NSError(domain: "FTPortal.PeerOffer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid URL for \(file.name)"])
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 3600
                request.setValue("Bearer \(offer.token)", forHTTPHeaderField: "Authorization")
                request.setValue(PeerProtocol.versionV2, forHTTPHeaderField: "X-FTPortal-Client")
                let (temporary, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw NSError(domain: "FTPortal.PeerOffer", code: 6, userInfo: [NSLocalizedDescriptionKey: "\(file.name): peer rejected the transfer"])
                }

                let destination = uniqueDestination(directory: directory, name: safeFileName(file.name))
                try FileManager.default.moveItem(at: temporary, to: destination)
                if file.size >= 0 {
                    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    let received = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                    guard received == file.size else {
                        try? FileManager.default.removeItem(at: destination)
                        throw NSError(domain: "FTPortal.PeerOffer", code: 7, userInfo: [NSLocalizedDescriptionKey: "\(file.name): expected \(file.size) bytes, received \(received)"])
                    }
                }
                urls.append(destination)
                PeerOfferStore.shared.markIncomingFileComplete(offerId: offer.offerId, fileId: file.id)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        if urls.isEmpty { try? FileManager.default.removeItem(at: directory) }
        return PeerOfferReceiveResult(urls: urls, directory: urls.isEmpty ? nil : directory, failures: failures)
    }

    private static func safeFileName(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        return leaf.isEmpty ? "FTPortal-download" : leaf
    }

    private static func uniqueDestination(directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let source = name as NSString
        let stem = source.deletingPathExtension
        let ext = source.pathExtension
        var index = 2
        while true {
            let suffix = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(suffix)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
