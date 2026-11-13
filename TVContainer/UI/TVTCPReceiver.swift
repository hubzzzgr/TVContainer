import Foundation
import Network
import Security
import Combine
@preconcurrency import Dispatch

@MainActor
final class TVTCPReceiver: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var port: UInt16?
    @Published private(set) var requestedPort: UInt16?
    @Published private(set) var connected = false
    @Published private(set) var fingerprint = ""
    @Published private(set) var deviceName: String
    let appVersion: String
    let keychain: TVReceiverKeychain
    var pair: ((UUID, String, String) async -> Bool)?
    var reserve: ((UUID, TVUploadHeader) -> String?)?
    var upload: ((UUID, TVUploadHeader, URL) async -> TVTransferResponse)?
    var release: ((UUID) -> Void)?
    var disconnected: ((UUID) -> Void)?
    private var listener: NWListener?
    private var generation = UUID()
    private var connections: [UUID: NWConnection] = [:]
    private var authenticatedConnections: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var readyWaiters: [UUID: (Bool) -> Void] = [:]
    private let preferences: UserDefaults
    private static let portPreference = "sideTVStoreTCPPort"
    let temporaryDirectory: URL

    init(deviceName: String, appVersion: String, keychain: TVReceiverKeychain = TVReceiverKeychain(), preferences: UserDefaults = .standard,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("TVContainerReceiver", isDirectory: true)) {
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.keychain = keychain
        self.preferences = preferences
        let saved = preferences.integer(forKey: Self.portPreference)
        self.requestedPort = saved > 0 && saved <= Int(UInt16.max) ? UInt16(saved) : nil
        self.temporaryDirectory = temporaryDirectory
    }
    // A requested port is only routing metadata. Persist it only once it binds.
    // Selecting automatic explicitly retries on an ephemeral port; no silent fallback.
    func configurePort(_ port: UInt16?) {
        precondition(port != 0)
        stop()
        requestedPort = port
    }
    func updateDeviceName(_ name: String) {
        guard name != deviceName else { return }
        stop(); deviceName = name
    }

    func start() {
        guard listener == nil else { return }
        port = nil
        status = "Starting…"
        let generation = UUID()
        self.generation = generation
        do {
            guard !deviceName.isEmpty else { throw TVTransferFailure("Unable to read the Apple TV’s assigned device name.") }
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
                    guard let self, self.listener != nil, self.generation == generation,
                          let peer = TVReceiverKeychain.peer(peerTrust) else { complete(false); return }
                    do {
                        if try self.keychain.trustedPeers().contains(peer.fingerprint) { complete(true); return }
                        // The TLS verification callback doesn't expose a connection
                        // ID; a unique approval ID avoids trusting another handshake.
                        let approvalID = UUID()
                        guard await self.pair?(approvalID, peer.name, peer.fingerprint) == true,
                              self.listener != nil, self.generation == generation else { complete(false); return }
                        try self.keychain.trust(peer.fingerprint)
                        complete(true)
                    } catch { complete(false) }
                }
            }, .main)
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            let parameters = NWParameters(tls: tls, tcp: tcp)
            let listener = try NWListener(using: parameters,
                on: requestedPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
            self.listener = listener
            // Direct paired-TV address routing: no Bonjour publication or dependency.
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let boundPort = listener.port?.rawValue, boundPort > 0 else {
                            self.stop(message: "The listener did not report a bound TCP port."); return
                        }
                        self.port = boundPort
                        self.requestedPort = boundPort
                        self.preferences.set(Int(boundPort), forKey: Self.portPreference)
                        self.running = true; self.status = "Running"
                    case .failed(let error): self.failToStart(error)
                    case .waiting(let error):
                        self.running = false; self.port = nil
                        self.status = "Waiting to listen\(self.requestedPort.map { " on port \($0)" } ?? ""): \(error.localizedDescription) Check Local Network access, change the port, or choose Use Automatic Port."
                    case .cancelled: self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)
        } catch { failToStart(error) }
    }

    private func failToStart(_ error: Error) {
        let target = requestedPort.map { " on port \($0)" } ?? " on an automatic port"
        stop(message: "Could not listen\(target): \(error.localizedDescription) Check Local Network access, change the port, or choose Use Automatic Port.")
    }

    func stop(message: String = "Stopped") {
        let old = listener
        listener = nil
        generation = UUID()
        old?.cancel()
        running = false; port = nil; status = message
        authenticatedConnections.removeAll(); connected = false
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
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.connections[id] === connection else { return }
                switch state {
                case .ready:
                    // NWConnection.ready follows successful mutual TLS verification.
                    self.authenticatedConnections.insert(id); self.connected = true
                    self.readyWaiters.removeValue(forKey: id)?(true)
                case .failed, .cancelled:
                    self.authenticatedConnections.remove(id)
                    self.connected = !self.authenticatedConnections.isEmpty
                    self.readyWaiters.removeValue(forKey: id)?(false)
                    self.tasks[id]?.cancel()
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
                self.authenticatedConnections.remove(id)
                self.connected = !self.authenticatedConnections.isEmpty
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
                    let chunk = try await readChunk(maximum: Int(min(remaining, 64 * 1024)), from: connection,
                        timeout: min(30, deadline.timeIntervalSinceNow))
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
        if response.message.utf8.count > 8_192 {
            response = .init(ok: response.ok, message: String(String.UnicodeScalarView(response.message.unicodeScalars.prefix(2_000))))
        }
        guard !Task.isCancelled else { return }
        switch connection.state { case .failed, .cancelled: return; default: break }
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
    private func readChunk(maximum: Int, from connection: NWConnection, timeout interval: TimeInterval = 30) async throws -> Data {
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
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, interval), execute: timeout)
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                    guard !finished else { return }; finished = true; timeout.cancel()
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: TVTransferFailure(complete ? "The incoming file ended before its declared size." : "The connection was interrupted.")) }
                }
            }
        } onCancel: { connection.cancel() }
    }
}
