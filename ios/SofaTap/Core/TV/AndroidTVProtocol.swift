import Foundation
import CoreFoundation

/// A distinct pairing namespace prevents a television QR from replacing a computer pairing.
struct AndroidTVPairing: Codable, Equatable, Sendable {
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

    static func parse(_ raw: String) throws -> Self {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 2048, let url = URLComponents(string: raw),
              url.scheme?.lowercased() == "sofatap", url.host == "tv",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty, url.fragment == nil,
              let items = url.queryItems, (4...6).contains(items.count) else { throw AndroidTVError.invalidPairing }
        var fields: [String: String] = [:]
        for item in items {
            guard ["host", "port", "token", "fingerprint", "platform", "name"].contains(item.name),
                  fields[item.name] == nil, let value = item.value else { throw AndroidTVError.invalidPairing }
            fields[item.name] = value
        }
        guard let host = fields["host"], let portText = fields["port"],
              portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(portText), let token = fields["token"],
              let fingerprint = fields["fingerprint"] else { throw AndroidTVError.invalidPairing }
        guard let metadata = try? PairingMetadata.validate(platform: fields["platform"], name: fields["name"],
                                                          allowedPlatforms: ["androidtv"]) else { throw AndroidTVError.invalidPairing }
        let pairing = Self(host: host, port: port, token: token, fingerprint: fingerprint.lowercased(),
                           platform: metadata.platform, name: metadata.name)
        try pairing.validate()
        return pairing
    }

    func validate() throws {
        guard let metadata = try? PairingMetadata.validate(platform: platform, name: name, allowedPlatforms: ["androidtv"]),
              metadata.name == name else { throw AndroidTVError.invalidPairing }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") &&
            $0.utf8.allSatisfy({ (48...57).contains($0) }) && UInt8($0) != nil }) else { throw AndroidTVError.invalidPairing }
        let octets = parts.compactMap { UInt8($0) }
        guard octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168),
              (1...65535).contains(port), Self.validToken(token), fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw AndroidTVError.invalidPairing }
    }
    static func validToken(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy(AndroidTVProtocol.identifierByte)
    }
    var endpoint: URL { URL(string: "wss://\(host):\(port)/control")! }
    func replacingToken(_ token: String) -> Self {
        Self(host: host, port: port, token: token, fingerprint: fingerprint, platform: platform, name: name)
    }
}

enum AndroidTVError: Error { case invalidPairing, malformedMessage, unsupportedVersion, invalidAction }
enum AndroidTVInputStatus: String, Sendable { case ready, accessibilityRequired = "accessibility_required", screenLocked = "screen_locked", unavailable }
struct AndroidTVCapabilities: Equatable, Sendable {
    let overlayCursor: Bool, nodeClick: Bool, scroll: Bool, back: Bool, home: Bool, directionalFocus: Bool
    static let unavailable = Self(overlayCursor: false, nodeClick: false, scroll: false, back: false, home: false, directionalFocus: false)
}
struct AndroidTVStatus: Equatable, Sendable {
    let available: Bool
    let inputStatus: AndroidTVInputStatus
    let capabilities: AndroidTVCapabilities
    var tvControls: AndroidTVControls? = nil
    var appShortcuts: AndroidTVAppShortcuts? = nil
}
enum AndroidTVAppShortcut: String, CaseIterable, Sendable { case youtube, netflix }

/// This extension lives outside tvControls so older clients keep their strict
/// v1 decoder. Only known app identifiers can ever become an outgoing command.
struct AndroidTVAppShortcuts: Equatable, Sendable {
    let availableApps: [AndroidTVAppShortcut]
    static func parse(_ value: Any?) throws -> Self? {
        guard let value else { return nil }
        guard let object = value as? [String: Any],
              Set(object.keys) == ["schema", "availableApps"],
              let schema = object["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let apps = object["availableApps"] as? [String], apps.count <= 16,
              Set(apps).count == apps.count,
              apps.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 && $0.utf8.allSatisfy(AndroidTVProtocol.identifierByte) })
        else { throw AndroidTVError.malformedMessage }
        // Future allowlisted receiver apps do not create arbitrary client actions.
        return Self(availableApps: apps.compactMap(AndroidTVAppShortcut.init(rawValue:)))
    }
}
enum AndroidTVResponse: Equatable, Sendable {
    case hello(name: String, status: AndroidTVStatus, pairingToken: String?)
    case ack(id: String, ok: Bool, status: AndroidTVStatus?, error: String?)
}
enum AndroidTVKey: String, Sendable { case back, home, up, down, left, right, confirm }
enum AndroidTVAction: Equatable, Sendable {
    case move(dx: Double, dy: Double), click, scroll(dx: Double, dy: Double), key(AndroidTVKey), ping
    case remotePairStart, remotePairCode(String), remoteKey(AndroidTVKey)
    case appLaunch(AndroidTVAppShortcut)
    case textCommit(editorEpoch: UUID, text: String), textBackspace(editorEpoch: UUID), textAction(editorEpoch: UUID)

