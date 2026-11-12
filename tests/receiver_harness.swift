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
        Task { try await Task.sleep(nanoseconds: 90_000_000_000); fatalError("Receiver tests timed out") }
        let valid = TVUploadHeader(version: 1, action: "uploadIPA", filename: "test.ipa", size: 200_003)
        let decoded = try TVTransferProtocol.header(JSONEncoder().encode(valid))
        assert(decoded == valid)
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
        let server = TVTCPReceiver(deviceName: "Test Apple TV", appVersion: "1.2.3", keychain: keychain, advertise: false,
            temporaryDirectory: temporaryDirectory)
        var pairCount = 0, allowPair = true, importCount = 0, releaseCount = 0, reservationCount = 0
        var rejection: String?, importResult = TVTransferResponse(ok: true, message: "Actually installed")
        var files: [URL] = [], received = Data()
        server.pair = { _, _, _ in pairCount += 1; return allowPair }
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
        assert(server.txtRecords == ["deviceName":"Test Apple TV", "appVersion":"1.2.3", "protocol":"1"])
        let identity = try TVReceiverKeychain.importIdentity(TVReceiverIdentity.create(deviceName: "Test iPhone"))
        func client(_ identity: SecIdentity?) async throws -> TestClient {
            let client = TestClient(port: server.port!, pin: server.fingerprint, identity: identity)
            try await client.connect(); return client
        }
        let payload = Data((0..<Int(valid.size)).map { UInt8($0 % 251) })
        let first = try await client(identity)
        let header = try TVTransferProtocol.frame(valid)
        // Fragment the length prefix and coalesce the JSON tail with payload.
        for byte in header.prefix(4) { try await first.send(Data([byte])) }
        try await first.send(header.dropFirst(4) + payload)
        let firstResult = try await first.response()
        print("Receiver stage: first upload returned a result")
        assert(firstResult == importResult && received == payload && importCount == 1 && pairCount == 1)
        first.connection.cancel()
        try await wait { releaseCount == 1 }
        assert(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let peers = try keychain.trustedPeers()
        assert(peers.count == 1)

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
        fourth.connection.cancel()
        try await wait { releaseCount == 3 }
        print("Receiver stage: interrupted upload cleaned up")
        assert(importCount == 2)

        // A different certificate cannot use previously approved trust.
        allowPair = false
        let stranger = try TVReceiverKeychain.importIdentity(TVReceiverIdentity.create(deviceName: "Different phone"))
        await rejectedClient(stranger)
        let peersAfterRejection = try keychain.trustedPeers()
        assert(pairCount == 2 && peersAfterRejection.count == 1)
        await rejectedClient(nil)
        assert(importCount == 2)

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
        assert(!server.running && server.port == nil && importCount == 2)
        assert(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        assert(leftovers.isEmpty)
        // Identity and peer trust survive restart; TLS tickets aren't used.
        server.start(); try await wait { server.running }
        assert(server.fingerprint == pin)
        let reconnect = try await client(identity); reconnect.connection.cancel()
        assert(pairCount == 2)
        server.stop()
        print("Receiver tests passed: strict framing, TLS pinning, pairing/rejection/reconnect, streamed payload, actual results, existing-certificate policy, truncated uploads, disable and cleanup.")

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
