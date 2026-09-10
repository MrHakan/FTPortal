import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct FTPortalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup { ContentView(model: model) }
            .onChange(of: scenePhase) { phase in
                if phase == .background { model.keepCurrentTransferAliveBriefly() }
                if phase == .active { model.endBackgroundAllowance() }
            }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Starting host…"
    @Published var files: [SharedFile] = []
    @Published var lobbies: [PeerLobby] = []
    @Published var incomingOffers: [IncomingPeerOffer] = []
    @Published var activeTransfers: [TransferSnapshot] = []
    @Published var transferHistory: [TransferHistoryEntry] = []
    @Published var isScanning = false

    let server = PortalServer()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        do {
            try server.start()
            refresh()
        } catch {
            status = "Host failed: \(error.localizedDescription)"
        }
    }

    func add(_ url: URL) { PortalStore.shared.add(url: url); refresh() }
    func clearPending() { PortalStore.shared.clearPending(); refresh() }
    func clearHistory() { TransferCenter.shared.clearHistory(); refresh() }

    func refresh() {
        files = PortalStore.shared.all()
        incomingOffers = PeerOfferStore.shared.incoming()
        activeTransfers = TransferCenter.shared.active()
        transferHistory = TransferCenter.shared.history()
        let urls = PortalServer.localIPv4().map { "http://\($0):\(PortalServer.legacyPort)" }
        status = urls.isEmpty
            ? "Connect this iPhone/iPad to Wi-Fi or a local hotspot."
            : "Web fallback: \(urls.joined(separator: " · "))\nNative peer: \(PeerProtocol.version) · TCP \(PeerProtocol.peerPort)"
    }

    func discoverLobbies() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            lobbies = await PeerDiscovery.discover()
            isScanning = false
        }
    }

    func keepCurrentTransferAliveBriefly() {
        guard !activeTransfers.isEmpty || PortalStore.shared.hasActiveTransfers, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FTPortalTransfer") { [weak self] in
            self?.endBackgroundAllowance()
        }
    }

    func endBackgroundAllowance() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            NavigationStack { HomeView(model: model) }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { NearbyView(model: model) }
                .tabItem { Label("Nearby", systemImage: "dot.radiowaves.left.and.right") }
            NavigationStack { HistoryView(model: model) }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .tint(.indigo)
        .onReceive(timer) { _ in model.refresh() }
        .task { model.discoverLobbies() }
    }
}

