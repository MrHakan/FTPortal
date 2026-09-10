import Foundation

enum TransferDirection: String, Codable {
    case send
    case receive
}

struct TransferSnapshot: Identifiable {
    let id: String
    let direction: TransferDirection
    let fileName: String
    let peer: String
    let bytesTransferred: Int64
    let totalBytes: Int64
    let progress: Double?
    let bytesPerSecond: Double
    let etaSeconds: Int64?
    let startedAt: Int64
}

struct TransferHistoryEntry: Identifiable, Codable {
    let id: String
    let direction: TransferDirection
    let fileName: String
    let peer: String
    let bytesTransferred: Int64
    let totalBytes: Int64
    let startedAt: Int64
    let finishedAt: Int64
    let success: Bool
    let detail: String?
}

private final class MutableTransfer {
    let id: String
    let direction: TransferDirection
    let fileName: String
    let peer: String
    let totalBytes: Int64
    let startedAt: Int64
    var bytesTransferred: Int64 = 0
    var lastSampleAt: Int64
    var lastSampleBytes: Int64 = 0
    var smoothedBytesPerSecond: Double = 0

    init(id: String, direction: TransferDirection, fileName: String, peer: String, totalBytes: Int64, startedAt: Int64) {
        self.id = id
        self.direction = direction
        self.fileName = fileName
        self.peer = peer
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.lastSampleAt = startedAt
    }
}

final class TransferCenter {
    static let shared = TransferCenter()
    private let lock = NSLock()
    private var activeById: [String: MutableTransfer] = [:]
    private var historyEntries: [TransferHistoryEntry] = []
    private let historyKey = "ftportal.transfer.history.v1"
    private let maximumHistory = 100

    private init() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([TransferHistoryEntry].self, from: data) {
            historyEntries = Array(decoded.prefix(maximumHistory))
        }
    }

    func begin(direction: TransferDirection, fileName: String, peer: String, totalBytes: Int64) -> String {
        let id = UUID().uuidString
        let now = Self.nowMilliseconds()
        let transfer = MutableTransfer(
            id: id,
            direction: direction,
            fileName: fileName.isEmpty ? "Unnamed file" : fileName,
            peer: peer.isEmpty ? "Local network peer" : peer,
            totalBytes: totalBytes,
            startedAt: now
        )
        lock.lock()
        activeById[id] = transfer
        lock.unlock()
        return id
    }

    func update(id: String, bytes: Int64) {
        let now = Self.nowMilliseconds()
        lock.lock()
        defer { lock.unlock() }
        guard let transfer = activeById[id] else { return }
        let absolute = max(0, bytes)
        let deltaBytes = absolute - transfer.lastSampleBytes
        let deltaMs = now - transfer.lastSampleAt
        transfer.bytesTransferred = absolute
        if deltaBytes >= 0 && deltaMs >= 180 {
            let instant = Double(deltaBytes) * 1000 / Double(deltaMs)
            transfer.smoothedBytesPerSecond = transfer.smoothedBytesPerSecond <= 0
                ? instant
                : transfer.smoothedBytesPerSecond * 0.72 + instant * 0.28
            transfer.lastSampleAt = now
            transfer.lastSampleBytes = absolute
        }
    }

    func finish(id: String, success: Bool, detail: String? = nil) {
        lock.lock()
        guard let transfer = activeById.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        let entry = TransferHistoryEntry(
            id: transfer.id,
            direction: transfer.direction,
            fileName: transfer.fileName,
            peer: transfer.peer,
            bytesTransferred: transfer.bytesTransferred,
            totalBytes: transfer.totalBytes,
            startedAt: transfer.startedAt,
            finishedAt: Self.nowMilliseconds(),
            success: success,
            detail: detail.map { String($0.prefix(240)) }
        )
        historyEntries.insert(entry, at: 0)
        if historyEntries.count > maximumHistory {
            historyEntries.removeLast(historyEntries.count - maximumHistory)
        }
        let historyCopy = historyEntries
        lock.unlock()
        persist(historyCopy)
    }

    func active() -> [TransferSnapshot] {
        lock.lock()
        let result = activeById.values.map { transfer -> TransferSnapshot in
            let total = transfer.totalBytes
            let bytes = transfer.bytesTransferred
            let speed = transfer.smoothedBytesPerSecond
            let progress = total > 0 ? min(1, Double(bytes) / Double(total)) : nil
            let eta: Int64? = total > 0 && speed > 1 && bytes < total
                ? max(0, Int64(Double(total - bytes) / speed))
                : nil
            return TransferSnapshot(
                id: transfer.id,
                direction: transfer.direction,
                fileName: transfer.fileName,
                peer: transfer.peer,
                bytesTransferred: bytes,
                totalBytes: total,
                progress: progress,
                bytesPerSecond: speed,
                etaSeconds: eta,
                startedAt: transfer.startedAt
            )
        }.sorted { $0.startedAt < $1.startedAt }
        lock.unlock()
        return result
    }

    func history() -> [TransferHistoryEntry] {
        lock.lock()
        let result = historyEntries
        lock.unlock()
        return result
    }

    func clearHistory() {
        lock.lock()
        historyEntries.removeAll()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    private func persist(_ entries: [TransferHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
