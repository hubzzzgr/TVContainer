import SwiftUI
import UIKit

struct TVReceiverPrompt: Identifiable {
    enum Kind { case pair, ipa, certificate }
    let id: UUID
    let kind: Kind
    let title: String
    let message: String
    var action: String { kind == .pair ? "Pair" : kind == .ipa ? "Install" : "Import" }
}

@MainActor
final class TVReceiverModel: ObservableObject {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "sideTVStoreTCPEnabled"); reconcile() }
    }
    @Published private(set) var prompt: TVReceiverPrompt?
    let server: TVTCPReceiver
    private weak var library: TVLibrary?
    private var active = false
    private var transfer: UUID?
    private var decision: CheckedContinuation<(Bool, String), Never>?

    init() {
        enabled = UserDefaults.standard.bool(forKey: "sideTVStoreTCPEnabled")
        server = TVTCPReceiver(deviceName: TVReceiverDeviceName() ?? "",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unavailable")
        server.pair = { [weak self] id, name, fingerprint in
            guard let self, self.enabled, self.active, self.transfer == nil,
                  self.library?.busy == false, self.library?.error == nil, self.prompt == nil else { return false }
            let message = "SideTVStore on \(name) wants to pair. Compare these certificate fingerprints on both devices before approving.\n\nPhone: \(TVReceiverKeychain.displayFingerprint(fingerprint))\n\nApple TV: \(TVReceiverKeychain.displayFingerprint(self.server.fingerprint))"
            return await self.ask(.init(id: id, kind: .pair, title: "Pair with SideTVStore?", message: message)).0
        }
        server.reserve = { [weak self] id, header in
            guard let self, self.active, self.enabled, let library = self.library else { return "TVContainer is not ready to receive files." }
            guard !library.busy, library.error == nil, self.transfer == nil, self.prompt == nil else { return "TVContainer is busy. Try again when the current operation finishes." }
            if header.action == "uploadP12" && TVInstaller.hasCertificate() { return "A signing certificate is already installed. It was not replaced." }
            if header.action == "uploadIPA" && !TVInstaller.hasCertificate() { return "Import a signing certificate before sending apps." }
            self.transfer = id; library.busy = true
            library.status = "Receiving \(header.filename) from SideTVStore…"
            return nil
        }
        server.upload = { [weak self] id, header, file in
            guard let self else { return .failure("TVContainer is unavailable.") }
            return await self.importUpload(id: id, header: header, file: file)
        }
        server.release = { [weak self] id in
            guard let self, self.transfer == id else { return }
            self.transfer = nil; self.library?.busy = false
            if self.library?.status.hasPrefix("Receiving ") == true { self.library?.status = "Transfer ended." }
        }
        server.disconnected = { [weak self] id in
            guard let self else { return }
            if self.prompt?.id == id { self.resolve(approved: false) }
        }
    }
    func attach(_ library: TVLibrary) { self.library = library; reconcile() }
    func setActive(_ active: Bool) { self.active = active; reconcile() }
    func changePort(_ port: UInt16?) {
        resolve(approved: false)
        server.configurePort(port)
        reconcile()
    }
    private func reconcile() {
        if enabled && active && library != nil {
            server.updateDeviceName(TVReceiverDeviceName() ?? "")
            server.start()
        }
        else { resolve(approved: false); server.stop() }
    }
    func forgetPeers() {
        resolve(approved: false); server.stop()
        do { try server.keychain.forgetPeers(); reconcile() }
        catch { library?.error = error.localizedDescription }
    }
    private func ask(_ request: TVReceiverPrompt) async -> (Bool, String) {
        guard prompt == nil, enabled, active, !Task.isCancelled else { return (false, "") }
        return await withCheckedContinuation { continuation in
            decision = continuation; prompt = request
            DispatchQueue.main.asyncAfter(deadline: .now() + (request.kind == .certificate ? 180 : 60)) { [weak self] in
                if self?.prompt?.id == request.id { self?.resolve(approved: false) }
            }
        }
    }
    func resolve(approved: Bool, password: String = "") {
        let continuation = decision
        decision = nil; prompt = nil
        continuation?.resume(returning: (approved, approved ? password : ""))
    }
    private func importUpload(id: UUID, header: TVUploadHeader, file: URL) async -> TVTransferResponse {
        guard transfer == id, enabled, active, let library, !Task.isCancelled else { return .failure("Transfer cancelled.") }
        do {
            if header.action == "uploadIPA" {
                library.status = "Checking incoming app…"
                let name = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    TVInstaller.incomingAppName(file) { name, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let name { continuation.resume(returning: name) }
                        else { continuation.resume(throwing: TVTransferFailure("The IPA contains no readable app.")) }
                    }
                }
                guard enabled, active, !Task.isCancelled else { throw CancellationError() }
                let approved = await ask(.init(id: id, kind: .ipa, title: "Install incoming app?",
                    message: "SideTVStore sent \(TVTransferProtocol.displayName(name)). Install it in TVContainer?"))
                guard approved.0, !Task.isCancelled else { library.status = "Incoming app cancelled."; return .failure("Installation cancelled on Apple TV.") }
                library.status = "Preparing and signing incoming app…"
                UserDefaults.standard.set(true, forKey: "SigningInProgress")
                defer { UserDefaults.standard.removeObject(forKey: "SigningInProgress") }
                // Once confirmed, retain the source until the native installer
                // finishes, even if the connection or listener is stopped.
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    TVInstaller.installArchive(file) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                library.reload(); library.status = "Incoming app installed."
                return .init(ok: true, message: "App installed in TVContainer.")
            }
            guard !TVInstaller.hasCertificate() else { return .failure("A signing certificate is already installed. It was not replaced.") }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.first == 0x30 else { throw TVTransferFailure("The incoming file is not a PKCS#12 signing identity.") }
            let approved = await ask(.init(id: id, kind: .certificate, title: "Import signing certificate?",
                message: "SideTVStore sent \(header.filename). Enter its P12 password, or leave the field empty if it has none. The signing identity will be stored in this Apple TV’s Keychain."))
            guard approved.0, !Task.isCancelled else { library.status = "Incoming certificate cancelled."; return .failure("Certificate import cancelled on Apple TV.") }
            try TVInstaller.importCertificateIfAbsent(data, password: approved.1)
            library.reload(); library.status = "Incoming signing certificate imported."
            return .init(ok: true, message: "Signing certificate imported.")
        } catch is CancellationError {
            library.status = "Incoming transfer cancelled."
            return .failure("Transfer cancelled.")
        } catch {
            library.status = "Incoming transfer failed."
            return .failure(error.localizedDescription)
        }
    }
}

