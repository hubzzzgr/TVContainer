import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject private var library: TVLibrary
    @State private var certificateURL = ""
    @State private var password = ""
    @State private var confirmRemove = false
    var body: some View {
        NavigationStack {
            List {
                Section("Signing Certificate") {
                    Label(library.certificateInstalled ? "Signing certificate installed" : "No signing certificate",
                          systemImage: library.certificateInstalled ? "checkmark.seal.fill" : "key")
                        .foregroundStyle(library.certificateInstalled ? .green : .orange)
                    Text("Import Certificate from URL").font(.title2.bold())
                    Text("Use a P12 signing identity from the same developer team used to sign TVContainer. The certificate and password are stored in this Apple TV’s Keychain.").foregroundStyle(.secondary)
                    TextField("https://example.com/certificate.p12", text: $certificateURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(library.busy)
                        .accessibilityIdentifier("certificateURL")
                    SecureField("Certificate password (may be empty)", text: $password)
                        .disabled(library.busy).accessibilityIdentifier("certificatePassword")
                    Button("Download Certificate", systemImage: "key.fill") {
                        library.importCertificate(certificateURL, password: password)
                        password = ""
                    }.disabled(library.busy || certificateURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("downloadCertificate")
                    if library.certificateInstalled {
                        Button("Remove Certificate", role: .destructive) { confirmRemove = true }.disabled(library.busy)
                    }
                    TVOperationStatus()
                }
                // A separate list section stays in the remote's scroll/focus
                // order even when the preceding certificate actions are disabled.
                Section {
                    NavigationLink {
                        TVWorthCheckingOutView()
                    } label: {
                        Label("Worth checking out", systemImage: "qrcode")
                    }
                    .accessibilityIdentifier("worthCheckingOut")
                }
                Section("Local Storage") {
                    Text("tvOS may purge cached apps and guest data when storage is low. Keep your original IPAs and back up important guest data outside Apple TV.").foregroundStyle(.secondary)
                    Text("TVContainer · Standalone · tvOS 17+").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .alert("Remove signing certificate?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { library.removeCertificate() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Import it again before installing or signing more apps.") }
        }
    }
}
