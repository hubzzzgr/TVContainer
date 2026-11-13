import SwiftUI

@main
struct TVContainerApp: App {
    @StateObject private var library = TVLibrary()
    @StateObject private var receiver = TVReceiverModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ZStack {
                TVHomeView()
                Color.clear.frame(width: 0, height: 0).modifier(TVReceiverPromptModifier())
                Color.clear.frame(width: 0, height: 0).modifier(TVLargeInstallPromptModifier())
            }
                .environmentObject(library).environmentObject(receiver)
                .preferredColorScheme(.dark)
                .onAppear { receiver.attach(library); receiver.setActive(scenePhase != .background) }
                // A tvOS keyboard can cover the root view without backgrounding
                // the app. Keep its pending certificate/password flow alive.
                .onChange(of: scenePhase) { _, phase in receiver.setActive(phase != .background) }
        }
    }
}

@MainActor
final class TVLibrary: ObservableObject {
    @Published private(set) var largeInstallPrompt = false
    @Published private(set) var largeInstallName = ""
    private var largeInstallDecision: CheckedContinuation<Bool, Never>?
    @Published var apps: [TVGuest] = []
    @Published var status = ""
    @Published var busy = false
    @Published var downloading = false
    @Published var downloadProgress = TVDownloadProgress()
    @Published var error: String?
    @Published var certificateInstalled = TVInstaller.hasCertificate()
    private var operation: Task<Void, Never>?
    private var activeDownloadID: UUID?

    init() {
        reload()
        if let message = UserDefaults.standard.string(forKey: "error") {
            error = message
            UserDefaults.standard.removeObject(forKey: "error")
        }
        if UserDefaults.standard.bool(forKey: "SigningInProgress") {
            error = "The last installation was interrupted. Download the app again to retry."
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }
    }

    func reload() {
        let root = TVInstaller.applicationsURL()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        apps = folders.filter { $0.pathExtension == "app" }.compactMap { url in
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
                  let identifier = info["CFBundleIdentifier"] as? String else { return nil }
            return TVGuest(id: url.lastPathComponent,
                name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? identifier,
                bundleID: identifier, version: info["CFBundleShortVersionString"] as? String ?? "",
                icon: TVGuestIcon.load(bundleURL: url, info: info))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        certificateInstalled = TVInstaller.hasCertificate()
    }

    static func remoteURL(_ input: String) throws -> URL {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw TVFailure("Enter a full HTTP or HTTPS download URL.")
        }
        return url
    }

    func install(_ input: String) {
        start {
            let url = try Self.remoteURL(input)
            guard self.certificateInstalled else { throw TVFailure("Import your signing certificate in Settings first.") }
            self.status = "Downloading app…"
            let file = try await self.download(url, limit: .max)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard await self.confirmLargeInstallation(size: size, name: url.lastPathComponent) else { throw CancellationError() }
            try Task.checkCancellation()
            self.status = "Preparing and signing app…"
            UserDefaults.standard.set(true, forKey: "SigningInProgress")
            defer { UserDefaults.standard.removeObject(forKey: "SigningInProgress") }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                TVInstaller.installArchive(file) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            self.reload()
            self.status = "App installed. Open Apps to launch it."
        }
    }

    func importCertificate(_ input: String, password: String) {
        start {
            let url = try Self.remoteURL(input)
            self.status = "Downloading certificate…"
            let file = try await self.download(url, limit: 4 * 1024 * 1024)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            let data = try Data(contentsOf: file)
            try TVInstaller.importCertificate(data, password: password)
            self.reload()
            self.status = "Signing certificate imported."
        }
    }

    func removeCertificate() {
        do {
            try TVInstaller.removeCertificate()
            reload()
            status = "Signing certificate removed."
        } catch { self.error = error.localizedDescription }
    }
    func launch(_ app: TVGuest) {
        guard !busy else { return }
        TVInstaller.launchApp(app.id) { [weak self] error in
            Task { @MainActor in self?.error = error?.localizedDescription }
        }
    }
    func remove(_ app: TVGuest) {
        do { try TVInstaller.removeApp(app.id); reload() }
        catch { self.error = error.localizedDescription }
    }
    func cancelDownload() { if downloading { operation?.cancel() } }

    func confirmLargeInstallation(size: Int64, name: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard size > TVUploadHeader.largeIPAWarningThreshold else { return true }
        guard largeInstallDecision == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                largeInstallDecision = continuation
                largeInstallName = TVTransferProtocol.displayName(name)
                largeInstallPrompt = true
            }
        } onCancel: {
            Task { @MainActor in self.resolveLargeInstallation(false) }
        }
    }
    func resolveLargeInstallation(_ install: Bool) {
        let decision = largeInstallDecision
        largeInstallDecision = nil; largeInstallPrompt = false
        decision?.resume(returning: install)
    }

    private func download(_ url: URL, limit: Int64) async throws -> URL {
        let id = UUID()
        activeDownloadID = id
        downloadProgress = TVDownloadProgress()
        downloading = true
        defer { downloading = false; activeDownloadID = nil }
        return try await TVDownload.fetch(url, limit: limit) { [weak self] update in
            Task { @MainActor in
                guard let self, self.activeDownloadID == id, self.downloading else { return }
                self.downloadProgress = update
            }
        }
    }
    private func start(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        operation = Task {
            defer { busy = false; downloading = false; operation = nil }
            do { try await work() }
            catch is CancellationError { status = "Download cancelled." }
            catch let failure as URLError where failure.code == .cancelled { status = "Download cancelled." }
            catch { self.error = error.localizedDescription; status = "" }
        }
    }
}

struct TVLargeInstallPromptModifier: ViewModifier {
    @EnvironmentObject private var library: TVLibrary
    func body(content: Content) -> some View {
        content.alert("Install large app?", isPresented: Binding(
            get: { library.largeInstallPrompt },
            set: { if !$0 { library.resolveLargeInstallation(false) } })) {
            Button("Install", role: .destructive) { library.resolveLargeInstallation(true) }
            Button("Abort") { library.resolveLargeInstallation(false) }
        } message: {
            Text("\(library.largeInstallName) is larger than 2 GiB. Installing it may take a long time and requires additional storage for extraction and signing. Large apps have not been validated and installation may fail. Continue?")
        }
    }
}
