import Foundation

enum TrackedPeerOfferReceiver {
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
            let transferId = TransferCenter.shared.begin(direction: .receive, fileName: file.name, peer: offer.senderAlias, totalBytes: file.size)
            do {
                guard let url = URL(string: "http://\(offer.host):\(offer.peerPort)\(PeerProtocol.transferPrefixV2)\(offer.offerId)/\(file.id)") else {
                    throw NSError(domain: "FTPortal.Offer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL for \(file.name)"])
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 3600
                request.setValue("Bearer \(offer.token)", forHTTPHeaderField: "Authorization")
                request.setValue(PeerProtocol.versionV2, forHTTPHeaderField: "X-FTPortal-Client")
                let destination = uniqueDestination(directory: directory, name: safeFileName(file.name))
                _ = try await ProgressDownloader.download(request: request, to: destination, transferId: transferId)
                if file.size >= 0 {
                    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    let received = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                    guard received == file.size else {
                        try? FileManager.default.removeItem(at: destination)
                        throw NSError(domain: "FTPortal.Offer", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(file.name): expected \(file.size) bytes, received \(received)"])
                    }
                }
                urls.append(destination)
                PeerOfferStore.shared.markIncomingFileComplete(offerId: offer.offerId, fileId: file.id)
                TransferCenter.shared.finish(id: transferId, success: true)
            } catch {
                TransferCenter.shared.finish(id: transferId, success: false, detail: error.localizedDescription)
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
