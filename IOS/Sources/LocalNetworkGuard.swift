import Foundation

/// Keeps the native iOS listener local-only without assuming every private
/// address is reachable from the current bearer. VPN interfaces are not part
/// of PortalServer.localIPv4(), so the admission set follows active Wi-Fi/AP
/// interfaces and uses a bounded /24 fallback like discovery.
enum LocalNetworkGuard {
    static func isAllowed(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value.isEmpty || value == "localhost" || value == "127.0.0.1" { return true }
        guard let client = octets(value), isPrivate(client) else { return false }

        return PortalServer.localIPv4().contains { address in
            guard let local = octets(address) else { return false }
            return local[0] == client[0] && local[1] == client[1] && local[2] == client[2]
        }
    }

    private static func octets(_ value: String) -> [UInt8]? {
        let pieces = value.split(separator: ".")
        guard pieces.count == 4 else { return nil }
        let result = pieces.compactMap { UInt8($0) }
        return result.count == 4 ? result : nil
    }

    private static func isPrivate(_ address: [UInt8]) -> Bool {
        address[0] == 10 ||
        (address[0] == 172 && (16...31).contains(address[1])) ||
        (address[0] == 192 && address[1] == 168)
    }
}
