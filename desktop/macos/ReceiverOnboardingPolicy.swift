import Foundation

/// A system permission the receiver (or an installed extension) needs before first use.
enum ReceiverPermission: String, CaseIterable, Codable, Sendable {
    case accessibility
    case screenRecording
}

/// The first-run pages, in order: what Sofatap does, each missing permission, then pairing.
/// Modeled on Tuwa Device's onboarding: permissions come first, one page each, and a page
/// comes back if its permission is later taken away.
enum ReceiverOnboardingStep: Equatable, Sendable {
    case intro
    case permission(ReceiverPermission, index: Int, of: Int)
    case pair
    case done
}

enum ReceiverOnboardingPolicy {
    /// Permissions to ask for: Accessibility always (mouse and keyboard), plus whatever the
    /// installed extensions declare, without duplicates and in a stable order.
    static func required(extensions: [ReceiverExtensionManifest]) -> [ReceiverPermission] {
        var wanted: Set<ReceiverPermission> = [.accessibility]
        for manifest in extensions { wanted.formUnion(manifest.permissions) }
        return ReceiverPermission.allCases.filter(wanted.contains)
    }

    /// The page to show. `introSeen` is true once the person pressed Continue on the intro;
    /// `paired` once a phone has connected. Dry-run receivers skip the permission pages.
    static func step(required: [ReceiverPermission], granted: Set<ReceiverPermission>, introSeen: Bool,
                     paired: Bool, onboarded: Bool, dryRun: Bool) -> ReceiverOnboardingStep {
        let missing = dryRun ? [] : required.filter { !granted.contains($0) }
        if onboarded {
            // A revoked permission brings its page back; otherwise there is nothing to show.
            guard let first = missing.first, let index = required.firstIndex(of: first) else { return .done }
            return .permission(first, index: index + 1, of: required.count)
        }
        if !introSeen { return .intro }
        if let first = missing.first, let index = required.firstIndex(of: first) {
            return .permission(first, index: index + 1, of: required.count)
        }
        return paired ? .done : .pair
    }
}

/// An optional helper shipped inside the app bundle (only paid builds include one). The
/// receiver starts it as its own child so macOS attributes its privacy grants to Sofatap.
struct ReceiverExtensionManifest: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let executable: String
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var permissions: [ReceiverPermission] = []
    /// When true the receiver keeps the helper's stdin open and writes a ReceiverExtensionLink
    /// line whenever the paired phone hands over a device-link token, and after each restart.
    var wantsLink = false

    enum CodingKeys: String, CodingKey { case id, name, executable, arguments, environment, permissions, wantsLink }

    init(id: String, name: String, executable: String, arguments: [String] = [],
         environment: [String: String] = [:], permissions: [ReceiverPermission] = [], wantsLink: Bool = false) {
        self.id = id; self.name = name; self.executable = executable
        self.arguments = arguments; self.environment = environment; self.permissions = permissions
        self.wantsLink = wantsLink
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        // Unknown permission names are ignored so an older receiver can still start a newer helper.
        let names = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        permissions = names.compactMap(ReceiverPermission.init(rawValue:))
        wantsLink = try c.decodeIfPresent(Bool.self, forKey: .wantsLink) ?? false
    }

    /// Only a plain file name inside the extension's own folder, and a reverse-DNS-like id.
    func validate() throws {
        let idChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(idChars.contains) else { throw ReceiverExtensionError.invalid("id") }
        guard !name.isEmpty, name.count <= 64 else { throw ReceiverExtensionError.invalid("name") }
        guard !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".." else {
            throw ReceiverExtensionError.invalid("executable")
        }
        guard arguments.count <= 32, environment.count <= 32 else { throw ReceiverExtensionError.invalid("size") }
        for key in environment.keys where key.hasPrefix("DYLD_") { throw ReceiverExtensionError.invalid("environment") }
    }

    static func decode(_ data: Data) throws -> ReceiverExtensionManifest {
        guard data.count <= 16_384 else { throw ReceiverExtensionError.invalid("size") }
        let manifest = try JSONDecoder().decode(ReceiverExtensionManifest.self, from: data)
        try manifest.validate()
        return manifest
    }
}

/// The device-link token the paired phone made for this receiver, forwarded to helpers that
/// ask for it. Held in memory only: never written to disk, environment or arguments.
struct ReceiverExtensionLink: Equatable, Sendable {
    let token: String
    let api: String
    let expiresAt: String

    /// Spec 14.2: `sbl_` plus 64 lowercase hex characters, an https API origin, a short date.
    init?(token: String, api: String, expiresAt: String) {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard token.hasPrefix("sbl_"), token.count == 68,
              token.dropFirst(4).unicodeScalars.allSatisfy(hex.contains),
              let url = URL(string: api), url.scheme == "https", url.host != nil, api.count <= 256,
              !expiresAt.isEmpty, expiresAt.count <= 64 else { return nil }
        self.token = token; self.api = api; self.expiresAt = expiresAt
    }

    /// One JSON line for the helper's stdin.
    var line: Data {
        let object: [String: String] = ["type": "link", "token": token, "api": api, "expiresAt": expiresAt]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    static let unlinkLine = Data(#"{"type":"unlink"}"#.utf8) + Data([0x0A])
}

enum ReceiverExtensionError: Error, Equatable {
    case invalid(String)
}

/// Restart delays for a helper that keeps exiting: 1 s doubling to 60 s; a run that lasted a
/// minute resets the delay.
enum ReceiverExtensionBackoff {
    static func delay(afterFailures failures: Int) -> TimeInterval {
        min(60, pow(2, Double(max(0, min(failures, 6)))))
    }
    static func failures(previous: Int, ranFor seconds: TimeInterval) -> Int {
        seconds >= 60 ? 0 : previous + 1
    }
}
