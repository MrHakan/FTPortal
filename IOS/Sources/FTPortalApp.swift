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

final class AppModel: ObservableObject {
    @Published var status = "Starting host…"
    @Published var files: [SharedFile] = []
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

    func refresh() {
        files = PortalStore.shared.all()
        let urls = PortalServer.localIPv4().map { "http://\($0):\(PortalServer.port)" }
        status = urls.isEmpty ? "Connect this iPhone/iPad to a local network." : urls.joined(separator: "\n") + "\nBonjour: FTPortal._http._tcp.local"
    }

    func keepCurrentTransferAliveBriefly() {
        guard backgroundTask == .invalid else { return }
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
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section("Host") {
                    Text(model.status).font(.system(.body, design: .monospaced))
                    Text("Keep FTPortal active for reliable hosting. iOS may suspend a general-purpose local server after the app is backgrounded; an active transfer gets a short background completion window.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("One-shot shares") {
                    Button("Share a file") { importing = true }
                    if model.files.isEmpty {
                        Text("Nothing pending. FTPortal does not make a persistent copy.").foregroundStyle(.secondary)
                    }
                    ForEach(model.files) { file in
                        VStack(alignment: .leading) {
                            Text(file.name)
                            Text(file.size >= 0 ? "\(file.size) bytes" : "Streaming source").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("FTPortal")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { model.add(url) }
            }
            .onReceive(timer) { _ in model.refresh() }
        }
    }
}
