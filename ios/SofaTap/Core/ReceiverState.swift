import Foundation
import CoreFoundation

enum RemoteTextFocus: String { case unknown, other, editable, protected }
enum SystemVolumeCommand: String, CaseIterable { case down, mute, up }

/// Additive protocol-v1 metadata. Older receivers omit it; unavailable never implies dry-run.
struct ReceiverState: Equatable {
    enum Platform: String { case windows, macos, linux, unknown }
    enum Status: String {
        case ready, dry_run, accessibility_required, desktop_unavailable, unavailable
        case permission_required, permission_pending, permission_denied, unsupported_session, dependency_missing, input_unavailable
    }

    var platform: Platform = .unknown
    var status: Status = .unavailable
    var inputAvailable: Bool = false
    var dryRun: Bool = false
    var textFocus: RemoteTextFocus = .unknown
    var focusRevision: Int = 0
    var reportsTextFocus: Bool = false
    var supportsLiveText: Bool = false
    var supportsSystemVolume: Bool = false
    var commandModifier: String { platform == .macos ? "win" : "ctrl" }
    var unavailableTitle: String {
        switch status {
        case .dry_run: return String(localized: "演练接收器 · 不会操作电脑")
        case .accessibility_required: return String(localized: "Mac 等待辅助功能授权")
        case .desktop_unavailable: return String(localized: "请登录并解锁电脑")
        case .permission_required, .permission_denied: return String(localized: "Linux 等待桌面控制授权")
        case .permission_pending: return String(localized: "请确认 Linux 系统授权")
        case .unsupported_session: return String(localized: "当前 Linux 桌面尚不支持控制")
        case .dependency_missing: return String(localized: "Linux 接收器缺少系统组件")
        case .input_unavailable: return String(localized: "电脑输入组件已停止")
        default: return String(localized: "电脑暂时无法接受操作")
        }
    }
    var unavailableMessage: String {
        switch status {
        case .dry_run: return String(localized: "接收器正在演练模式，鼠标和文字操作已停用。")
        case .accessibility_required: return String(localized: "请在 Mac 接收器页面打开辅助功能授权，并在系统设置中允许 Sofatap。")
        case .desktop_unavailable: return String(localized: "请登录并解锁电脑，保持桌面打开；连接会自动检查状态。")
        case .permission_required, .permission_denied: return String(localized: "请在 Linux 接收器点允许控制桌面，再完成系统授权。")
        case .permission_pending: return String(localized: "请在 Linux 原生系统窗口中确认；完成后会自动检查状态。")
        case .unsupported_session: return String(localized: "请查看 Linux 接收器说明，确认桌面提供受支持的 X11 或 Wayland 远程控制接口。")
        case .dependency_missing: return String(localized: "请按 Linux 接收器说明安装所需组件，再重新打开接收器。")
        case .input_unavailable: return String(localized: "请查看电脑接收器，重新授权或重启后再连接；不要自动重发文字。")
        default: return String(localized: "接收器已连接，但输入尚不可用。请查看电脑接收器页面。")
        }
    }

    static func hello(_ message: [String: Any]) -> ReceiverState? {
        guard let available = message["inputAvailable"] as? Bool else { return nil }
        let platform = (message["platform"] as? String).flatMap(Platform.init(rawValue:)) ?? .unknown
        return make(platform: platform, available: available, message: message)
    }

    func updating(_ message: [String: Any]) -> ReceiverState? {
        // Legacy ACKs have no availability metadata and leave state unchanged.
        guard let available = message["inputAvailable"] as? Bool,
              message["dryRun"] is Bool, message["inputStatus"] is String else { return nil }
        var state = Self.make(platform: platform, available: available, message: message)
        if message["liveText"] == nil { state.supportsLiveText = supportsLiveText }
        if message["systemVolume"] == nil { state.supportsSystemVolume = supportsSystemVolume }
        return state
    }

