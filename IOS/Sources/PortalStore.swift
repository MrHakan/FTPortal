import Foundation
import UniformTypeIdentifiers

struct SharedFile: Identifiable, Codable {
    let id: String
    let name: String
    let size: Int64
    let mime: String
}

final class PortalStore {
    static let shared = PortalStore()

    private struct Entry {
        let meta: SharedFile
        let url: URL
        let securityScopeActive: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var claimed: Set<String> = []

    @discardableResult
    func add(url: URL) -> SharedFile {
        let scopeActive = url.startAccessingSecurityScopedResource()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey, .contentTypeKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let meta = SharedFile(
            id: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            name: values?.name ?? url.lastPathComponent,
            size: Int64(values?.fileSize ?? -1),
            mime: type?.preferredMIMEType ?? "application/octet-stream"
        )

        lock.lock()
        entries[meta.id] = Entry(meta: meta, url: url, securityScopeActive: scopeActive)
        lock.unlock()
        return meta
    }

    func all() -> [SharedFile] {
        lock.lock()
        defer { lock.unlock() }
        return entries
            .filter { !claimed.contains($0.key) }
            .map { $0.value.meta }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Atomically reserves a one-shot share so only one transfer can own it at a time.
    func claim(_ id: String) -> (SharedFile, URL)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id], !claimed.contains(id) else { return nil }
        claimed.insert(id)
        return (entry.meta, entry.url)
    }

    func release(_ id: String) {
        lock.lock()
        claimed.remove(id)
        lock.unlock()
    }

    func consume(_ id: String) {
        lock.lock()
        claimed.remove(id)
        let removed = entries.removeValue(forKey: id)
        lock.unlock()

        if let removed, removed.securityScopeActive {
            removed.url.stopAccessingSecurityScopedResource()
        }
    }

    func clearPending() {
        lock.lock()
        let removable: [(String, Entry)] = entries.compactMap { key, entry in
            claimed.contains(key) ? nil : (key, entry)
        }
        for (id, _) in removable { entries.removeValue(forKey: id) }
        lock.unlock()

        for (_, entry) in removable where entry.securityScopeActive {
            entry.url.stopAccessingSecurityScopedResource()
        }
    }

    var hasActiveTransfers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !claimed.isEmpty
    }
}
