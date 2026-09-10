import Foundation
import UIKit

struct PeerRemoteFile: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let size: Int64
    let mime: String
}

struct PeerInfo: Codable {
    let protocolName: String
    let deviceId: String
    let lobbyId: String
    let alias: String
    let platform: String
    let peerPort: Int
    let legacyPort: Int
    let lobbyActive: Bool
    let fileCount: Int
    let files: [PeerRemoteFile]
    let compatible: [String]?
    let capabilities: [String]?

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case deviceId, lobbyId, alias, platform, peerPort, legacyPort, lobbyActive, fileCount, files, compatible, capabilities
    }
}

struct PeerLobby: Identifiable, Hashable {
    var id: String { deviceId }
    let deviceId: String
    let lobbyId: String
    let alias: String
    let platform: String
    let host: String
    let peerPort: Int
    let legacyPort: Int
    let files: [PeerRemoteFile]
    let protocolVersion: String
    let capabilities: Set<String>

    var supportsOffers: Bool {
        protocolVersion == PeerProtocol.versionV2 && capabilities.contains(PeerProtocol.capOffers)
    }
}

enum PeerIdentity {
    private static let key = "FTPortalPeerDeviceId"

    static func deviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    static func alias() -> String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone / iPad" : name
    }
}

enum PeerProtocol {
    static let versionV1 = "ftportal/1"
    static let versionV2 = "ftportal/2"
    static let version = versionV2
    static let peerPort = 47_171

    static let infoPathV1 = "/api/ftportal/v1/info"
    static let downloadPrefixV1 = "/api/ftportal/v1/download/"
    static let infoPathV2 = "/api/ftportal/v2/info"
    static let offerPathV2 = "/api/ftportal/v2/offers"
    static let transferPrefixV2 = "/api/ftportal/v2/transfers/"

    // Compatibility aliases for the established direct-pull UI.
    static let infoPath = infoPathV1
    static let downloadPrefix = downloadPrefixV1

    static let capOffers = "offers"
    static let capAcceptDecline = "accept-decline"
    static let capBearerToken = "bearer-token"
    static let capVerificationCode = "verification-code"
    static let capabilitiesV2 = ["lobbies", capOffers, capAcceptDecline, capBearerToken, capVerificationCode]

    static func infoData(legacyPort: Int, version: String = versionV2) -> Data {
        let files = PortalStore.shared.all().map {
            PeerRemoteFile(id: $0.id, name: $0.name, size: $0.size, mime: $0.mime)
        }
        let deviceId = PeerIdentity.deviceId()
        let info = PeerInfo(
            protocolName: version,
            deviceId: deviceId,
            lobbyId: "lobby-\(deviceId)",
            alias: PeerIdentity.alias(),
            platform: "iOS",
            peerPort: peerPort,
            legacyPort: legacyPort,
            lobbyActive: !files.isEmpty,
            fileCount: files.count,
            files: files,
            compatible: version == versionV2 ? [versionV1] : nil,
            capabilities: version == versionV2 ? capabilitiesV2 : nil
        )
        return (try? JSONEncoder().encode(info)) ?? Data("{\"protocol\":\"\(version)\",\"lobbyActive\":false,\"files\":[]}".utf8)
    }
}

enum PeerDiscovery {
    static func discover() async -> [PeerLobby] {
        let ownAddresses = Set(PortalServer.localIPv4())
        let ownId = PeerIdentity.deviceId()
        var candidates = Set<String>()

        for address in ownAddresses {
            let parts = address.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            for last in 1...254 {
                let candidate = "\(prefix).\(last)"
                if !ownAddresses.contains(candidate) { candidates.insert(candidate) }
            }
        }
        if candidates.isEmpty { return [] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.8
        configuration.timeoutIntervalForResource = 1.4
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let hosts = Array(candidates)
        var found: [String: PeerLobby] = [:]
        let batchSize = 32

        for start in stride(from: 0, to: hosts.count, by: batchSize) {
            let end = min(start + batchSize, hosts.count)
            let batch = hosts[start..<end]
            await withTaskGroup(of: PeerLobby?.self) { group in
                for host in batch {
                    group.addTask {
                        await probe(host: host, session: session, ownId: ownId)
                    }
                }
                for await lobby in group {
                    if let lobby, found[lobby.deviceId] == nil {
                        found[lobby.deviceId] = lobby
                    }
                }
            }
        }

        return found.values.sorted {
            $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
        }
    }

    private static func probe(host: String, session: URLSession, ownId: String) async -> PeerLobby? {
        if let v2 = await probeVersion(
            host: host,
            path: PeerProtocol.infoPathV2,
            clientVersion: PeerProtocol.versionV2,
            session: session,
            ownId: ownId
        ) { return v2 }

        return await probeVersion(
            host: host,
            path: PeerProtocol.infoPathV1,
            clientVersion: PeerProtocol.versionV1,
            session: session,
            ownId: ownId
        )
    }

    private static func probeVersion(
        host: String,
        path: String,
        clientVersion: String,
        session: URLSession,
        ownId: String
    ) async -> PeerLobby? {
        guard let url = URL(string: "http://\(host):\(PeerProtocol.peerPort)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientVersion, forHTTPHeaderField: "X-FTPortal-Client")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let info = try JSONDecoder().decode(PeerInfo.self, from: data)
            guard
                (info.protocolName == PeerProtocol.versionV2 || info.protocolName == PeerProtocol.versionV1),
                info.deviceId != ownId,
                info.lobbyActive,
                !info.files.isEmpty
            else { return nil }

            return PeerLobby(
                deviceId: info.deviceId,
                lobbyId: info.lobbyId,
                alias: info.alias,
                platform: info.platform,
                host: host,
                peerPort: (1...65_535).contains(info.peerPort) ? info.peerPort : PeerProtocol.peerPort,
                legacyPort: info.legacyPort,
                files: info.files,
                protocolVersion: info.protocolName,
                capabilities: Set(info.capabilities ?? [])
            )
        } catch {
            return nil
        }
    }
}