struct HomeView: View {
    @ObservedObject var model: AppModel
    @State private var importing = false
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                FTCard {
                    HStack(spacing: 13) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16).fill(Color.indigo.gradient)
                            Image(systemName: "arrow.left.arrow.right").font(.title2.bold()).foregroundStyle(.white)
                        }
                        .frame(width: 54, height: 54)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Ready for local transfer").font(.headline)
                            Text("No cloud. No account. Same-network delivery.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(Color.green).frame(width: 9, height: 9)
                    }
                    Text(model.status).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.top, 12)
                }

                Button { importing = true } label: {
                    Label("Share a file", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.large)

                if !model.activeTransfers.isEmpty {
                    FTCard {
                        Text("Active transfers").font(.headline)
                        ForEach(model.activeTransfers) { transfer in
                            TransferProgressView(transfer: transfer)
                                .padding(.top, 8)
                        }
                    }
                }

                FTCard {
                    Label("iOS background behavior", systemImage: "moon.stars.fill").font(.headline)
                    Text("FTPortal can finish an active transfer during iOS's allowed background window, but iOS does not permit a third-party app to host an arbitrary TCP server indefinitely like Android/Termux. Keep FTPortal active when you need reliable lobby hosting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                }

                FTCard {
                    HStack {
                        Text("Incoming transfers").font(.headline)
                        Spacer()
                        if !model.incomingOffers.isEmpty { Text("\(model.incomingOffers.count)").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4).background(.indigo.opacity(0.15)).clipShape(Capsule()) }
                    }
                    if model.incomingOffers.isEmpty {
                        EmptyLine(text: "No incoming v2 offers.")
                    } else {
                        ForEach(model.incomingOffers) { offer in
                            NavigationLink {
                                IncomingOfferView(model: model, offer: offer) {
                                    model.refresh(); model.discoverLobbies()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "iphone.and.arrow.forward").foregroundStyle(.indigo)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(offer.senderAlias).foregroundStyle(.primary).font(.subheadline.bold())
                                        Text("\(offer.senderPlatform) · \(offer.files.count) file\(offer.files.count == 1 ? "" : "s") · code \(offer.verificationCode)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }

                FTCard {
                    HStack {
                        Text("My one-shot shares").font(.headline)
                        Spacer()
                        Button("Clear", role: .destructive) { confirmClear = true }.disabled(model.files.isEmpty)
                    }
                    if model.files.isEmpty {
                        EmptyLine(text: "Nothing pending. Share a file to make this device appear as a lobby.")
                    } else {
                        ForEach(model.files) { file in
                            FileLine(name: file.name, detail: file.size >= 0 ? formatBytes(file.size) : "Streaming source", icon: "doc.fill")
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("FTPortal")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.add(url); model.discoverLobbies() }
            case .failure(let error): model.status = "File selection failed: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Clear all pending share links? Original files will not be deleted.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear pending shares", role: .destructive) { model.clearPending() }
        }
    }
}

struct NearbyView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                FTCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nearby lobbies").font(.title3.bold())
                            Text("v2 supports offers; v1 remains fully compatible.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.discoverLobbies() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.bordered).disabled(model.isScanning)
                    }
                    if model.isScanning { ProgressView("Scanning local network…").padding(.top, 10) }
                }

                if !model.isScanning && model.lobbies.isEmpty {
                    FTCard { EmptyLine(text: "No active FTPortal lobbies found on this local network.") }
                }

                ForEach(model.lobbies) { lobby in
                    NavigationLink {
                        LobbyView(model: model, lobby: lobby) {
                            model.refresh(); model.discoverLobbies()
                        }
                    } label: {
                        FTCard {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(.indigo.opacity(0.14))
                                    Image(systemName: platformIcon(lobby.platform)).foregroundStyle(.indigo)
                                }.frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(lobby.alias).font(.headline).foregroundStyle(.primary)
                                    Text("\(lobby.platform) · \(lobby.files.count) file\(lobby.files.count == 1 ? "" : "s") · \(lobby.supportsOffers ? "v2" : "v1")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(lobby.host).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Nearby")
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if model.transferHistory.isEmpty {
                    FTCard { EmptyLine(text: "No transfers yet. Completed and failed sends/receives will appear here.") }
                }
                ForEach(model.transferHistory) { entry in
                    FTCard {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: entry.direction == .receive ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .font(.title2).foregroundStyle(entry.success ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.fileName).font(.subheadline.bold())
                                Text("\(entry.direction == .receive ? "From" : "To") \(entry.peer)").font(.caption).foregroundStyle(.secondary)
                                Text("\(formatBytes(entry.bytesTransferred)) · \(formatDate(entry.finishedAt))\(entry.success ? "" : " · Failed")")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                if let detail = entry.detail, !entry.success { Text(detail).font(.caption2).foregroundStyle(.red) }
                            }
                            Spacer()
                        }
                    }
                }
            }.padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("History")
        .toolbar {
            if !model.transferHistory.isEmpty { Button("Clear", role: .destructive) { model.clearHistory() } }
        }
    }
}

private struct RemoteExport: Identifiable {
    let id = UUID()
    let urls: [URL]
    let directory: URL
    let completionMessage: String?
}

struct LobbyView: View {
    @ObservedObject var model: AppModel
    let lobby: PeerLobby
    let onFinished: () -> Void
    @State private var downloadingId: String?
    @State private var sendingOffer = false
    @State private var export: RemoteExport?
    @State private var errorMessage: String?
    @State private var offerMessage: String?

    var body: some View {
        List {
            Section {
                Label("Direct · \(lobby.protocolVersion)", systemImage: "bolt.horizontal.circle.fill")
                Text("\(lobby.host):\(lobby.peerPort) · the original v1 pull path stays available.").font(.caption).foregroundStyle(.secondary)
            }
            if let active = model.activeTransfers.first(where: { $0.peer == lobby.alias }) {
                Section("Transfer") { TransferProgressView(transfer: active) }
            }
            if lobby.supportsOffers {
                Section("Send") {
                    Button(sendingOffer ? "Sending offer…" : "Send my pending files") { Task { await sendOffer() } }
                        .disabled(sendingOffer || PortalStore.shared.all().isEmpty)
                    Text("The receiver must Accept. The offer uses a short-lived token and expires automatically.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Files") {
                ForEach(lobby.files) { file in
                    Button { Task { await download(file) } } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.name)
                                Text(file.size >= 0 ? formatBytes(file.size) : "Streaming source").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if downloadingId == file.id { ProgressView() } else { Image(systemName: "arrow.down.circle") }
                        }
                    }.disabled(downloadingId != nil)
                }
            }
        }
        .navigationTitle(lobby.alias)
        .sheet(item: $export) { item in
            ShareSheet(urls: item.urls) {
                try? FileManager.default.removeItem(at: item.directory)
                export = nil
                if let message = item.completionMessage { errorMessage = message }
                onFinished()
            }
        }
        .alert("FTPortal", isPresented: Binding(get: { errorMessage != nil || offerMessage != nil }, set: { if !$0 { errorMessage = nil; offerMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil; offerMessage = nil }
        } message: { Text(offerMessage ?? errorMessage ?? "Unknown status") }
    }

    @MainActor private func sendOffer() async {
        guard !sendingOffer else { return }
        let files = PortalStore.shared.all()
        guard !files.isEmpty else { errorMessage = "Add at least one pending share first."; return }
        sendingOffer = true
        defer { sendingOffer = false }
        do {
            let offer = try await PeerOfferClient.send(lobby: lobby, files: files)
            offerMessage = "Offer sent. Verification code: \(offer.verificationCode). The receiver must Accept within 5 minutes."
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func download(_ file: PeerRemoteFile) async {
        guard downloadingId == nil else { return }
        downloadingId = file.id
        defer { downloadingId = nil; model.refresh() }
        guard let url = URL(string: "http://\(lobby.host):\(lobby.peerPort)\(PeerProtocol.downloadPrefixV1)\(file.id)") else { errorMessage = "Invalid peer URL"; return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FTPortal-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent(safeFileName(file.name))
        let transferId = TransferCenter.shared.begin(direction: .receive, fileName: file.name, peer: lobby.alias, totalBytes: file.size)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var request = URLRequest(url: url)
            request.timeoutInterval = 3600
            request.setValue(PeerProtocol.versionV1, forHTTPHeaderField: "X-FTPortal-Client")
            _ = try await ProgressDownloader.download(request: request, to: destination, transferId: transferId)
            if file.size >= 0 {
                let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                let received = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard received == file.size else { throw NSError(domain: "FTPortal", code: 3, userInfo: [NSLocalizedDescriptionKey: "Expected \(file.size) bytes, received \(received)."] ) }
            }
            TransferCenter.shared.finish(id: transferId, success: true)
            export = RemoteExport(urls: [destination], directory: directory, completionMessage: nil)
        } catch {
            TransferCenter.shared.finish(id: transferId, success: false, detail: error.localizedDescription)
            try? FileManager.default.removeItem(at: directory)
            errorMessage = error.localizedDescription
            onFinished()
        }
    }

    private func safeFileName(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent.replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        return leaf.isEmpty ? "FTPortal-download" : leaf
    }
}

struct IncomingOfferView: View {
    @ObservedObject var model: AppModel
    let offer: IncomingPeerOffer
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var receiving = false
    @State private var export: RemoteExport?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Sender") {
                Text(offer.senderAlias)
                Text("\(offer.senderPlatform) · \(offer.host):\(offer.peerPort)").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Verification code", value: offer.verificationCode)
            }
            if let active = model.activeTransfers.first(where: { $0.peer == offer.senderAlias }) {
                Section("Transfer") { TransferProgressView(transfer: active) }
            }
            Section("Offered files") {
                ForEach(offer.files) { file in FileLine(name: file.name, detail: file.size >= 0 ? formatBytes(file.size) : "Streaming source", icon: "doc.fill") }
            }
            Section {
                Button(receiving ? "Receiving…" : "Accept and receive") { Task { await accept() } }.disabled(receiving)
                Button("Decline", role: .destructive) { PeerOfferStore.shared.decline(offer.offerId); onFinished(); dismiss() }.disabled(receiving)
            } footer: {
                Text("Compare the six-digit code with the sender if you want to verify the intended offer.")
            }
        }
        .navigationTitle("Incoming transfer")
        .sheet(item: $export) { item in
            ShareSheet(urls: item.urls) {
                try? FileManager.default.removeItem(at: item.directory)
                export = nil
                if let message = item.completionMessage { errorMessage = message }
                onFinished()
            }
        }
        .alert("Transfer status", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown status") }
    }

    @MainActor private func accept() async {
        guard !receiving else { return }
        receiving = true
        defer { receiving = false; model.refresh() }
        let result = await TrackedPeerOfferReceiver.receiveAll(offer)
        if result.urls.isEmpty { errorMessage = result.failures.first ?? "No files were received."; onFinished(); return }
        let partial = result.failures.isEmpty ? nil : "Received \(result.urls.count) file\(result.urls.count == 1 ? "" : "s"); \(result.failures.count) failed and can be retried while the offer remains active."
        if let directory = result.directory { export = RemoteExport(urls: result.urls, directory: directory, completionMessage: partial) }
    }
}

struct TransferProgressView: View {
    let transfer: TransferSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(transfer.fileName).font(.subheadline.bold()).lineLimit(1)
                Spacer()
                Text(transfer.progress.map { "\(Int($0 * 100))%" } ?? "Streaming").font(.caption.bold()).foregroundStyle(.indigo)
            }
            if let progress = transfer.progress { ProgressView(value: progress).tint(.indigo) } else { ProgressView().tint(.indigo) }
            HStack {
                Text(formatSpeed(transfer.bytesPerSecond))
                if let eta = transfer.etaSeconds { Text("ETA \(formatDuration(eta))") }
                Spacer()
                Text(formatBytes(transfer.bytesTransferred))
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct FileLine: View {
    let name: String
    let detail: String
    let icon: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.indigo).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) { Text(name).font(.subheadline); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }
}

struct EmptyLine: View {
    let text: String
    var body: some View { Text(text).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8) }
}

struct FTCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onComplete: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in DispatchQueue.main.async { onComplete() } }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file) }
private func formatSpeed(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 1 else { return "Measuring…" }
    let mb = bytesPerSecond / 1_048_576
    return mb >= 0.1 ? String(format: "%.2f MB/s", mb) : String(format: "%.0f KB/s", bytesPerSecond / 1024)
}
private func formatDuration(_ seconds: Int64) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
}
private func formatDate(_ milliseconds: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
}
private func platformIcon(_ platform: String) -> String {
    let lower = platform.lowercased()
    if lower.contains("windows") { return "desktopcomputer" }
    if lower.contains("android") { return "iphone" }
    return "iphone"
}
