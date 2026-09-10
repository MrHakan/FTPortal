import Foundation

struct SharedFile: Identifiable, Codable {
    let id: String
    let name: String
    let size: Int64
}

final class PortalStore {
    static let shared = PortalStore()
    private let lock = NSLock()
    private var entries: [String: (meta: SharedFile, url: URL)] = [:]

    @discardableResult
    func add(url: URL) -> SharedFile {
        _ = url.startAccessingSecurityScopedResource()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
        let meta = SharedFile(id: UUID().uuidString.replacingOccurrences(of: "-", with: ""), name: values?.name ?? url.lastPathComponent, size: Int64(values?.fileSize ?? -1))
        lock.lock()
        entries[meta.id] = (meta, url)
        lock.unlock()
        return meta
    }

    func all() -> [SharedFile] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.map { $0.meta }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func item(_ id: String) -> (SharedFile, URL)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id] else { return nil }
        return (entry.meta, entry.url)
    }

    func consume(_ id: String) {
        lock.lock()
        let removed = entries.removeValue(forKey: id)
        lock.unlock()
        removed?.url.stopAccessingSecurityScopedResource()
    }
}
