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
        let bookmark: Data?
    }

    private struct StoredEntry: Codable {
        let meta: SharedFile
        let bookmark: Data
    }

    private let lock = NSLock()
    private let stateKey = "FTPortalSharedFiles.v1"
    private var entries: [String: Entry] = [:]
    private var claimed: Set<String> = []

    private init() {
        restore()
    }

    @discardableResult
    func add(url: URL) -> SharedFile {
        let scopeActive = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey, .contentTypeKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let meta = SharedFile(
            id: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            name: values?.name ?? url.lastPathComponent,
            size: Int64(values?.fileSize ?? -1),
            mime: type?.preferredMIMEType ?? "application/octet-stream"
        )

        lock.lock()
        entries[meta.id] = Entry(meta: meta, url: url, securityScopeActive: scopeActive, bookmark: bookmark)
        persistLocked()
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
        persistLocked()
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
        if !removable.isEmpty { persistLocked() }
        lock.unlock()

        for (_, entry) in removable where entry.securityScopeActive {
            entry.url.stopAccessingSecurityScopedResource()
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let saved = try? JSONDecoder().decode([StoredEntry].self, from: data) else { return }

        for stored in saved {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: stored.bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), url.startAccessingSecurityScopedResource() else { continue }

            let bookmark: Data
            if stale {
                bookmark = (try? url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )) ?? stored.bookmark
            } else {
                bookmark = stored.bookmark
            }
            entries[stored.meta.id] = Entry(
                meta: stored.meta,
                url: url,
                securityScopeActive: true,
                bookmark: bookmark
            )
        }

        lock.lock()
        persistLocked()
        lock.unlock()
    }

    private func persistLocked() {
        let saved = entries.values.compactMap { entry -> StoredEntry? in
            guard let bookmark = entry.bookmark, !bookmark.isEmpty else { return nil }
            return StoredEntry(meta: entry.meta, bookmark: bookmark)
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }

    var hasActiveTransfers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !claimed.isEmpty
    }
}
