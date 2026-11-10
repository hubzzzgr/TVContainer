import SwiftUI

@main
struct TVContainerApp: App {
    @StateObject private var library = TVLibrary()
    var body: some Scene {
        WindowGroup { TVHomeView().environmentObject(library).preferredColorScheme(.dark) }
    }
}

struct TVGuest: Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let version: String
}

struct TVFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class TVLibrary: ObservableObject {
    @Published var apps: [TVGuest] = []
    @Published var status = ""
    @Published var busy = false
    @Published var downloading = false
    @Published var error: String?
    @Published var certificateInstalled = TVInstaller.hasCertificate()
    private var operation: Task<Void, Never>?

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
                bundleID: identifier, version: info["CFBundleShortVersionString"] as? String ?? "")
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
            self.downloading = true
            let file = try await TVDownload.fetch(url, limit: 2 * 1024 * 1024 * 1024)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            self.downloading = false
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
            self.downloading = true
            let file = try await TVDownload.fetch(url, limit: 4 * 1024 * 1024)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            self.downloading = false
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
