import Foundation
import Network
import Security
import Combine

@MainActor
final class TVTCPReceiver: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var port: UInt16?
    @Published private(set) var fingerprint = ""
    let deviceName: String
    let appVersion: String
    let keychain: TVReceiverKeychain
    var pair: ((UUID, String, String) async -> Bool)?
    var reserve: ((UUID, TVUploadHeader) -> String?)?
    var upload: ((UUID, TVUploadHeader, URL) async -> TVTransferResponse)?
    var release: ((UUID) -> Void)?
    var disconnected: ((UUID) -> Void)?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var readyWaiters: [UUID: (Bool) -> Void] = [:]
    private let advertise: Bool
    let temporaryDirectory: URL

    init(deviceName: String, appVersion: String, keychain: TVReceiverKeychain = TVReceiverKeychain(), advertise: Bool = true,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("TVContainerReceiver", isDirectory: true)) {
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.keychain = keychain
        self.advertise = advertise
        self.temporaryDirectory = temporaryDirectory
    }
    var txtRecords: [String: String] { ["deviceName": deviceName, "appVersion": appVersion, "protocol": "1"] }

    func start() {
        guard listener == nil else { return }
        status = "Starting…"
        do {
            // Remove only this receiver's private staging directory. Never do so
            // while a confirmed native install is still retaining its source.
            if tasks.isEmpty { try? FileManager.default.removeItem(at: temporaryDirectory) }
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let identity = try keychain.identity(deviceName: deviceName)
            fingerprint = try TVReceiverKeychain.fingerprint(identity)
            let tls = NWProtocolTLS.Options()
            guard let localIdentity = sec_identity_create(identity) else { throw TVTransferFailure("TLS identity is unavailable.") }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
            sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
            sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
                let peerTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                Task { @MainActor [weak self] in
                    guard let self, self.listener != nil, let peer = TVReceiverKeychain.peer(peerTrust) else { complete(false); return }
                    do {
                        if try self.keychain.trustedPeers().contains(peer.fingerprint) { complete(true); return }
                        // The TLS verification callback doesn't expose a connection
                        // ID; a unique approval ID avoids trusting another handshake.
                        let approvalID = UUID()
                        guard await self.pair?(approvalID, peer.name, peer.fingerprint) == true,
                              self.listener != nil else { complete(false); return }
                        try self.keychain.trust(peer.fingerprint)
                        complete(true)
                    } catch { complete(false) }
                }
            }, .main)
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            let parameters = NWParameters(tls: tls, tcp: tcp)
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            if advertise {
                listener.service = NWListener.Service(name: deviceName, type: TVTransferProtocol.service,
                    txtRecord: NWTXTRecord(txtRecords))
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.running = true; self.port = listener.port?.rawValue; self.status = "Running"
                    case .failed: self.stop(message: "Failed to start. Check Local Network permission, then toggle the server off and on.")
                    case .waiting: self.running = false; self.port = nil; self.status = "Waiting for the network…"
                    case .cancelled: self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        } catch { stop(message: error.localizedDescription) }
    }

    func stop(message: String = "Stopped") {
        let old = listener
        listener = nil
        old?.service = nil
        old?.cancel()
        running = false; port = nil; status = message
        for (id, connection) in connections {
            tasks[id]?.cancel()
            readyWaiters.removeValue(forKey: id)?(false)
            disconnected?(id)
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.readyWaiters.removeValue(forKey: id)?(true)
                case .failed, .cancelled:
                    self.readyWaiters.removeValue(forKey: id)?(false)
                    self.disconnected?(id)
                default: break
                }
            }
        }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                connection.cancel()
                self.connections.removeValue(forKey: id)
                self.tasks.removeValue(forKey: id)
                self.readyWaiters.removeValue(forKey: id)?(false)
            }
            let ready = await withCheckedContinuation { continuation in
                self.readyWaiters[id] = { continuation.resume(returning: $0) }
                connection.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
                    guard let waiter = self?.readyWaiters.removeValue(forKey: id) else { return }
                    waiter(false); connection.cancel()
                }
            }
            guard ready, !Task.isCancelled else { return }
            await self.receiveUpload(id: id, connection: connection)
        }
    }

    private func receiveUpload(id: UUID, connection: NWConnection) async {
        var temporary: URL?
        var reserved = false
        defer {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            if reserved { release?(id) }
        }
        var response: TVTransferResponse
        do {
            let lengthBytes = try await readExactly(4, from: connection)
            let headerBytes = try await readExactly(TVTransferProtocol.length(lengthBytes), from: connection)
            let header = try TVTransferProtocol.header(headerBytes)
            guard let reserve else { throw TVTransferFailure("The receiver is not ready.") }
            if let rejection = reserve(id, header) { throw TVTransferFailure(rejection) }
            reserved = true
            let file = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(header.action == "uploadIPA" ? "ipa" : "p12")
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
#if os(tvOS) || os(iOS)
            attributes[.protectionKey] = FileProtectionType.complete
#endif
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: attributes) else { throw TVTransferFailure("Unable to create temporary transfer storage.") }
            temporary = file
            let output = try FileHandle(forWritingTo: file)
            do {
                var remaining = header.size
                let deadline = Date().addingTimeInterval(30 * 60)
                while remaining > 0 {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw TVTransferFailure("The transfer exceeded its time limit.") }
                    let chunk = try await readChunk(maximum: Int(min(remaining, 64 * 1024)), from: connection)
                    try output.write(contentsOf: chunk)
                    remaining -= Int64(chunk.count)
                }
                try output.close()
            } catch { try? output.close(); throw error }
            try Task.checkCancellation()
            response = await upload?(id, header, file) ?? .failure("The receiver is unavailable.")
        } catch is CancellationError { response = .failure("Transfer cancelled.") }
        catch let error as TVTransferFailure { response = .failure(error.message) }
        catch { response = .failure("The transfer failed or the connection was interrupted.") }
        // Result is sent only after the importer finishes, never on mere receipt.
        if let bytes = try? TVTransferProtocol.frame(response) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var finished = false
                let done = { if !finished { finished = true; continuation.resume() } }
                connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in done() })
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { done() }
            }
        }
    }

    private func readExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            result.append(try await readChunk(maximum: count - result.count, from: connection))
        }
        return result
    }
    private func readChunk(maximum: Int, from connection: NWConnection) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // NWConnection and timers all run on the main serial queue.
                var finished = false
                let timeout = DispatchWorkItem {
                    guard !finished else { return }; finished = true
                    continuation.resume(throwing: TVTransferFailure("Timed out waiting for transfer data."))
                    connection.cancel()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                    guard !finished else { return }; finished = true; timeout.cancel()
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: TVTransferFailure(complete ? "The incoming file ended before its declared size." : "The connection was interrupted.")) }
                }
            }
        } onCancel: { connection.cancel() }
    }
}
