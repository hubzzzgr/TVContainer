import SwiftUI
import UIKit

struct TVHomeView: View {
    @EnvironmentObject private var library: TVLibrary
    @State private var selectedTab = 0
    @State private var installURL = ""
    @State private var showProjects = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TabView(selection: $selectedTab) {
            TVAppsView(showProjects: $showProjects).tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag(0)
            TVInstallView(url: $installURL).tabItem { Label("Install from URL", systemImage: "arrow.down.circle") }.tag(1)
            TVSettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .disabled(showProjects)
        .overlay {
            ZStack {
                if showProjects {
                    Color.black.opacity(0.65).ignoresSafeArea()
                        .transition(.opacity)
                    TVWorthCheckingOutView()
                        .frame(width: 1400, height: 800)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                        .onExitCommand { showProjects = false }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(showProjects)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.88), value: showProjects)
        .alert("TVContainer", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "tvcontainer", url.host == "install",
                  let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value else { return }
            installURL = value
            selectedTab = 1
        }
    }
}

struct TVAppsView: View {
    @EnvironmentObject private var library: TVLibrary
    @State private var search = ""
    @Binding var showProjects: Bool
    private var filtered: [TVGuest] {
        library.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    HStack {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TVContainer").font(.largeTitle.bold())
                            Text("LiveContainer port for Apple TV").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(library.apps.count) apps").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 20) {
                        TextField("Search apps", text: $search).frame(maxWidth: 700)
                        Button {
                            showProjects = true
                        } label: {
                            Image(systemName: "qrcode")
                                .font(.system(size: 24, weight: .medium))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Worth checking out")
                        .accessibilityIdentifier("worthCheckingOut")
                    }
                    if library.apps.isEmpty {
                        VStack(spacing: 24) {
                            Image(systemName: "appletv").font(.system(size: 80))
                            Text("Make room for your apps").font(.title2.bold())
                            Text("Import a signing certificate in Settings, then choose Install from URL.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        TVAppFlowLayout {
                            ForEach(filtered) { app in
                                NavigationLink { TVAppDetailView(app: app) } label: {
                                    TVGuestCard(app: app)
                                }
                                .buttonStyle(.card)
                                .contextMenu { Button("Launch", systemImage: "play.fill") { library.launch(app) } }
                            }
                        }
                        if filtered.isEmpty { Text("No matching apps.").foregroundStyle(.secondary) }
                    }
                }.padding(64)
            }
        }
    }
}

struct TVAppDetailView: View {
    let app: TVGuest
    @EnvironmentObject private var library: TVLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @FocusState private var launchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let icon = app.icon {
                Image(uiImage: icon).resizable().scaledToFit()
                    .frame(width: 300, height: 300 / app.artworkAspectRatio)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Image(systemName: "app.fill").font(.system(size: 90)).foregroundStyle(.blue)
            }
            Text(app.name).font(.largeTitle.bold())
            Text("\(app.bundleID) · \(app.version)").foregroundStyle(.secondary)
            HStack(spacing: 36) {
                Button("Launch", systemImage: "play.fill") { library.launch(app) }
                    .focused($launchFocused).disabled(library.busy)
                Button("Delete App", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(library.busy)
            }
            Text("Press Play/Pause to launch. Inside a guest app, hold Play/Pause for two seconds to return to TVContainer.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 1000, alignment: .leading)
        }
        .padding(80).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { launchFocused = true }
        .onPlayPauseCommand { library.launch(app) }
        .alert("Delete \(app.name)?", isPresented: $confirmDelete) {
            Button("Delete App and Data", role: .destructive) { library.remove(app); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the installed app and its local container.") }
    }
}

struct TVOperationStatus: View {
    @EnvironmentObject private var library: TVLibrary
    var body: some View {
        if !library.status.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    if library.busy && !library.downloading { ProgressView() }
                    Text(library.status).foregroundStyle(.secondary)
                    if library.downloading { Button("Cancel Download") { library.cancelDownload() } }
                }
                if library.downloading {
                    TVDownloadProgressView(progress: library.downloadProgress)
                }
            }
        }
    }
}

