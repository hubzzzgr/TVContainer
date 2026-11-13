import Foundation
import Network
import Security
import Darwin

@MainActor final class TestClient {
    let connection: NWConnection
    init(port: UInt16, pin: String, identity: SecIdentity?, plaintext: Bool = false) {
        if plaintext { connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp); return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        if let identity { sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!) }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            complete(TVReceiverKeychain.peer(value)?.fingerprint == pin)
        }, .main)
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
    }
    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            let finish: (Bool) -> Void = { success in
                guard !finished else { return }; finished = true
                if success { continuation.resume() } else { continuation.resume(throwing: TVTransferFailure("TLS rejected")) }
            }
            connection.stateUpdateHandler = { state in
                switch state { case .ready: finish(true); case .failed, .cancelled: finish(false); default: break }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [connection] in
                if !finished { finish(false); connection.cancel() }
            }
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func read(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let value: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, _, _ in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: TVTransferFailure("Unexpected EOF")) }
                }
            }
            result.append(value)
        }
        return result
    }
    func response() async throws -> TVTransferResponse {
        let count = try TVTransferProtocol.length(try await read(4))
        return try JSONDecoder().decode(TVTransferResponse.self, from: try await read(count))
    }
}

@main struct ReceiverTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        // Watchdog prevents a broken network callback from hanging CI.
        Task { try await Task.sleep(nanoseconds: 150_000_000_000); fatalError("Receiver tests timed out") }
        let valid = TVUploadHeader(version: 1, action: "uploadIPA", filename: "test.ipa", size: 200_003)
        let decoded = try TVTransferProtocol.header(JSONEncoder().encode(valid))
        assert(decoded == valid)
        try TVUploadHeader(version: 1, action: "uploadIPA", filename: "large.ipa", size: 2_147_483_649).validate()
        try TVUploadHeader(version: 1, action: "uploadIPA", filename: "large.ipa", size: Int64.max).validate()
        let invalids = [
            TVUploadHeader(version: 2, action: "uploadIPA", filename: "a.ipa", size: 1),
            TVUploadHeader(version: 1, action: "other", filename: "a.ipa", size: 1),
            TVUploadHeader(version: 1, action: "uploadIPA", filename: "../a.ipa", size: 1),
            TVUploadHeader(version: 1, action: "uploadP12", filename: "a.p12", size: 4_194_305),
            TVUploadHeader(version: 1, action: "uploadIPA", filename: "a.ipa", size: -1),
            TVUploadHeader(version: 1, action: "uploadIPA", filename: "a.ipa", size: 0),
            TVUploadHeader(version: 1, action: "uploadIPA", filename: "bad\nname", size: 1)
        ]
        for value in invalids {
            do { try value.validate(); fatalError("Invalid header accepted") } catch is TVTransferFailure {}
        }
        for prefix in [Data([0,0,0,0]), Data([255,255,255,255]), Data([1])] {
            do { _ = try TVTransferProtocol.length(prefix); fatalError("Invalid length accepted") } catch is TVTransferFailure {}
        }

        let keychain = TVReceiverKeychain(service: "org.tvcontainer.receiver-tests.\(UUID())")
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychain.service] as CFDictionary) }
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let suite = "org.tvcontainer.receiver-port-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let server = TVTCPReceiver(deviceName: "Test Apple TV", appVersion: "1.2.3", keychain: keychain, preferences: preferences,
            temporaryDirectory: temporaryDirectory)
        var pairCount = 0, allowPair = true, importCount = 0, releaseCount = 0, reservationCount = 0
        var rejection: String?, importResult = TVTransferResponse(ok: true, message: "Actually installed")
        var files: [URL] = [], received = Data()
        server.pair = { _, _, _ in
            // An unapproved handshake is not a connected SideTVStore session.
            if pairCount == 0 { assert(!server.connected) }
            pairCount += 1; return allowPair
        }
        server.reserve = { _, _ in
            if rejection == nil { reservationCount += 1 }
            return rejection
        }
        server.upload = { _, _, file in
            importCount += 1; files.append(file); received = try! Data(contentsOf: file)
            return importResult
        }
        server.release = { _ in releaseCount += 1 }
        server.start()
        print("Receiver initial listener state: \(server.status)")
        try await wait { server.running }
        print("Receiver stage: listener ready")
        assert(!server.connected)
        let initialPort = server.port!
        assert(preferences.integer(forKey: "sideTVStoreTCPPort") == Int(initialPort))
        let identityPassword = UUID().uuidString
        let identity = try TVReceiverKeychain.importIdentity(TVReceiverIdentity.create(deviceName: "Test iPhone", password: identityPassword), password: identityPassword)
        func client(_ identity: SecIdentity?) async throws -> TestClient {
            let client = TestClient(port: server.port!, pin: server.fingerprint, identity: identity)
            try await client.connect(); return client
        }
        let payload = Data((0..<Int(valid.size)).map { UInt8($0 % 251) })
        let first = try await client(identity)
        try await wait { server.connected }
        assert(server.authenticatedIdleTimeout == 900)
        // A real delay beyond the old 30-second timeout must not reserve a slot.
        try await Task.sleep(nanoseconds: 31_000_000_000)
        assert(server.connected && reservationCount == 0 && importCount == 0)
        let idleCompanion = try await client(identity)
        let header = try TVTransferProtocol.frame(valid)
        // Fragment the length prefix and coalesce the JSON tail with payload.
        for byte in header.prefix(4) { try await first.send(Data([byte])) }
        try await first.send(header.dropFirst(4) + payload)
        let firstResult = try await first.response()
        print("Receiver stage: first upload returned a result")
        assert(firstResult == importResult && received == payload && importCount == 1 && pairCount == 1)
        first.connection.cancel()
        try await wait { releaseCount == 1 }
        assert(server.connected) // Another idle client did not block this upload.
        idleCompanion.connection.cancel()
        try await wait { !server.connected }
        assert(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let peers = try keychain.trustedPeers()
        assert(peers.count == 1)

        // Graceful TLS EOF while idle clears status without waiting for expiry.
        let graceful = try await client(identity)
        try await wait { server.connected }
        let closedAt = Date()
        graceful.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        try await wait { !server.connected }
        assert(Date().timeIntervalSince(closedAt) < 3 && reservationCount == 1)
        graceful.connection.cancel()

        // A single prefix byte cannot obtain the long authenticated idle window.
        let partial = try await client(identity)
        try await wait { server.connected }
        try await partial.send(Data([0]))
        try await Task.sleep(nanoseconds: 31_000_000_000)
        try await wait { !server.connected }
        assert(reservationCount == 1 && importCount == 1)
        partial.connection.cancel()

        // Same identity reconnects without another Apple TV pairing prompt.
        importResult = .failure("Actual signing failure")
        let second = try await client(identity)
        try await second.send(header + payload)
        let secondResult = try await second.response()
        assert(secondResult == importResult && importCount == 2 && pairCount == 1)
        second.connection.cancel()
        try await wait { releaseCount == 2 }
        print("Receiver stage: reconnect and importer failure checked")

        // Certificate-present/busy policy rejects before the importer runs.
        rejection = "A signing certificate is already installed. It was not replaced."
        let third = try await client(identity)
        try await third.send(TVTransferProtocol.frame(TVUploadHeader(version: 1, action: "uploadP12", filename: "a.p12", size: 4)))
        let rejected = try await third.response()
        assert(!rejected.ok && rejected.message == rejection && importCount == 2)
        third.connection.cancel(); rejection = nil

        for malformed in [Data([0,0,0,0]), Data([0,0,128,0]), Data([0,0,0,2,91,93])] {
            let invalid = try await client(identity)
            try await invalid.send(malformed)
            let result = try await invalid.response()
            assert(!result.ok && importCount == 2)
            invalid.connection.cancel()
        }

        // Truncated uploads never reach the importer; reserved state is released.
        let fourth = try await client(identity)
        try await fourth.send(header + payload.prefix(17))
        try await wait { reservationCount == 3 }
        fourth.connection.cancel()
        try await wait { releaseCount == 3 }
        print("Receiver stage: interrupted upload cleaned up")
        assert(importCount == 2)

        // A different certificate cannot use previously approved trust.
        allowPair = false
        let strangerPassword = UUID().uuidString
        let stranger = try TVReceiverKeychain.importIdentity(TVReceiverIdentity.create(deviceName: "Different phone", password: strangerPassword), password: strangerPassword)
        await rejectedClient(stranger)
        let peersAfterRejection = try keychain.trustedPeers()
        assert(pairCount == 2 && peersAfterRejection.count == 1)
        await rejectedClient(nil)
        try await wait { !server.connected }
        assert(importCount == 2)
        assert(!server.connected)

        // Plain TCP framing cannot bypass TLS or reach application handlers.
        let plain = TestClient(port: server.port!, pin: "", identity: nil, plaintext: true)
        try await plain.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { plain.connection.cancel() }
        do { try await plain.send(header + payload); _ = try await plain.response(); fatalError("Plaintext was accepted") } catch {}
        plain.connection.cancel()
        assert(importCount == 2)

        // Listener disable closes an in-progress upload and cleans temporary data.
        let last = try await client(identity)
        try await last.send(header + payload.prefix(11))
        try await wait { reservationCount == 4 }
        let pin = server.fingerprint
        server.stop()
        try await wait { releaseCount == 4 }
        assert(!server.running && server.port == nil && !server.connected && importCount == 2)
        assert(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        assert(leftovers.isEmpty)
        // Identity and peer trust survive restart; TLS tickets aren't used.
        server.start(); try await wait { server.running }
        assert(server.fingerprint == pin && server.port == initialPort)
        let reconnect = try await client(identity); reconnect.connection.cancel()
        assert(pairCount == 2)
        try await wait { !server.connected }

        // Occupy another port: failure cannot be displayed or saved as a bound port.
        // An independent plain TCP listener owns the busy-port test fixture.
        let blocker = try NWListener(using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()), on: .any)
        blocker.newConnectionHandler = { $0.cancel() }
        var blockerReady = false, blockerClosed = false
        blocker.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: blockerReady = true
                case .cancelled: blockerClosed = true
                case .failed(let error): fatalError("Port blocker failed: \(error)")
                default: break
                }
            }
        }
        blocker.start(queue: .main)
        try await wait { blockerReady }
        let blockedPort = blocker.port!.rawValue
        assert(blockedPort != initialPort)
        server.configurePort(blockedPort); server.start()
        try await wait { server.status.contains("Use Automatic Port") }
        assert(!server.running && server.port == nil && !server.connected)
        assert(server.requestedPort == blockedPort && server.status.contains(String(blockedPort)))
        assert(preferences.integer(forKey: "sideTVStoreTCPPort") == Int(initialPort))
        // A new receiver reads only the last successful bind, not the failed choice.
        let restored = TVTCPReceiver(deviceName: "Test Apple TV", appVersion: "1.2.3", keychain: keychain,
            preferences: preferences, temporaryDirectory: temporaryDirectory)
        assert(restored.requestedPort == initialPort)
        restored.start(); try await wait { restored.running }
        assert(restored.port == initialPort && restored.fingerprint == pin)
        restored.stop()

        // Explicit automatic-port recovery preserves the established TLS identity.
        server.configurePort(nil); server.start()
        assert(server.port == nil)
        try await wait { server.running }
        assert(server.port != blockedPort && server.fingerprint == pin)
        assert(preferences.integer(forKey: "sideTVStoreTCPPort") == Int(server.port!))
        let recovered = try await client(identity)
        try await wait { server.connected }
        assert(pairCount == 2)
        let other = try await client(identity)
        recovered.connection.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        assert(server.connected) // One remaining authenticated phone is still connected.
        other.connection.cancel(); try await wait { !server.connected }
        server.stop()

        // A user-selected port is used exactly after the previous owner releases it.
        blocker.cancel(); try await wait { blockerClosed }
        server.configurePort(blockedPort); server.start()
        assert(server.port == nil)
        try await wait { server.running }
        assert(server.port == blockedPort && server.fingerprint == pin)
        assert(preferences.integer(forKey: "sideTVStoreTCPPort") == Int(blockedPort))

        // A changed server pin is rejected on the phone; forgetting phone pins
        // forces a new TV approval without replacing the receiver's identity.
        let wrongPin = TestClient(port: blockedPort, pin: String(repeating: "0", count: 64), identity: identity)
        do { try await wrongPin.connect(); fatalError("Changed server pin accepted") } catch {}
        wrongPin.connection.cancel()
        try await wait { !server.connected }
        server.stop(); try keychain.forgetPeers()
        server.start(); try await wait { server.running }
        assert(server.fingerprint == pin)
        allowPair = true
        let pairedAgain = try await client(identity)
        try await wait { server.connected }
        assert(pairCount == 3)
        pairedAgain.connection.cancel(); try await wait { !server.connected }
        server.stop()
        // Shorten only the pre-request idle window for deterministic expiry;
        // no production header/payload timeout changes are needed for the test.
        let expiring = TVTCPReceiver(deviceName: "Test Apple TV", appVersion: "1.2.3", keychain: keychain,
            preferences: preferences, temporaryDirectory: temporaryDirectory, authenticatedIdleTimeout: 0.5)
        var idleReservations = 0
        expiring.reserve = { _, _ in idleReservations += 1; return nil }
        expiring.start(); try await wait { expiring.running }
        let idle = TestClient(port: expiring.port!, pin: expiring.fingerprint, identity: identity)
        try await idle.connect(); try await wait { expiring.connected }
        try await wait { !expiring.connected }
        assert(idleReservations == 0)
        idle.connection.cancel()
        let disabledIdle = TestClient(port: expiring.port!, pin: expiring.fingerprint, identity: identity)
        try await disabledIdle.connect(); try await wait { expiring.connected }
        expiring.stop()
        assert(!expiring.connected && idleReservations == 0)
        disabledIdle.connection.cancel()
        print("Authenticated idle tests passed: >30-second idle upload, simultaneous idle clients without reservation, graceful EOF, short partial-prefix timeout, idle expiry and disable.")
        print("Receiver tests passed: direct TLS without Bonjour, stable/occupied/automatic/explicit ports, authenticated connection status, strict framing, pinning, pairing/rejection/reconnect, streaming/results, certificate policy, interruption and cleanup.")

        func rejectedClient(_ value: SecIdentity?) async {
            do {
                let unauthorized = try await client(value)
                defer { unauthorized.connection.cancel() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { unauthorized.connection.cancel() }
                try await unauthorized.send(header + payload)
                let response = try await unauthorized.response()
                assert(!response.ok)
            } catch {}
        }
    }
    @MainActor static func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<480 { if predicate() { return }; try await Task.sleep(nanoseconds: 25_000_000) }
        fatalError("Receiver state transition timed out", file: file, line: line)
    }
}
