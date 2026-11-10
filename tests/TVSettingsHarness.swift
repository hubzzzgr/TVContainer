import SwiftUI
import Darwin

// The real Settings view with a deterministic model: no signing identity,
// downloads, keychain access, guest artwork, or runtime bundle hooks.
@MainActor final class TVLibrary: ObservableObject {
    @Published var certificateInstalled = false
    @Published var busy = CommandLine.arguments.contains("--busy")
    func importCertificate(_ url: String, password: String) {}
    func removeCertificate() {}
}
struct TVOperationStatus: View {
    var body: some View { EmptyView() }
}

@main struct SettingsHarness: App {
    @StateObject private var library = TVLibrary()
    private let restarted: Bool
    init() {
        restarted = UserDefaults.standard.integer(forKey: "reexecPID") == Int(getpid())
        let arguments = CommandLine.unsafeArgv
        _ = TVPrepareReexecForTest(Bundle.main.executablePath!, CommandLine.argc, arguments)
    }
    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--reexec-only") {
                VStack {
                    Text(restarted ? "Restarted in same process" : "Ready to restart")
                    Button("Restart") {
                        UserDefaults.standard.set(Int(getpid()), forKey: "reexecPID")
                        UserDefaults.standard.synchronize()
                        let result = TVPerformReexec()
                        fatalError("Re-exec failed: \(result)")
                    }
                }
            } else {
                TVSettingsView().environmentObject(library)
            }
        }
    }
}