struct TVInstallView: View {
    @EnvironmentObject private var library: TVLibrary
    @Binding var url: String
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Label("Install from URL", systemImage: "arrow.down.circle").font(.largeTitle.bold())
            Text("Enter a direct download link to a decrypted tvOS IPA, or a ZIP containing one IPA.").foregroundStyle(.secondary)
            TextField("https://example.com/app.ipa", text: $url)
                .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(library.busy)
            Button("Download and Install", systemImage: "arrow.down.to.line") { library.install(url) }
                .disabled(library.busy || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !library.certificateInstalled {
                Label("Import a signing certificate in Settings before installing apps.", systemImage: "key").foregroundStyle(.orange)
            }
            TVOperationStatus()
            Spacer()
        }.padding(80).frame(maxWidth: 1400, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct TVSettingsView: View {
    @EnvironmentObject private var library: TVLibrary
    @EnvironmentObject private var receiver: TVReceiverModel
    @State private var certificateURL = ""
    @State private var password = ""
    @State private var confirmRemove = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Text("Settings").font(.largeTitle.bold())
                    TVReceiverSettings(receiver: receiver)
                    Divider().padding(.vertical)
                    Label(library.certificateInstalled ? "Signing certificate installed" : "No signing certificate",
                          systemImage: library.certificateInstalled ? "checkmark.seal.fill" : "key")
                        .foregroundStyle(library.certificateInstalled ? .green : .orange)
                    Text("Import Certificate from URL").font(.title2.bold())
                    Text("Use a P12 signing identity from the same developer team used to sign TVContainer. The certificate and password are stored in this Apple TV’s Keychain.").foregroundStyle(.secondary)
                    TextField("https://example.com/certificate.p12", text: $certificateURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(library.busy)
                    SecureField("Certificate password (may be empty)", text: $password).disabled(library.busy)
                    HStack(spacing: 36) {
                        Button("Download Certificate", systemImage: "key.fill") {
                            library.importCertificate(certificateURL, password: password)
                            password = ""
                        }.disabled(library.busy || certificateURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if library.certificateInstalled {
                            Button("Remove Certificate", role: .destructive) { confirmRemove = true }.disabled(library.busy)
                        }
                    }
                    TVOperationStatus()
                    Divider().padding(.vertical)
                    Text("Local Storage").font(.title2.bold())
                    Text("tvOS may purge cached apps and guest data when storage is low. Keep your original IPAs and back up important guest data outside Apple TV.").foregroundStyle(.secondary)
                    Text("TVContainer · Standalone · tvOS 17+").font(.caption).foregroundStyle(.secondary)
                }.padding(80).frame(maxWidth: 1400, alignment: .leading)
            }
            .alert("Remove signing certificate?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { library.removeCertificate() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Import it again before installing or signing more apps.") }
        }
        .background(TVSettingsRemoteControl { receiver.fingerprintsHidden.toggle() }.frame(width: 0, height: 0))
    }
}

private struct TVSettingsRemoteControl: UIViewControllerRepresentable {
    let action: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(action: action) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.action = action }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.removeGesture() }

    final class Controller: UIViewController {
        var action: () -> Void
        private var gesture: UILongPressGestureRecognizer?
        init(action: @escaping () -> Void) { self.action = action; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard gesture == nil, let window = view.window else { return }
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            gesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
            gesture.minimumPressDuration = 2
            gesture.cancelsTouchesInView = false
            window.addGestureRecognizer(gesture)
            self.gesture = gesture
        }
        override func viewWillDisappear(_ animated: Bool) { removeGesture(); super.viewWillDisappear(animated) }
        func removeGesture() {
            if let gesture { gesture.view?.removeGestureRecognizer(gesture) }
            gesture = nil
        }
        @objc private func held(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { action() }
        }
    }
}
