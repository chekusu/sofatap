import Foundation
import Darwin

/// Same bounded desktop pairing contract as the phone. Copy never accepts TV or browser links.
enum ReceiverPairingURI {
    static func valid(_ value: String, expectedHost: String) -> Bool {
        guard value.utf8.count <= 2_048,
              value.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 35 }),
              value.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
              let url = URLComponents(string: value), url.scheme?.lowercased() == "sofatap", url.host == "pair",
              url.user == nil, url.password == nil, url.port == nil, url.path.isEmpty, url.fragment == nil,
              let query = url.percentEncodedQuery else { return false }
        let items = query.split(separator: "&", omittingEmptySubsequences: false)
        guard (4...6).contains(items.count) else { return false }
        var fields: [String: String] = [:]
        for item in items {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  ["host", "port", "token", "fingerprint", "platform", "name"].contains(String(parts[0])),
                  fields[String(parts[0])] == nil,
                  let decoded = String(parts[1]).removingPercentEncoding else { return false }
            fields[String(parts[0])] = decoded
        }
        guard let host = fields["host"], validHost(host), host.lowercased() == expectedHost.lowercased(),
              let port = fields["port"], !port.isEmpty, port.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(port), (1...65535).contains(number),
              let token = fields["token"], (32...256).contains(token.utf8.count),
              token.utf8.allSatisfy({ asciiAlphanumeric($0) || $0 == 45 || $0 == 95 }),
              let fingerprint = fields["fingerprint"], fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return false }
        if let platform = fields["platform"], !["windows", "macos", "linux"].contains(platform) { return false }
        if let name = fields["name"] {
            guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 80, trimmed.utf8.count <= 256 else { return false }
        }
        return true
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, host.utf8.allSatisfy({ $0 < 128 }) else { return false }
        var address = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 { return true }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy({ asciiAlphanumeric($0) || $0 == 45 })
        }
    }
    private static func asciiAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

enum ReceiverProtocolError: Error {
    case oversizedFrame, truncatedFrame, invalidState
}

/// Bounds a newline-delimited JSON frame before JSON/base64 decoding. Pairing secrets stay in memory.
struct ReceiverLineBuffer {
    static let maximumFrameBytes = 2 * 1_024 * 1_024
    private var bytes = Data()

    mutating func append(_ byte: UInt8) throws -> Data? {
        if byte == 10 {
            let frame = bytes
            bytes.removeAll(keepingCapacity: true)
            return frame.isEmpty ? nil : frame
        }
        guard bytes.count < Self.maximumFrameBytes else { throw ReceiverProtocolError.oversizedFrame }
        bytes.append(byte)
        return nil
    }

    func finish() throws {
        guard bytes.isEmpty else { throw ReceiverProtocolError.truncatedFrame }
    }
}

struct ReceiverPairing: Decodable, Equatable, Sendable, Identifiable {
    let host: String
    let uri: String
    let qrPng: String
    var id: String { host }

    var pngData: Data? { Data(base64Encoded: qrPng) }

    func validate() throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ReceiverPairingURI.valid(uri, expectedHost: host),
              qrPng.utf8.count <= 256 * 1_024,
              let png = pngData, png.count >= 24,
              Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(png[12..<16]) == [73, 72, 68, 82] else {
            throw ReceiverProtocolError.invalidState
        }
        // Check the PNG dimensions before handing data to an image decoder.
        let width = png[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = png[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width > 0, height > 0, width <= 2_048, height <= 2_048 else {
            throw ReceiverProtocolError.invalidState
        }
    }
}

/// Routing metadata from the private helper pipe, independent of LAN QR entries.
struct ReceiverPeerIdentity: Decodable, Equatable, Sendable {
    let port: UInt16
    let fingerprint: String

    func validate() throws {
        guard port > 0, fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ReceiverProtocolError.invalidState
        }
    }
}

struct ReceiverState: Decodable, Equatable, Sendable {
    let type: String
    let name: String
    let platform: String
    let inputStatus: String
    let dryRun: Bool
    let connected: Bool
    let pairings: [ReceiverPairing]
    var peer: ReceiverPeerIdentity? = nil

    static func decode(_ data: Data) throws -> ReceiverState {
        guard data.count <= ReceiverLineBuffer.maximumFrameBytes else { throw ReceiverProtocolError.oversizedFrame }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.type == "state", value.platform == "macos",
              !value.name.isEmpty, value.name.utf8.count <= 512,
              value.inputStatus.utf8.count <= 128, value.pairings.count <= 16,
              Set(value.pairings.map(\.host)).count == value.pairings.count else {
            throw ReceiverProtocolError.invalidState
        }
        try value.peer?.validate()
        try value.pairings.forEach { try $0.validate() }
        return value
    }

    /// Preserve the selected interface across periodic updates, but never keep a stale pairing.
    func selectedHost(preserving current: String?) -> String? {
        if let current, pairings.contains(where: { $0.host == current }) { return current }
        return pairings.first?.host
    }
}

enum ReceiverCommand: String, Sendable, CaseIterable {
    case refresh, requestAccess, quit

    var line: Data { Data("{\"type\":\"\(rawValue)\"}\n".utf8) }
}