    private static func make(platform: Platform, available: Bool, message: [String: Any]) -> ReceiverState {
        let dry = message["dryRun"] as? Bool ?? false
        let code = (message["inputStatus"] as? String).flatMap(Status.init(rawValue:))
        let status: Status = dry ? .dry_run : code ?? (message["inputStatus"] == nil && available ? .ready : .unavailable)
        let canInput = available && status == .ready && !dry
        var state = ReceiverState(platform: platform, status: status, inputAvailable: canInput, dryRun: dry)
        if let capability = message["liveText"] as? [String: Any],
           LiveTextSnapshot.integer(capability["version"]) == 1 { state.supportsLiveText = true }
        if let capability = message["systemVolume"] as? [String: Any],
           LiveTextSnapshot.integer(capability["version"]) == 1 { state.supportsSystemVolume = true }
        if let focus = message["textFocus"] as? [String: Any],
           let raw = focus["state"] as? String, let kind = RemoteTextFocus(rawValue: raw),
           let revision = focus["revision"] as? NSNumber,
           CFGetTypeID(revision) != CFBooleanGetTypeID(),
           revision.doubleValue.isFinite, revision.doubleValue >= 0,
           revision.doubleValue <= Double(Int32.max), revision.doubleValue.rounded() == revision.doubleValue {
            state.reportsTextFocus = true
            if canInput { state.textFocus = kind; state.focusRevision = revision.intValue }
        }
        return state
    }
}


/// A complete editable field and its UTF-16 selection. Desktop contents stay in
/// memory for the lifetime of the editor; they are never persisted as a draft.
struct LiveTextSnapshot: Equatable {
    let text: String
    let selection: NSRange
    var fields: [String: Any] {
        ["text": text, "selectionStart": selection.location, "selectionLength": selection.length]
    }
    var valid: Bool {
        let units = Array(text.utf16)
        guard units.count <= 16_000, !units.contains(0), selection.location >= 0,
              selection.length >= 0, selection.location <= units.count,
              selection.length <= units.count - selection.location else { return false }
        func boundary(_ offset: Int) -> Bool {
            offset == 0 || offset == units.count || !(0xDC00...0xDFFF).contains(units[offset])
        }
        guard boundary(selection.location), boundary(selection.location + selection.length) else { return false }
        // Reserve the same 1 KiB envelope as the receiver. Unicode may be
        // escaped differently by Foundation and System.Text.Json: use the
        // larger of the actual iOS encoding and a conservative receiver bound.
        guard let encoded = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]) else { return false }
        return max(encoded.count, receiverEscapedByteBound) <= 65_536 - 1024
    }
    private var receiverEscapedByteBound: Int {
        var count = 2 // JSON string quotes
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C: count += 2
            case 0x00...0x1F: count += 6
            case 0x10000...0x10FFFF: count += 12 // escaped UTF-16 surrogate pair
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                    count += 6
                case .spaceSeparator where scalar.value != 0x20:
                    count += 6
                default: count += scalar.utf8.count
                }
            }
        }
        return count
    }
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int32.max), number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
    static func parse(_ object: [String: Any]) -> LiveTextSnapshot? {
        guard let text = object["text"] as? String,
              let start = integer(object["selectionStart"]), let length = integer(object["selectionLength"]) else { return nil }
        let result = Self(text: text, selection: NSRange(location: start, length: length))
        return result.valid ? result : nil
    }
    /// Speech replaces the selection at recording start; later recognition
    /// corrections replace only that insertion, retaining the original suffix.
    func replacingSelection(with transcript: String) -> LiveTextSnapshot? {
        guard valid else { return nil }
        let text = (text as NSString).replacingCharacters(in: selection, with: transcript)
        let result = Self(text: text, selection: NSRange(location: selection.location + transcript.utf16.count, length: 0))
        return result.valid ? result : nil
    }
    /// Match native Backspace: erase the selection, or the composed character
    /// immediately before the caret. Preserve UTF-16 positions and emoji.
    func deletingBackward() -> LiveTextSnapshot? {
        guard valid else { return nil }
        var range = selection
        if range.length == 0 {
            guard range.location > 0 else { return self }
            range = (text as NSString).rangeOfComposedCharacterSequence(at: range.location - 1)
        }
        let result = Self(text: (text as NSString).replacingCharacters(in: range, with: ""),
                          selection: NSRange(location: range.location, length: 0))
        return result.valid ? result : nil
    }
}

enum LiveTextStatus: Equatable {
    case idle, starting, active, syncing, unsupported, paused(String)
}
