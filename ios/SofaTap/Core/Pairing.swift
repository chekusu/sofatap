import Foundation
import Security
import CryptoKit
import Darwin

struct Pairing: SavedDeviceCredential {
    let host: String
    let port: Int
    let token: String
    let fingerprint: String
    let platform: String?
    let name: String?

    init(host: String, port: Int, token: String, fingerprint: String, platform: String? = nil, name: String? = nil) {
        self.host = host; self.port = port; self.token = token; self.fingerprint = fingerprint
        self.platform = platform; self.name = name
    }

    static func parse(_ raw: String) throws -> Pairing {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2048,
              let url = URLComponents(string: text),
              url.scheme?.lowercased() == "sofatap", url.host == "pair",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty, url.fragment == nil,
              let items = url.queryItems, (4...6).contains(items.count) else { throw PairingError.invalid }
        var fields: [String: String] = [:]
        for item in items {
            guard ["host", "port", "token", "fingerprint", "platform", "name"].contains(item.name),
                  fields[item.name] == nil, let value = item.value else { throw PairingError.invalid }
            fields[item.name] = value
        }
        guard let host = fields["host"], validHost(host),
              let portText = fields["port"], portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(portText), (1...65535).contains(port),
              let token = fields["token"], (32...256).contains(token.count),
              token.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
              }),
              let fingerprint = fields["fingerprint"], fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) })
        else { throw PairingError.invalid }
        let metadata = try PairingMetadata.validate(platform: fields["platform"], name: fields["name"],
                                                    allowedPlatforms: ["windows", "macos", "linux"])
        return Pairing(host: host.lowercased(), port: port, token: token, fingerprint: fingerprint.lowercased(),
                       platform: metadata.platform, name: metadata.name)
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ $0 < 128 }) else { return false }
        var address = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 { return true }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        }
    }

    var endpoint: URL? {
        var parts = URLComponents()
        parts.scheme = "wss"
        parts.host = host
        parts.port = port
        parts.path = "/control"
        return parts.url
    }
}

/// QR labels are untrusted display hints, never part of the TLS identity.
/// Reject controls before trimming so newline/bidi injection cannot disappear
/// during normalization. URLComponents retains a literal '+' in names.
enum PairingMetadata {
    static func validate(platform: String?, name: String?, allowedPlatforms: Set<String>) throws -> (platform: String?, name: String?) {
        if let platform, !allowedPlatforms.contains(platform) { throw PairingError.invalid }
        guard let name else { return (platform, nil) }
        guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PairingError.invalid }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.unicodeScalars.count <= 80, normalized.utf8.count <= 256 else { throw PairingError.invalid }
        return (platform, normalized)
    }
}

enum PairingError: LocalizedError {
    case invalid, storeFailed
    var errorDescription: String? {
        switch self {
        case .invalid: return String(localized: "配对链接不完整。请复制电脑接收器窗口里的完整 sofatap://pair 链接，或重新扫描二维码。")
        case .storeFailed: return String(localized: "无法将配对安全保存到钥匙串，请重试。")
        }
    }
}

extension Pairing {
    var deviceIdentity: String { "computer:" + fingerprint.lowercased() }
    var deviceAddress: String { "\(host):\(port)" }
    var pairingName: String? { name }
    var pairingPlatform: String? { platform }
    func validateForStorage() throws {
        var link = URLComponents()
        link.scheme = "sofatap"; link.host = "pair"
        link.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
                           URLQueryItem(name: "token", value: token), URLQueryItem(name: "fingerprint", value: fingerprint)]
        if let platform { link.queryItems?.append(URLQueryItem(name: "platform", value: platform)) }
        if let name { link.queryItems?.append(URLQueryItem(name: "name", value: name)) }
        guard let raw = link.string, (try? Self.parse(raw)) == self else { throw PairingError.invalid }
    }
}

enum PairingStore {
    private static let store = KeychainDeviceLibrary<Pairing>(service: "com.chekusu.sofatap.pairing", legacyAccount: "living-room-pc")
    static func read() -> Pairing? { (try? store.read())?.selected?.credential }
    static func library() throws -> DeviceLibrary<Pairing> { try store.read() }
    static func write(_ pairing: Pairing) throws { try store.mutate { $0.upsert(pairing) } }
    static func select(_ id: UUID) throws { try store.mutate { try $0.select(id) } }
    static func rename(_ id: UUID, name: String) throws { try store.mutate { try $0.rename(id, name: name) } }
    static func metadata(_ id: UUID, name: String, platform: String) throws {
        try store.mutate { try $0.updateMetadata(id, name: name, platform: platform) }
    }
    static func remove(_ id: UUID) throws { try store.mutate { $0.remove(id) } }
    static func delete() { if let id = try? store.read().selectedID { try? remove(id) } }
}

/// Trust is limited to the exact paired host, port and DER leaf fingerprint.
/// The scanned certificate becomes an anchor for this challenge only, never a system CA.
final class PinnedSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let pairing: Pairing
    private let loopbackPort: UInt16?
    private let diagnosticLock = NSLock()
    private var failure: String?
    var rejectionReason: String? {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }
        return failure
    }
    // A bridge changes only the transport endpoint. Certificate identity stays
    // bound to the original pairing, including hostname, validity and leaf pin.
    init(pairing: Pairing, loopbackPort: UInt16? = nil) {
        self.pairing = pairing; self.loopbackPort = loopbackPort
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Pairing fixes the complete endpoint. Never forward the bearer credential on redirects.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        func reject(_ reason: String) {
            diagnosticLock.lock(); failure = reason; diagnosticLock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else { reject("TLS_METHOD"); return }
        guard challenge.protectionSpace.host.lowercased() == (loopbackPort == nil ? pairing.host : "127.0.0.1") else { reject("TLS_HOST"); return }
        guard challenge.protectionSpace.port == (loopbackPort.map(Int.init) ?? pairing.port) else { reject("TLS_PORT_\(challenge.protectionSpace.port)"); return }
        guard let trust = challenge.protectionSpace.serverTrust else { reject("TLS_TRUST_MISSING"); return }
        guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificates.first else { reject("TLS_LEAF_MISSING"); return }
        let der = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard actual == pairing.fingerprint else {
            reject("TLS_PIN")
            return
        }
        let policyResult = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, pairing.host as CFString))
        let anchorResult = SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        let anchorsOnlyResult = SecTrustSetAnchorCertificatesOnly(trust, true)
        guard policyResult == errSecSuccess, anchorResult == errSecSuccess, anchorsOnlyResult == errSecSuccess else {
            reject("TLS_POLICY_\(policyResult)_\(anchorResult)_\(anchorsOnlyResult)")
            return
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            reject("TLS_VERIFY_\(error.map { CFErrorGetCode($0) } ?? 0)")
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
