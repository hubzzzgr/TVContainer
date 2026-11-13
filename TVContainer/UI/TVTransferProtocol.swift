import Foundation

struct TVTransferFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct TVUploadHeader: Codable, Equatable {
    static let largeIPAWarningThreshold: Int64 = 2 * 1024 * 1024 * 1024
    let version: Int
    let action: String
    let filename: String
    let size: Int64

    func validate() throws {
        guard version == 1 else { throw TVTransferFailure("Unsupported transfer protocol version.") }
        guard action == "uploadIPA" || action == "uploadP12" else { throw TVTransferFailure("Unsupported transfer action.") }
        guard !filename.isEmpty, filename.utf8.count <= 200,
              !filename.contains("/"), !filename.contains("\\"), filename != ".", filename != "..",
              filename.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw TVTransferFailure("Invalid transfer filename.")
        }
        let limit: Int64 = action == "uploadIPA" ? .max : 4 * 1024 * 1024
        guard size > 0, size <= limit else { throw TVTransferFailure("The incoming file exceeds the allowed size or is empty.") }
        // The action chooses the importer. Validate actual contents there rather
        // than rejecting a valid IPA/P12 because a sender renamed its file.
    }
}

struct TVTransferResponse: Codable, Equatable {
    let ok: Bool
    let message: String
    static func failure(_ message: String) -> Self { .init(ok: false, message: message) }
}

enum TVTransferProtocol {
    static let maximumHeaderLength = 16 * 1024
    static func length(_ bytes: Data) throws -> Int {
        guard bytes.count == 4 else { throw TVTransferFailure("Incomplete frame length.") }
        let length = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximumHeaderLength else { throw TVTransferFailure("Invalid JSON frame length.") }
        return Int(length)
    }
    static func frame<T: Encodable>(_ message: T) throws -> Data {
        let json = try JSONEncoder().encode(message)
        guard !json.isEmpty, json.count <= maximumHeaderLength else { throw TVTransferFailure("JSON message is too large.") }
        let length = UInt32(json.count)
        var result = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        result.append(json)
        return result
    }
    static func header(_ bytes: Data) throws -> TVUploadHeader {
        guard !bytes.isEmpty, bytes.count <= maximumHeaderLength else { throw TVTransferFailure("Invalid request header.") }
        let header: TVUploadHeader
        do { header = try JSONDecoder().decode(TVUploadHeader.self, from: bytes) }
        catch { throw TVTransferFailure("Invalid JSON request header.") }
        try header.validate()
        return header
    }
    static func displayName(_ input: String) -> String {
        String(String.UnicodeScalarView(input.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120)))
    }
}