    var isText: Bool {
        switch self { case .textCommit, .textBackspace, .textAction: return true; default: return false }
    }
    var isPairing: Bool {
        switch self { case .remotePairStart, .remotePairCode: return true; default: return false }
    }
    var isLeavingPage: Bool {
        if case .appLaunch = self { return true }
        return self == .key(.back) || self == .key(.home) || self == .remoteKey(.back) || self == .remoteKey(.home)
    }
    var isDirectionalNavigation: Bool {
        guard case .remoteKey(let key) = self else { return false }
        return key == .up || key == .down || key == .left || key == .right
    }
    var isDiscrete: Bool {
        switch self { case .click, .key, .remoteKey, .appLaunch, .textCommit, .textBackspace, .textAction: return true; default: return false }
    }
}

/// No server-provided URLs or command names are executed. Input messages are bounded and allowlisted.
enum AndroidTVProtocol {
    static let maximumMessageBytes = 16_384
    static func identifierByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }
    static func encode(_ action: AndroidTVAction, id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw AndroidTVError.invalidAction }
        var object: [String: Any] = ["id": id]
        switch action {
        case .move(let dx, let dy), .scroll(let dx, let dy):
            guard dx.isFinite, dy.isFinite, abs(dx) <= 500, abs(dy) <= 500 else { throw AndroidTVError.invalidAction }
            if case .move = action { object["type"] = "move" } else { object["type"] = "scroll" }
            object["dx"] = dx; object["dy"] = dy
        case .click: object["type"] = "click"
        case .key(let key): object["type"] = "key"; object["key"] = key.rawValue
        case .remotePairStart: object["type"] = "remote_pair_start"
        case .remotePairCode(let code):
            guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw AndroidTVError.invalidAction }
            object["type"] = "remote_pair_code"; object["code"] = code.uppercased()
        case .remoteKey(let key): object["type"] = "remote_key"; object["key"] = key.rawValue
        case .appLaunch(let app): object["type"] = "app_launch"; object["app"] = app.rawValue
        case .textCommit(let epoch, let text):
            guard !text.isEmpty, text.utf8.count <= 4096, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw AndroidTVError.invalidAction }
            object["type"] = "text_commit"; object["editorEpoch"] = epoch.uuidString; object["text"] = text
        case .textBackspace(let epoch): object["type"] = "text_backspace"; object["editorEpoch"] = epoch.uuidString
        case .textAction(let epoch): object["type"] = "text_action"; object["editorEpoch"] = epoch.uuidString
        case .ping: object["type"] = "ping"
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maximumMessageBytes else { throw AndroidTVError.invalidAction }
        return String(data: data, encoding: .utf8)!
    }
    static func parse(_ text: String) throws -> AndroidTVResponse {
        guard text.utf8.count <= maximumMessageBytes,
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw AndroidTVError.malformedMessage }
        if type == "hello" {
            guard let version = object["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1, version.doubleValue == 1,
                  object["platform"] as? String == "androidtv" else { throw AndroidTVError.unsupportedVersion }
            guard let name = object["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { throw AndroidTVError.malformedMessage }
            let token = object["pairingToken"] as? String
            if object["pairingToken"] != nil && (token == nil || !AndroidTVPairing.validToken(token!)) {
                throw AndroidTVError.malformedMessage
            }
            return .hello(name: name, status: try parseStatus(object), pairingToken: token)
        }
        guard type == "ack", let id = object["id"] as? String, UUID(uuidString: id) != nil,
              let ok = boolean(object["ok"]) else { throw AndroidTVError.malformedMessage }
        let status: AndroidTVStatus?
        if object["inputAvailable"] != nil || object["inputStatus"] != nil || object["capabilities"] != nil || object["tvControls"] != nil || object["appShortcuts"] != nil {
            status = try parseStatus(object)
        } else { status = nil }
        // Error codes are never shown verbatim; retain a bounded identifier for internal classification.
        let error = object["error"] as? String
        if object["error"] != nil && (error == nil || error!.utf8.count > 64 || !error!.utf8.allSatisfy(identifierByte)) {
            throw AndroidTVError.malformedMessage
        }
        return .ack(id: id, ok: ok, status: status, error: error)
    }
    private static func parseStatus(_ object: [String: Any]) throws -> AndroidTVStatus {
        guard let available = boolean(object["inputAvailable"]),
              let rawStatus = object["inputStatus"] as? String, let status = AndroidTVInputStatus(rawValue: rawStatus),
              available == (status == .ready), let caps = object["capabilities"] as? [String: Any],
              let overlay = boolean(caps["overlayCursor"]), let click = boolean(caps["nodeClick"]),
              let scroll = boolean(caps["scroll"]), let back = boolean(caps["back"]), let home = boolean(caps["home"]),
              let focus = boolean(caps["directionalFocus"]),
              boolean(caps["text"]) == false, boolean(caps["rawMouse"]) == false,
              boolean(caps["rightClick"]) == false, boolean(caps["drag"]) == false
        else { throw AndroidTVError.malformedMessage }
        return AndroidTVStatus(available: available, inputStatus: status,
                               capabilities: .init(overlayCursor: overlay, nodeClick: click, scroll: scroll,
                                                   back: back, home: home, directionalFocus: focus),
                               tvControls: try AndroidTVControls.parse(object["tvControls"]),
                               appShortcuts: try AndroidTVAppShortcuts.parse(object["appShortcuts"]))
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
