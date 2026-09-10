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

    func add(_ url: URL) {
        PortalStore.shared.add(url: url)
        refresh()
    }

    func clearPending() {
        PortalStore.shared.clearPending()
        refresh()
    }

    func refresh() {
        files = PortalStore.shared.all()
        incomingOffers = PeerOfferStore.shared.incoming()
        let urls = PortalServer.localIPv4().map { "http://\($0):\(PortalServer.legacyPort)" }
        status = urls.isEmpty
            ? "Connect this iPhone/iPad to Wi-Fi or a local hotspot."
            : "Web fallback:\n" + urls.joined(separator: "\n") + "\nPeer protocol: \(PeerProtocol.version) (v1 compatible) on TCP \(PeerProtocol.peerPort)"
    }

    func discoverLobbies() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let found = await PeerDiscovery.discover()
            lobbies = found
            isScanning = false
        }
    }

    func keepCurrentTransferAliveBriefly() {
        guard PortalStore.shared.hasActiveTransfers, backgroundTask == .invalid else { return }
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
    @State private var importing = false
    @State private var confirmClear = false
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section("Host") {
                    Text(model.status).font(.system(.body, design: .monospaced))
                    Text("Selecting a file makes this device visible as an FTPortal lobby. Web browsers keep using the legacy address above.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Incoming transfers") {
                    if model.incomingOffers.isEmpty {
                        Text("No incoming v2 offers.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.incomingOffers) { offer in
                        NavigationLink {
                            IncomingOfferView(offer: offer) {
                                model.refresh()
                                model.discoverLobbies()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(offer.senderAlias)
                                Text("\(offer.senderPlatform) · \(offer.files.count) file\(offer.files.count == 1 ? "" : "s") · code \(offer.verificationCode)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Lobbies") {
                    Button(model.isScanning ? "Scanning…" : "Refresh lobbies") {
                        model.discoverLobbies()
                    }
                    .disabled(model.isScanning)

                    if model.isScanning && model.lobbies.isEmpty {
                        ProgressView("Searching the local network")
                    } else if model.lobbies.isEmpty {
                        Text("No active FTPortal lobbies found.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.lobbies) { lobby in
                        NavigationLink {
                            LobbyView(lobby: lobby, onFinished: {
                                model.refresh()
                                model.discoverLobbies()
                            })
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(lobby.alias)
                                Text("\(lobby.platform) · \(lobby.files.count) file\(lobby.files.count == 1 ? "" : "s") · \(lobby.supportsOffers ? "v2" : "v1") · \(lobby.host)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("My one-shot shares") {
                    Button("Share a file") { importing = true }
                    Button("Clear pending shares", role: .destructive) { confirmClear = true }
                        .disabled(model.files.isEmpty)

                    if model.files.isEmpty {
                        Text("Nothing pending. Add a file to make this device appear as a lobby.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.files) { file in
                        VStack(alignment: .leading) {
                            Text(file.name)
                            Text(file.size >= 0 ? "\(file.size) bytes" : "Streaming source")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("FTPortal")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        model.add(url)
                        model.discoverLobbies()
                    }
                case .failure(let error):
                    model.status = "File selection failed: \(error.localizedDescription)"
                }
            }
            .confirmationDialog(
                "Clear all pending share links? Original files will not be deleted.",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear pending shares", role: .destructive) { model.clearPending() }
            }
            .onReceive(timer) { _ in model.refresh() }
            .task { model.discoverLobbies() }
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
                Text("Connected directly to \(lobby.host):\(lobby.peerPort) using \(lobby.protocolVersion). The original v1 pull path remains available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if lobby.supportsOffers {
                Section("Send") {
                    Button(sendingOffer ? "Sending offer…" : "Send my pending files") {
                        Task { await sendOffer() }
                    }
                    .disabled(sendingOffer || PortalStore.shared.all().isEmpty)
                    Text("The receiver must Accept. FTPortal then transfers only the offered one-shot shares using a short-lived token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Files") {
                ForEach(lobby.files) { file in
                    Button {
                        Task { await download(file) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.name)
                                Text(file.size >= 0 ? "\(file.size) bytes" : "Streaming source")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if downloadingId == file.id { ProgressView() }
                        }
                    }
                    .disabled(downloadingId != nil)
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
        .alert("FTPortal", isPresented: Binding(
            get: { errorMessage != nil || offerMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                    offerMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                errorMessage = nil
                offerMessage = nil
            }
        } message: {
            Text(offerMessage ?? errorMessage ?? "Unknown status")
        }
    }

    @MainActor
    private func sendOffer() async {
        guard !sendingOffer else { return }
        let files = PortalStore.shared.all()
        guard !files.isEmpty else {
            errorMessage = "Add at least one pending share first."
            return
        }
        sendingOffer = true
        defer { sendingOffer = false }
        do {
            let offer = try await PeerOfferClient.send(lobby: lobby, files: files)
            offerMessage = "Offer sent. \(lobby.alias) must Accept. Verification code: \(offer.verificationCode). The offer expires in 5 minutes."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func download(_ file: PeerRemoteFile) async {
        guard downloadingId == nil else { return }
        downloadingId = file.id
        defer { downloadingId = nil }

        guard let url = URL(string: "http://\(lobby.host):\(lobby.peerPort)\(PeerProtocol.downloadPrefixV1)\(file.id)") else {
            errorMessage = "Invalid peer URL"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        request.setValue(PeerProtocol.versionV1, forHTTPHeaderField: "X-FTPortal-Client")

        do {
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "FTPortal", code: 2, userInfo: [NSLocalizedDescriptionKey: "Peer rejected the one-shot transfer."])
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FTPortal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(safeFileName(file.name))
            try FileManager.default.moveItem(at: temporary, to: destination)
            if file.size >= 0 {
                let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                let received = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard received == file.size else {
                    throw NSError(domain: "FTPortal", code: 3, userInfo: [NSLocalizedDescriptionKey: "Expected \(file.size) bytes, received \(received)."])
                }
            }
            export = RemoteExport(urls: [destination], directory: directory, completionMessage: nil)
        } catch {
            errorMessage = error.localizedDescription
            onFinished()
        }
    }

    private func safeFileName(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        return leaf.isEmpty ? "FTPortal-download" : leaf
    }
}

struct IncomingOfferView: View {
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
                Text("\(offer.senderPlatform) · \(offer.host):\(offer.peerPort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Verification code", value: offer.verificationCode)
            }

            Section("Offered files") {
                ForEach(offer.files) { file in
                    VStack(alignment: .leading) {
                        Text(file.name)
                        Text(file.size >= 0 ? "\(file.size) bytes" : "Streaming source")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(receiving ? "Receiving…" : "Accept and receive") {
                    Task { await accept() }
                }
                .disabled(receiving)
                Button("Decline", role: .destructive) {
                    PeerOfferStore.shared.decline(offer.offerId)
                    onFinished()
                    dismiss()
                }
                .disabled(receiving)
            } footer: {
                Text("Compare the six-digit code with the sender if you want to verify you are accepting the intended offer. The offer expires automatically.")
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
        .alert("Transfer status", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown status")
        }
    }

    @MainActor
    private func accept() async {
        guard !receiving else { return }
        receiving = true
        defer { receiving = false }

        let result = await PeerOfferReceiver.receiveAll(offer)
        if result.urls.isEmpty {
            errorMessage = result.failures.first ?? "No files were received."
            onFinished()
            return
        }
        let partialMessage = result.failures.isEmpty
            ? nil
            : "Received \(result.urls.count) file\(result.urls.count == 1 ? "" : "s"); \(result.failures.count) failed and can be retried while the offer remains active."
        if let directory = result.directory {
            export = RemoteExport(urls: result.urls, directory: directory, completionMessage: partialMessage)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { onComplete() }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