struct TVReceiverPromptModifier: ViewModifier {
    @EnvironmentObject private var receiver: TVReceiverModel
    @State private var password = ""
    func body(content: Content) -> some View {
        content.alert(receiver.prompt?.title ?? "SideTVStore", isPresented: Binding(
            get: { receiver.prompt != nil }, set: { if !$0 { receiver.resolve(approved: false); password = "" } }),
            presenting: receiver.prompt) { prompt in
                if prompt.kind == .certificate {
                    SecureField("P12 password (may be empty)", text: $password)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button(prompt.action) { receiver.resolve(approved: true, password: password); password = "" }
                Button("Cancel", role: .cancel) { receiver.resolve(approved: false); password = "" }
            } message: { prompt in Text(prompt.message) }
            .onChange(of: receiver.prompt?.id) { _, _ in password = "" }
    }
}

struct TVReceiverSettings: View {
    @ObservedObject var receiver: TVReceiverModel
    @ObservedObject private var server: TVTCPReceiver
    @State private var forget = false
    @State private var editPort = false
    @State private var portText = ""
    @State private var portError: String?
    init(receiver: TVReceiverModel) { self.receiver = receiver; server = receiver.server }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("SideTVStore TCP Server").font(.title2.bold())
            Toggle("Receive from SideTVStore", isOn: $receiver.enabled)
            Label(server.status, systemImage: server.running ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(server.running ? .green : .red)
            Label(server.connected ? "SideTVStore connected" : "SideTVStore disconnected",
                  systemImage: server.connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(server.connected ? .green : .red)
            Text("Device: \(server.deviceName.isEmpty ? "Unavailable" : server.deviceName)")
            Text("TCP port: \(server.port.map(String.init) ?? "—")").monospacedDigit()
            if receiver.enabled {
                Text(server.port == nil ? "The TCP port appears after the listener starts successfully." : "Enter this port in SideTVStore for this paired Apple TV. If it changes, update SideTVStore’s port field.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                Button("Change TCP Port") {
                    portText = server.requestedPort.map(String.init) ?? ""
                    portError = nil; editPort = true
                }
                Button("Use Automatic Port") { portError = nil; receiver.changePort(nil) }
            }
            .disabled(!receiver.enabled)
            if let portError { Text(portError).foregroundStyle(.red) }
            Text("Changing the port disconnects transfers. The last successfully bound port is reused on restart.")
                .font(.caption).foregroundStyle(.secondary)
            if !server.fingerprint.isEmpty {
                Text("TLS fingerprint: \(TVReceiverKeychain.displayFingerprint(server.fingerprint))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text("Keep TVContainer’s launcher open and this server enabled. In SideTVStore, pair or select this TV in the Apple TV tab, then open Settings → TVContainer, choose that paired TV, enter the TCP port shown here, and connect. Both devices need the same reachable local network and Local Network access.")
                .foregroundStyle(.secondary)
            Text("First approve the TV fingerprint on iPhone, then approve the phone fingerprint on Apple TV. Developer-device pairing does not authorize transfers. Confirm each app or certificate import separately. The connection checkmark appears only while an authenticated TLS connection is open; it clears after each upload connection closes.")
                .foregroundStyle(.secondary)
            Button("Forget Paired Devices") { forget = true }
        }
        .focusSection()
        .alert("Change TCP Port", isPresented: $editPort) {
            TextField("1–65535", text: $portText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Use Port") {
                let value = portText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let port = UInt16(value), port > 0 else {
                    portError = "Enter a whole TCP port number from 1 to 65535."; return
                }
                portError = nil; receiver.changePort(port)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Choose a port from 1 to 65535. Update SideTVStore’s port field after it binds successfully. Active transfers will disconnect.") }
        .alert("Forget paired devices?", isPresented: $forget) {
            Button("Forget", role: .destructive) { receiver.forgetPeers() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("SideTVStore will need pairing approval again. Your signing certificate is kept.") }
    }
}
