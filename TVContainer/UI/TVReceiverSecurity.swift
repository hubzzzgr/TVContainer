import Foundation
import Security
import CryptoKit

// The TLS identity is independent of the developer's signing identity. A user
// can pair and receive the very first signing P12 without already having one.
final class TVReceiverKeychain {
    let service: String
    init(service: String = "com.kdt.tvcontainer.receiver.v1") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TVTransferFailure("Receiver Keychain data is unavailable (\(status)).") }
        return data
    }
    func write(_ account: String, data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TVTransferFailure("Unable to save receiver Keychain data (\(status)).") }
    }
    func identity(deviceName: String) throws -> SecIdentity {
        if let saved = try read("tls-identity") { return try Self.importIdentity(saved) }
        let data = try TVReceiverIdentity.create(deviceName: deviceName)
        let identity = try Self.importIdentity(data)
        try write("tls-identity", data: data)
        return identity
    }
    static func importIdentity(_ data: Data) throws -> SecIdentity {
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: ""]
#if os(macOS)
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
#endif
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let item = first[kSecImportItemIdentity as String] else { throw TVTransferFailure("Unable to open the receiver TLS identity (\(status)).") }
        return item as! SecIdentity
    }
    func trustedPeers() throws -> Set<String> {
        guard let data = try read("paired-peers") else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: data))
    }
    func trust(_ fingerprint: String) throws {
        var peers = try trustedPeers()
        guard peers.count < 16 || peers.contains(fingerprint) else { throw TVTransferFailure("The paired-device limit has been reached. Forget paired devices in Settings first.") }
        peers.insert(fingerprint)
        try write("paired-peers", data: JSONEncoder().encode(peers.sorted()))
    }
    func forgetPeers() throws { try write("paired-peers", data: JSONEncoder().encode([String]())) }
    static func fingerprint(_ certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
    }
    static func fingerprint(_ identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw TVTransferFailure("The receiver TLS certificate is unavailable.")
        }
        return fingerprint(certificate)
    }
    static func displayFingerprint(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 8).map { index in
            let start = value.index(value.startIndex, offsetBy: index)
            return String(value[start..<value.index(start, offsetBy: min(8, value.count - index))])
        }.joined(separator: " ")
    }
    // Self-signed certificates are allowed only for local pairing; the TLS
    // CertificateVerify proves key possession and the approved DER pin persists.
    static func peer(_ trust: SecTrust) -> (name: String, fingerprint: String)? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return nil }
        return (TVTransferProtocol.displayName(SecCertificateCopySubjectSummary(leaf) as String? ?? "SideTVStore"), fingerprint(leaf))
    }
}
