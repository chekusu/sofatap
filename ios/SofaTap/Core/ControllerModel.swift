import Foundation
import SwiftUI
import CoreMotion
import UIKit
import CryptoKit
import Darwin

enum DesktopConnectionMode: String {
    case automatic, wifi
}

enum TextDelivery: Equatable {
    case ready, sending, sent, rejected(String), uncertain
}

private enum CommandResult {
    case accepted([String: Any]), rejected(String), uncertain
}

@MainActor
final class ControllerModel: ObservableObject {
    // A TV selection suspends the desktop transport, including scene/deep-link
    // reconnects. Input must never fall back to a different device on failure.
    @Published private(set) var desktopControlEnabled = true
    @Published private(set) var pairing: Pairing?
    @Published private(set) var savedDevices: [SavedDevice<Pairing>] = []
    @Published private(set) var selectedDeviceID: UUID?
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var inputAvailable = false
    @Published private(set) var receiverState = ReceiverState()
    @Published private(set) var computerName = String(localized: "客厅电脑")
    @Published var notice = String(localized: "配对一次，坐下来就能控制电脑。")
    @Published var pairingError: String?
    private var draftDefaults: UserDefaults? = .standard
    @Published var draft: String {
        didSet {
            // Local-only recovery for a Typeless app switch or process termination.
            if !demo && !ephemeralDraft { draftDefaults?.set(draft, forKey: "localTextDraft") }
            if textDelivery == .sent && explicitTextToSend != "" { textDelivery = .ready }
            else if textDelivery == .ready && lastSentDraft != nil && explicitTextToSend == "" { textDelivery = .sent }
            // Keep the acknowledged prefix receipt when an unsent suffix is edited.
            persistDeliveryState()
        }
    }
    @Published var composing = false
    @Published var draftSelection = NSRange(location: 0, length: 0)
    @Published private(set) var liveTextStatus: LiveTextStatus = .idle
    private var ephemeralDraft = false
    private var draftRequiresTargetReview = false
    private var liveTextSession: String?
    private var liveTextRevision = 0
    private var liveTextBaseline: LiveTextSnapshot?
    private var liveTextDesired: LiveTextSnapshot?
    private var liveTextEpoch = UUID()
    private var liveTextOpenCallbacks: [() -> Void] = []
    private var liveTextOpeningSnapshot: LiveTextSnapshot?

    @Published private(set) var textDelivery: TextDelivery = .ready {
        didSet { persistDeliveryState() }
    }
    @Published private(set) var dragging = false
    @Published private(set) var airMoving = false
    @Published private(set) var sensitivity = 1.0
    @Published private(set) var volumeBusy = false
    @Published private(set) var volumeFeedback: String?
    let demo: Bool
    let unlock = ComputerUnlockController()

    private var lastSentDraft: String?
    private var sentSnapshot = ""
    private var explicitSendAttempt: UUID?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sessionDelegate: PinnedSessionDelegate?
    private static let connectionModeKey = "sofatap.desktopConnectionMode.v1"
    private var connectionDefaults: UserDefaults? = nil
    @Published private(set) var connectionMode: DesktopConnectionMode = .automatic

    @Published private(set) var peerConnectionAvailable = false
    private var availabilityDiscovery: PeerTransportDiscovery?
    private var availabilityGeneration = UUID()
    private var availabilityPairing: Pairing?
    private var availabilityMonitoringRequested = false

    func startPeerAvailabilityMonitoring() {
        availabilityMonitoringRequested = true
        guard !demo, foreground, desktopControlEnabled, let pairing,
              PeerTransportDiscovery.shouldAttempt(platform: pairing.platform) else {
            resetPeerAvailabilityMonitoring(); return
        }
        if availabilityPairing == pairing {
#if SOFATAP_CONTROLLER_TESTING
            if testPeerAvailabilityMonitor != nil { return }
#endif
            if availabilityDiscovery?.isBrowsing == true { return }
        }
        resetPeerAvailabilityMonitoring()
        availabilityPairing = pairing
        let request = availabilityGeneration
        let callback: (Bool) -> Void = { [weak self] available in
            guard let self, self.availabilityGeneration == request,
                  self.desktopControlEnabled, self.pairing == pairing else { return }
            if self.peerConnectionAvailable != available { self.peerConnectionAvailable = available }
        }
#if SOFATAP_CONTROLLER_TESTING
        if let testPeerAvailabilityMonitor { testPeerAvailabilityMonitor(callback); return }
#endif
        let discovery = PeerTransportDiscovery(serviceName: PeerTransportDiscovery.serviceName(fingerprint: pairing.fingerprint))
        availabilityDiscovery = discovery
        discovery.monitorAvailability(callback)
    }

    func stopPeerAvailabilityMonitoring() {
        availabilityMonitoringRequested = false
        resetPeerAvailabilityMonitoring()
    }

    private func resetPeerAvailabilityMonitoring() {
        availabilityGeneration = UUID()
        availabilityPairing = nil
        availabilityDiscovery?.stop(); availabilityDiscovery = nil
        peerConnectionAvailable = false
    }

    func setConnectionMode(_ mode: DesktopConnectionMode) {
        guard connectionMode != mode else { return }
        let reconnect = connected || connecting || reconnectID != nil
        connectionMode = mode
        if !demo { connectionDefaults?.set(mode.rawValue, forKey: Self.connectionModeKey) }
        // A route change ends the gesture/session; no pending input crosses routes.
        disconnect()
        if reconnect && !demo { connect() }
    }

    var usesPeerTransport: Bool { connected && peerConnectionAttempt }
    private var peerConnectionAttempt = false
    private var preferLANForNextAttempt = false
    private var routePreparation: Task<Void, Never>?
    private var peerDiscovery: PeerTransportDiscovery?
    private var peerBridge: PeerTLSBridge?
    private var generation = UUID()
    private var foreground = true
    private var manualConnectionPaused = false
    private var pairingRestorationPending = false
    private var automaticReconnectBlocked = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectID: UUID?
    private var reconnectAttempt = 0
    private var keepAliveTask: Task<Void, Never>?
    private var helloTimeout: Task<Void, Never>?
    private var motionTimer: Timer?
    private var movementFlights: [UUID: TimeInterval] = [:]
    private var motionBusy: Bool { !movementFlights.isEmpty }
    private static let movementLifetime = 0.12
    // LAN can spend 80–100 ms awaiting ACKs even when touch delivery is 120 Hz.
    // Twelve slots avoid an extra sender pause; the 120 ms oldest-flight gate
    // still prevents unlimited backlog. Keep the measured peer window unchanged.
    private var maximumMovementFlights: Int { peerConnectionAttempt ? 8 : 12 }
    private var movementTime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    // Keep the remote button down until its final queued movement is acknowledged.
    @Published private var dragReleasePending = false
    private var dragTail: (dx: Double, dy: Double)?
    private var scrollBusy = false
    private var queuedDX = 0.0
    private var queuedDY = 0.0
    private var queuedScroll = 0.0
    private var queuedMovementStart = -Double.infinity
    private var lastScroll = Date.distantPast
    private let motion = CMMotionManager()
    private struct Pending {
        let type: String
        let timer: Task<Void, Never>
        let completion: ((CommandResult) -> Void)?
    }
    private var pending: [String: Pending] = [:]
#if SOFATAP_CONTROLLER_TESTING
    // Recording transport only: compiled solely by the offscreen regression test.
    private var testLiveSend: ((String, [String: Any], @escaping ([String: Any]) -> Void) -> Void)?
    private var testSend: ((String, [String: Any], @escaping (Bool) -> Void) -> Void)?
    private var testPairingWrite: ((Pairing) throws -> DeviceLibrary<Pairing>)?
    private var testPairingConnect: ((Pairing) -> Void)?
    private var testPrepareConnection: ((@escaping (UInt16?) -> Void) -> Void)?
    private var testPairingRead: (() throws -> DeviceLibrary<Pairing>)?
    private var testScheduleReconnect: ((TimeInterval, @escaping () -> Void) -> Void)?
    private var testPeerAvailabilityMonitor: ((@escaping (Bool) -> Void) -> Void)?
    private var testWireSend: ((String) -> Void)?
    init(testPairingLibrary: DeviceLibrary<Pairing>,
         testPairingWrite: @escaping (Pairing) throws -> DeviceLibrary<Pairing>,
         testPairingConnect: @escaping (Pairing) -> Void,
         testPairingRead: (() throws -> DeviceLibrary<Pairing>)? = nil,
         testScheduleReconnect: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
         testInputSend: ((String, [String: Any], @escaping ([String: Any]) -> Void) -> Void)? = nil,
         testWireSend: ((String) -> Void)? = nil,
         testPrepareConnection: ((@escaping (UInt16?) -> Void) -> Void)? = nil,
         testConnectionDefaults: UserDefaults? = nil,
         testPeerAvailabilityMonitor: ((@escaping (Bool) -> Void) -> Void)? = nil) {
        demo = false; draftDefaults = nil; draft = ""
        pairing = testPairingLibrary.selected?.credential
        savedDevices = testPairingLibrary.devices; selectedDeviceID = testPairingLibrary.selectedID
        self.testPairingWrite = testPairingWrite; self.testPairingConnect = testPairingConnect
        self.testPairingRead = testPairingRead; self.testScheduleReconnect = testScheduleReconnect
        self.testLiveSend = testInputSend
        self.testWireSend = testWireSend
        self.testPrepareConnection = testPrepareConnection
        self.testPeerAvailabilityMonitor = testPeerAvailabilityMonitor
        self.connectionDefaults = testConnectionDefaults
        self.connectionMode = DesktopConnectionMode(rawValue: testConnectionDefaults?.string(forKey: Self.connectionModeKey) ?? "") ?? .automatic
        if testPairingRead != nil {
            pairing = nil; savedDevices = []; selectedDeviceID = nil
            pairingRestorationPending = true
            restoreSavedSelection()
        }
    }
    var testConnectionGeneration: UUID { generation }
    func testTransportFailure(retryable: Bool = true, generation: UUID? = nil) {
        transportFailed(message: "test transport failure", retryable: retryable, generation: generation ?? self.generation)
    }
    func testConnectionEstablished() {
        _ = handle(["type": "hello", "version": 1, "name": "Test PC", "platform": "windows",
                    "inputAvailable": true, "inputStatus": "ready"])
    }
    static func testMayRetry(_ error: URLError.Code, diagnostic: String? = nil, status: Int? = nil,
                             closeCode: URLSessionWebSocketTask.CloseCode = .invalid, authenticated: Bool = false) -> Bool {
        mayRetryTransport(URLError(error), diagnostic: diagnostic, status: status, closeCode: closeCode, authenticated: authenticated)
    }
    static func testMayRetryPOSIX(_ code: Int32) -> Bool {
        mayRetryTransport(NSError(domain: NSPOSIXErrorDomain, code: Int(code)), diagnostic: nil, status: nil)
    }
    func testCommandTimeout(_ type: String) -> () -> Void {
        guard let id = pending.first(where: { $0.value.type == type })?.key else { preconditionFailure("No pending command") }
        let currentGeneration = generation
        return { [weak self] in self?.commandTimedOut(id: id, generation: currentGeneration) }
    }
    func testAcknowledgeCommand(_ type: String, ok: Bool = true, error: String? = nil) {
        guard let id = pending.first(where: { $0.value.type == type })?.key else { preconditionFailure("No pending command") }
        var ack: [String: Any] = ["type": "ack", "id": id, "ok": ok]
        if let error { ack["error"] = error }
        _ = handle(ack)
    }
    init(testPeer: Bool = false, testSend: @escaping (String, [String: Any], @escaping (Bool) -> Void) -> Void) {
        demo = false
        draftDefaults = nil
        pairing = nil
        draft = ""
        connected = true
        inputAvailable = true
        self.testSend = testSend
        self.peerConnectionAttempt = testPeer
    }
    init(testLiveSend: @escaping (String, [String: Any], @escaping ([String: Any]) -> Void) -> Void,
         draftDefaults: UserDefaults? = nil) {
        demo = false; pairing = nil; draft = draftDefaults?.string(forKey: "localTextDraft") ?? ""; connected = true; inputAvailable = true
        self.draftDefaults = draftDefaults
        receiverState = ReceiverState(platform: .windows, status: .ready, inputAvailable: true,
                                      textFocus: .editable, reportsTextFocus: true, supportsLiveText: true)
        self.testLiveSend = testLiveSend
        restoreDeliveryReceipt()
    }
    convenience init(testRecordingWire: @escaping (String) -> Void) {
        self.init(testLiveSend: { _, _, _ in })
        testLiveSend = nil
        testWireSend = testRecordingWire
    }
    func testReceiveAcknowledgement(_ message: [String: Any]) -> Bool { handle(message) }
    func testFlushMovement() { flushMovement() }
    func testReceiveState(_ state: ReceiverState) { updateReceiverState(state) }
    func testReceiveFocus(_ revision: Int, editable: Bool = true, kind: RemoteTextFocus? = nil) {
        var state = receiverState; state.focusRevision = revision; state.textFocus = kind ?? (editable ? .editable : .other)
        updateReceiverState(state)
    }
    func testSwitchDeviceBoundary(liveCapable: Bool = false) {
        prepareForDeviceSwitch()
        connected = true; inputAvailable = true
        receiverState = ReceiverState(platform: .windows, status: .ready, inputAvailable: true,
                                      textFocus: .editable, reportsTextFocus: true, supportsLiveText: liveCapable)
    }
#endif

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        self.demo = demo
        self.connectionDefaults = demo ? nil : .standard
        self.connectionMode = DesktopConnectionMode(rawValue: connectionDefaults?.string(forKey: Self.connectionModeKey) ?? "") ?? .automatic
        self.desktopControlEnabled = demo || !["webos", "androidtv"].contains(UserDefaults.standard.string(forKey: "manualRemoteTarget") ?? "computer")
        self.pairing = nil
        self.draft = demo ? String(localized: "你好，帮我播放今晚想看的电影。") : UserDefaults.standard.string(forKey: "localTextDraft") ?? ""
        if demo {
            notice = String(localized: "界面演示：按钮只展示反馈，没有连接或操作电脑。")
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--demo-devices") {
                var library = DeviceLibrary<Pairing>()
                for (index, title, platform) in [(1, "Living room PC", "windows"), (2, "Studio Mac", "macos"), (3, "Cinema Linux", "linux")] {
                    let credential = Pairing(host: "192.0.2.\(index)", port: 53317,
                                             token: String(repeating: "d", count: 43), fingerprint: String(repeating: String(index), count: 64))
                    library.upsert(credential)
                    try? library.updateMetadata(library.selectedID!, name: title, platform: platform)
                }
                savedDevices = library.devices
                selectedDeviceID = library.devices.first?.id
                computerName = library.devices.first?.displayName ?? computerName
            }
#endif
        }
        else {
            pairingRestorationPending = true
            restoreSavedSelection()
            restoreDeliveryReceipt()
        }
    }

    var currentDisplayName: String {
        savedDevices.first { $0.id == selectedDeviceID }?.displayName ?? pairing?.deviceAddress ?? computerName
    }

    private func refreshSavedDevices() {
#if SOFATAP_CONTROLLER_TESTING
        if testPairingWrite != nil { return }
#endif
        do {
            let library = try PairingStore.library()
            savedDevices = library.devices
            selectedDeviceID = library.selectedID
        } catch { pairingError = error.localizedDescription }
    }

    private func updateReceiverMetadata(_ id: UUID, name: String, platform: String) {
#if SOFATAP_CONTROLLER_TESTING
        if testPairingWrite != nil { return }
#endif
        try? PairingStore.metadata(id, name: name, platform: platform)
        refreshSavedDevices()
    }

    /// Read the selected credential and library atomically. A temporarily locked
    /// Keychain must not turn an existing pairing into a permanently empty one.
    private func restoreSavedSelection() {
        guard pairingRestorationPending else { return }
        do {
            let library: DeviceLibrary<Pairing>
#if SOFATAP_CONTROLLER_TESTING
            if let testPairingRead { library = try testPairingRead() }
            else { library = try PairingStore.library() }
#else
            library = try PairingStore.library()
#endif
            pairing = library.selected?.credential
            savedDevices = library.devices
            selectedDeviceID = library.selectedID
            computerName = library.selected?.reportedName ?? pairing?.deviceAddress ?? computerName
            updateUnlockPairing(pairing)
            pairingRestorationPending = false
            pairingError = nil
        } catch { pairingError = error.localizedDescription }
    }

    func selectDevice(_ id: UUID) {
        guard !demo, let device = savedDevices.first(where: { $0.id == id }) else { return }
        do {
            // Persist the retained-draft review boundary before changing the
            // durable target, so a process kill between the two is also safe.
            if selectedDeviceID != id { prepareForDeviceSwitch() }
            else { disconnect() }
            try PairingStore.select(id)
            pairing = device.credential
            pairingRestorationPending = false
            selectedDeviceID = id
            computerName = device.reportedName ?? device.credential.deviceAddress
            unlock.setPairing(pairing)
            manualConnectionPaused = false
            desktopControlEnabled = true
            rememberManualTarget()
            pairingError = nil
            connect()
        } catch { pairingError = error.localizedDescription }
    }

    func renameDevice(_ id: UUID, name: String) {
        guard !demo else { return }
        do { try PairingStore.rename(id, name: name); refreshSavedDevices(); pairingError = nil }
        catch { pairingError = error.localizedDescription }
    }

    func removeDevice(_ id: UUID) {
        guard !demo, let device = savedDevices.first(where: { $0.id == id }) else { return }
        do {
            try PairingStore.remove(id)
            if selectedDeviceID == id {
                prepareForDeviceSwitch()
                pairing = nil
                pairingRestorationPending = false
                unlock.setPairing(nil)
            }
            unlock.forget(device.credential)
            refreshSavedDevices()
            pairingError = nil
        } catch { pairingError = error.localizedDescription }
    }

    /// User disconnects survive scene changes; only explicit connection or
    /// device selection resumes this transport.
    func disconnectDevice() {
        manualConnectionPaused = true
        disconnect()
    }

    private func prepareForDeviceSwitch() {
        stopPeerAvailabilityMonitoring()
        disconnect()
        // A receipt belongs to its original receiver. An old callback must not
        // mark a new device's draft sent or suppress an acknowledged prefix.
        explicitSendAttempt = nil
        lastSentDraft = nil
        liveTextStatus = .idle
        draftRequiresTargetReview = !draft.isEmpty
        if !draft.isEmpty { textDelivery = .uncertain }
        else { textDelivery = .ready }
    }

    private func restoreDeliveryReceipt() {
        if let defaults = draftDefaults, let marker = defaults.string(forKey: "textDeliveryMarker") {
            // A process kill must never turn a pending/accepted draft into an implicit retry.
            let count = defaults.object(forKey: "sentDraftUTF16Length") as? Int ?? draft.utf16.count
            if ["sent", "accepted-prefix"].contains(marker), count > 0, count <= draft.utf16.count,
               let prefix = Self.exactPrefix(draft, count: count),
               defaults.string(forKey: "sentDraftDigest") == digest(prefix) {
                lastSentDraft = prefix
                textDelivery = explicitTextToSend == "" ? .sent : .ready
            } else {
                textDelivery = .uncertain
            }
        }
    }

    // Session/permission availability is stable while a final drag ACK is pending.
    // The UI uses this for disconnect cleanup; canControl gates new input only.
    var controlAvailable: Bool { desktopControlEnabled && (demo || (connected && inputAvailable)) }
    var canControl: Bool { controlAvailable && !dragReleasePending }
    var canChangeSystemVolume: Bool {
        canControl && foreground && !demo && receiverState.supportsSystemVolume && !volumeBusy
    }
    var remoteTextFocus: RemoteTextFocus { controlAvailable ? receiverState.textFocus : .unknown }
    var focusRevision: Int { receiverState.focusRevision }
    var statusTitle: String {
        if demo { return String(localized: "界面演示") }
        if connecting { return String(localized: "正在安全连接…") }
        if connected { return inputAvailable ? computerName : receiverState.unavailableTitle }
        return pairing == nil ? String(localized: "尚未配对电脑") : String(localized: "已配对 · 未连接")
    }
    var statusSubtitle: String {
        if demo { return String(localized: "未连接电脑 · SIMULATOR DEMO") }
        if let pairing { return String(localized: "\(pairing.host):\(pairing.port) · 证书固定") }
        return String(localized: "iPhone 和电脑连接同一家庭网络")
    }
    var draftLength: Int { draft.utf16.count }
    var draftWithinLimit: Bool { draftLength <= 16_000 }
    var sendingText: Bool { textDelivery == .sending }
    var usesLiveText: Bool {
        // A local explicit draft belongs to the user, even when a reconnected
        // receiver advertises live editing. Only an already-opening/live session
        // may own imported field text; don't silently replace a retained draft.
        if draftRequiresTargetReview { return false }
        let retainedExplicitDraft = !ephemeralDraft && !draft.isEmpty && liveTextStatus != .starting
        return !demo && ((receiverState.supportsLiveText && liveTextStatus != .unsupported && !retainedExplicitDraft) || liveTextPaused)
    }
    var liveTextReady: Bool { liveTextStatus == .active || liveTextStatus == .syncing }
    var liveTextPaused: Bool { if case .paused = liveTextStatus { return true }; return false }
    var editorLoading: Bool { liveTextStatus == .starting }
    var liveTextDescription: String {
        switch liveTextStatus {
        case .idle: return String(localized: "点键盘或麦克风，开始同步当前输入框。")
        case .starting: return String(localized: "正在读取电脑当前输入框…")
        case .active: return String(localized: "已实时同步 · 退格、选区和全选也会同步。")
        case .syncing: return String(localized: "正在实时同步…")
        case .unsupported: return String(localized: "这个输入框不支持实时编辑，请确认后发送。")
        case .paused: return String(localized: "同步已暂停，手机文字已保留。检查电脑后重新读取输入框。")
        }
    }
    var canSendText: Bool {
        !usesLiveText && canControl && !(explicitTextToSend?.isEmpty ?? true) && draftWithinLimit && !composing && !sendingText &&
        textDelivery != .uncertain
    }
    var sentTextWasEdited: Bool { !usesLiveText && lastSentDraft != nil && explicitTextToSend == nil }
    private var explicitTextToSend: String? {
        guard let prefix = lastSentDraft else { return draft }
        guard draft.utf16.starts(with: prefix.utf16) else { return nil }
        return (draft as NSString).substring(from: prefix.utf16.count)
    }
    private static func exactPrefix(_ text: String, count: Int) -> String? {
        let units = Array(text.utf16)
        guard count >= 0, count <= units.count,
              count == units.count || !(0xDC00...0xDFFF).contains(units[count]) else { return nil }
        return (text as NSString).substring(to: count)
    }
    var textStatus: String {
        if usesLiveText { return liveTextDescription }
        if composing { return String(localized: "正在输入或听写，完成后再发送。") }
        if !draftWithinLimit { return String(localized: "文字过长，请分段发送。") }
        if sentTextWasEdited && textDelivery != .uncertain && !sendingText { return String(localized: "已发送部分已修改；电脑不会自动覆盖。请清空后输入新段，或检查电脑后允许整段重发。") }
        switch textDelivery {
        case .ready:
            if lastSentDraft != nil { return String(localized: "确认后只发送新增的文字。") }
            return liveTextStatus == .unsupported ? liveTextDescription : String(localized: "先点电脑里的输入框，再发送整段文字。")
        case .sending: return String(localized: "等待电脑确认… 请勿重复发送。")
        case .sent: return String(localized: "已向电脑系统提交文字；请在屏幕上确认内容。")
        case .rejected(let error): return String(localized: "未被电脑接受：\(error)")
        case .uncertain: return String(localized: "发送结果不完整或未确认，文字可能已输入。请先查看电脑屏幕，避免重复。")
        }
    }

    func acceptPairing(_ raw: String) {
        do {
            let newPairing = try Pairing.parse(raw)
            // A failed candidate save must not let foreground reconnect the old
            // stored target. Only successfully saving this attempt resumes it.
            manualConnectionPaused = true
            let previous = savedDevices.first(where: { $0.credential.deviceIdentity == newPairing.deviceIdentity })?.credential ?? pairing
            if pairing?.deviceIdentity != newPairing.deviceIdentity { prepareForDeviceSwitch() }
            else { disconnect(message: String(localized: "已保存新的配对。")) }
            try savePairing(newPairing)
            if let previous, previous.deviceIdentity == newPairing.deviceIdentity,
               previous.host != newPairing.host || previous.port != newPairing.port || previous.token != newPairing.token {
                // Retire credentials tied to the replaced token/address only
                // after saving succeeds. This does not enable the retired
                // account-password flow or a PIN-unlock feature.
                retireUnlockPairing(previous)
            }
            desktopControlEnabled = true
            manualConnectionPaused = false
            rememberManualTarget()
            pairing = newPairing
            pairingRestorationPending = false
            refreshSavedDevices()
            computerName = savedDevices.first { $0.id == selectedDeviceID }?.reportedName ?? newPairing.deviceAddress
            updateUnlockPairing(newPairing)
            pairingError = nil
            connect()
        } catch {
            pairingError = error.localizedDescription
        }
    }

    private func savePairing(_ pairing: Pairing) throws {
#if SOFATAP_CONTROLLER_TESTING
        if let testPairingWrite {
            let library = try testPairingWrite(pairing)
            savedDevices = library.devices; selectedDeviceID = library.selectedID
            return
        }
#endif
        try PairingStore.write(pairing)
    }
    private func retireUnlockPairing(_ pairing: Pairing) {
#if SOFATAP_CONTROLLER_TESTING
        if testPairingWrite != nil { return }
#endif
        unlock.forget(pairing)
    }
    private func updateUnlockPairing(_ pairing: Pairing?) {
#if SOFATAP_CONTROLLER_TESTING
        if testPairingWrite != nil { return }
#endif
        unlock.setPairing(pairing)
    }

    func forgetPairing() {
        if let selectedDeviceID { removeDevice(selectedDeviceID) }
    }

    func becameActive() {
        unlock.becameActive()
        foreground = true
        if !demo { restoreSavedSelection() }
        if availabilityMonitoringRequested { startPeerAvailabilityMonitoring() }
        if reconnectID == nil { connectAutomatically() }
    }

    func setDesktopControlEnabled(_ enabled: Bool, televisionTarget: String = "webos", reconnect: Bool = true) {
        guard enabled != desktopControlEnabled else {
            if !enabled { rememberManualTarget(televisionTarget: televisionTarget) }
            return
        }
        if !enabled { stopPeerAvailabilityMonitoring(); disconnect(message: String(localized: "电脑遥控已暂停，当前选择电视。")) }
        desktopControlEnabled = enabled
        rememberManualTarget(televisionTarget: televisionTarget)
        if enabled && reconnect { becameActive() }
    }

    private func rememberManualTarget(televisionTarget: String = "webos") {
        guard !demo else { return }
#if SOFATAP_CONTROLLER_TESTING
        guard testSend == nil && testLiveSend == nil && testPairingWrite == nil else { return }
#endif
        UserDefaults.standard.set(desktopControlEnabled ? "computer" : (televisionTarget == "androidtv" ? "androidtv" : "webos"), forKey: "manualRemoteTarget")
    }

    func becameInactive() {
        unlock.becameInactive()
        guard foreground else { return }
        foreground = false
        resetPeerAvailabilityMonitoring()
        stopAirMouse()
        if demo { dragging = false; return }
        disconnect(message: String(localized: "切回 App 会重新连接；草稿已留在手机上。"))
    }

    // A system permission sheet makes the app inactive without backgrounding it.
    // Pause all input but preserve the connection and explicit permission request.
    func pauseInput() {
        stopAirMouse()
        queuedDX = 0; queuedDY = 0; queuedScroll = 0
        setDragging(false)
    }

    func connect() {
        manualConnectionPaused = false
        automaticReconnectBlocked = false
        cancelReconnect()
        startConnection()
    }

    private var mayReconnectAutomatically: Bool {
        desktopControlEnabled && !demo && foreground && !manualConnectionPaused &&
            !automaticReconnectBlocked && !pairingRestorationPending &&
            pairing != nil && selectedDeviceID != nil &&
            savedDevices.first(where: { $0.id == selectedDeviceID })?.credential == pairing
    }

    private func connectAutomatically() {
        guard mayReconnectAutomatically else { return }
        startConnection()
    }

    private func startConnection() {
        guard desktopControlEnabled, !demo, foreground, !connecting, !connected,
              let pairing, let endpoint = pairing.endpoint else { return }
        generation = UUID()
        let currentGeneration = generation
        connecting = true
        inputAvailable = false
        receiverState = ReceiverState()
        notice = String(localized: "正在验证电脑证书与配对凭据…")
        let skipPeer = connectionMode == .wifi || preferLANForNextAttempt
        preferLANForNextAttempt = false
#if SOFATAP_CONTROLLER_TESTING
        if !skipPeer, let testPrepareConnection {
            testPrepareConnection { [weak self] port in
                self?.openAuthenticatedConnection(pairing: pairing, endpoint: endpoint,
                                                  generation: currentGeneration, loopbackPort: port)
            }
            return
        }
        if testPairingConnect != nil {
            openAuthenticatedConnection(pairing: pairing, endpoint: endpoint,
                                        generation: currentGeneration, loopbackPort: nil)
            return
        }
#endif
        if !skipPeer, PeerTransportDiscovery.shouldAttempt(platform: pairing.platform) {
            let discovery = PeerTransportDiscovery(serviceName: PeerTransportDiscovery.serviceName(fingerprint: pairing.fingerprint))
            peerDiscovery = discovery
            routePreparation = Task { [weak self] in
                do {
                    let peer = try await discovery.find()
                    try Task.checkCancellation()
                    guard let self, self.generation == currentGeneration else { discovery.stop(); return }
                    let bridge = PeerTLSBridge(endpoint: peer)
                    self.peerBridge = bridge
                    let port = try await bridge.start()
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration else { bridge.stop(); discovery.stop(); return }
                    self.routePreparation = nil
                    self.openAuthenticatedConnection(pairing: pairing, endpoint: endpoint,
                                                     generation: currentGeneration, loopbackPort: port)
                } catch {
                    discovery.stop()
                    guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                    self.peerBridge?.stop(); self.peerBridge = nil
                    self.peerDiscovery = nil; self.routePreparation = nil
                    // Discovery failed before any authenticated session or input.
                    self.openAuthenticatedConnection(pairing: pairing, endpoint: endpoint,
                                                     generation: currentGeneration, loopbackPort: nil)
                }
            }
            return
        }
        openAuthenticatedConnection(pairing: pairing, endpoint: endpoint,
                                    generation: currentGeneration, loopbackPort: nil)
    }

    private func openAuthenticatedConnection(pairing: Pairing, endpoint: URL,
                                             generation currentGeneration: UUID, loopbackPort: UInt16?) {
        guard generation == currentGeneration, connecting, foreground, self.pairing == pairing else { return }
        peerConnectionAttempt = loopbackPort != nil
#if SOFATAP_CONTROLLER_TESTING
        if let testPairingConnect { testPairingConnect(pairing); return }
#endif
        let transportEndpoint = loopbackPort.flatMap { URL(string: "wss://127.0.0.1:\($0)/control") } ?? endpoint
        let delegate = PinnedSessionDelegate(pairing: pairing, loopbackPort: loopbackPort)
        sessionDelegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 0
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let newSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session = newSession
        var request = URLRequest(url: transportEndpoint)
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        let task = newSession.webSocketTask(with: request)
        socket = task
        task.maximumMessageSize = 65_536
        task.resume()
        receiveNext(task, generation: currentGeneration)
        helloTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.generation == currentGeneration, !self.connected else { return }
            let retryable = Self.mayRetryTransport(URLError(.timedOut), diagnostic: self.sessionDelegate?.rejectionReason,
                                                  status: (task.response as? HTTPURLResponse)?.statusCode)
            self.transportFailed(message: String(localized: "连接超时。请检查电脑接收器、家庭网络与本地网络权限。"),
                                 retryable: retryable, generation: currentGeneration)
        }
    }

    private func cancelReconnect(resetAttempt: Bool = true) {
        reconnectID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        if resetAttempt { reconnectAttempt = 0 }
    }

    private func scheduleReconnect() {
        guard mayReconnectAutomatically, !connected, !connecting, let pairing else { return }
        let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt = min(reconnectAttempt + 1, delays.count - 1)
        let id = UUID(), currentGeneration = generation, deviceID = selectedDeviceID
        reconnectID = id
        let retry: () -> Void = { [weak self] in
            guard let self, self.reconnectID == id, self.generation == currentGeneration,
                  self.selectedDeviceID == deviceID, self.pairing == pairing,
                  self.mayReconnectAutomatically else { return }
            self.reconnectID = nil
            self.reconnectTask = nil
            self.connectAutomatically()
        }
#if SOFATAP_CONTROLLER_TESTING
        if let testScheduleReconnect { testScheduleReconnect(delay, retry); return }
#endif
        reconnectTask = Task {
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            retry()
        }
    }

    private func transportFailed(message: String, retryable: Bool, generation failedGeneration: UUID) {
        guard generation == failedGeneration else { return }
        // Disconnect invalidates every pending input; reconnect restores only the
        // authenticated transport, never an unacknowledged gesture or text frame.
        // A failed peer route should not delay recovery by rediscovering the same
        // unavailable path, even when it previously completed authentication.
        let retryWithLAN = retryable && peerConnectionAttempt
        disconnect(message: message, preservingRetryAttempt: true)
        preferLANForNextAttempt = retryWithLAN
        if retryable { scheduleReconnect() }
        else { automaticReconnectBlocked = true }
    }

    private static func mayRetryTransport(_ error: Error, diagnostic: String?, status: Int?,
                                         closeCode: URLSessionWebSocketTask.CloseCode = .invalid,
                                         authenticated: Bool = false) -> Bool {
        guard diagnostic == nil else { return false }
        if let status, status >= 400 {
            // A killed phone process can leave its old connection occupying the
            // single-controller slot briefly, until the receiver's idle timeout.
            return status == 408 || status == 409 || status == 429 || (500...599).contains(status)
        }
        let failure = error as NSError
        let terminalURLCodes: [URLError.Code] = [.secureConnectionFailed, .serverCertificateHasBadDate,
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired, .userAuthenticationRequired,
            .userCancelledAuthentication, .appTransportSecurityRequiresSecureConnection]
        if failure.domain == NSURLErrorDomain && terminalURLCodes.contains(URLError.Code(rawValue: failure.code)) { return false }
        if authenticated && (closeCode == .normalClosure || closeCode == .goingAway) { return true }
        if failure.domain == NSURLErrorDomain {
            return [URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                    .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable].contains(URLError.Code(rawValue: failure.code))
        }
        if failure.domain == NSPOSIXErrorDomain {
            return [ECONNRESET, ECONNREFUSED, ENOTCONN, ETIMEDOUT, ENETDOWN, ENETUNREACH,
                    EHOSTDOWN, EHOSTUNREACH, EPIPE].contains(Int32(failure.code))
        }
        return false
    }

    func disconnect(message: String = String(localized: "已断开连接。"), preservingRetryAttempt: Bool = false) {
        cancelReconnect(resetAttempt: !preservingRetryAttempt)
        peerConnectionAttempt = false
        preferLANForNextAttempt = false
        invalidateLiveText(pause: liveTextSession != nil || liveTextStatus == .starting)
        stopAirMouse()
        motionTimer?.invalidate()
        motionTimer = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        helloTimeout?.cancel()
        helloTimeout = nil
        // Best effort release before closing; the receiver independently releases on close/idle.
        if dragging || dragReleasePending, let socket {
            let release: [String: Any] = ["id": UUID().uuidString, "type": "button", "button": "left", "down": false]
            if let data = try? JSONSerialization.data(withJSONObject: release), let text = String(data: data, encoding: .utf8) {
                socket.send(.string(text)) { _ in }
            }
        }
        dragging = false
        dragReleasePending = false
        dragTail = nil
        generation = UUID()
        routePreparation?.cancel(); routePreparation = nil
        peerBridge?.stop(); peerBridge = nil
        peerDiscovery?.stop(); peerDiscovery = nil
        let oldSocket = socket
        let oldSession = session
        socket = nil
        session = nil
        sessionDelegate = nil
        connected = false
        connecting = false
        inputAvailable = false
        receiverState = ReceiverState()
        movementFlights.removeAll()
        scrollBusy = false
        if volumeBusy { volumeFeedback = String(localized: "音量操作未确认，请查看电脑音量后再操作。") }
        volumeBusy = false
        queuedDX = 0; queuedDY = 0; queuedScroll = 0
        let oldPending = pending.values
        pending.removeAll()
        oldPending.forEach { item in item.timer.cancel(); item.completion?(.uncertain) }
        oldSocket?.cancel(with: .goingAway, reason: nil)
        oldSession?.invalidateAndCancel()
        if !demo { notice = message }
    }

    private func receiveNext(_ task: URLSessionWebSocketTask, generation currentGeneration: UUID) {
        task.receive { [weak self] result in
#if DEBUG
            let receivedAt = ProcessInfo.processInfo.systemUptime
#endif
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
#if DEBUG
                PointerTiming.shared.sample("receiveMainWait", seconds: self.movementTime - receivedAt)
#endif
                switch result {
                case .failure(let error):
                    let diagnostic = self.sessionDelegate?.rejectionReason
                    let failureMessage = diagnostic.map { reason in
                        reason == "TLS_VERIFY_-67901"
                        ? String(localized: "电脑证书有效期超出 iOS 限制（\(reason)）。请更新电脑接收器并重新配对。")
                        : String(localized: "电脑证书校验失败（\(reason)）。请检查电脑接收器的证书并重新配对。")
                    }
                    let retryable = Self.mayRetryTransport(error, diagnostic: diagnostic,
                                                          status: (task.response as? HTTPURLResponse)?.statusCode,
                                                          closeCode: task.closeCode, authenticated: self.connected)
                    self.transportFailed(message: failureMessage ?? String(localized: "连接中断。请检查接收器；未确认的文字不会自动重发。"),
                                         retryable: retryable, generation: currentGeneration)
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let value): data = value.data(using: .utf8)
                    case .data(let value): data = value
                    @unknown default: data = nil
                    }
                    guard let data, data.count <= 65_536,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          self.handle(object) else {
                        self.transportFailed(message: String(localized: "接收器协议不匹配，请更新手机和电脑两端。"),
                                             retryable: false, generation: currentGeneration)
                        return
                    }
                    self.receiveNext(task, generation: currentGeneration)
                }
            }
        }
    }

    private func handle(_ message: [String: Any]) -> Bool {
        switch message["type"] as? String {
        case "hello":
            guard connecting, let version = message["version"] as? Int, version == 1,
                  let name = message["name"] as? String, name.utf8.count <= 256,
                  message["inputAvailable"] is Bool,
                  let state = ReceiverState.hello(message) else { return false }
            helloTimeout?.cancel()
            helloTimeout = nil
            connecting = false
            connected = true
            cancelReconnect()
            automaticReconnectBlocked = false
            receiverState = state
            inputAvailable = state.inputAvailable
            computerName = name
            if let selectedDeviceID {
                updateReceiverMetadata(selectedDeviceID, name: name, platform: state.platform.rawValue)
            }
            // The retired account-password capability is deliberately ignored.
            // Windows Hello PIN support requires a separate verified protocol.
            notice = state.inputAvailable ? String(localized: "已连接。先点选电脑上的输入框，即可发送文字。") : state.unavailableMessage
            startTimers()
            return true
        case "ack":
            guard connected, let id = message["id"] as? String, let ok = message["ok"] as? Bool else { return false }
            guard let item = pending.removeValue(forKey: id) else { return true }
            item.timer.cancel()
            if item.type == "ping", let state = receiverState.updating(message), state != receiverState {
                let availabilityChanged = state.inputAvailable != receiverState.inputAvailable || state.status != receiverState.status
                updateReceiverState(state)
                if !inputAvailable {
                    stopAirMouse()
                    if dragging { setDragging(false) }
                }
                if availabilityChanged { notice = inputAvailable ? String(localized: "电脑已就绪，可以继续控制。") : state.unavailableMessage }
            }
            if ok { item.completion?(.accepted(message)) }
            else {
                // Preserve an allowlisted machine code for control flow. Display text
                // stays bounded and never includes server-controlled suffixes or drafts.
                let rawCode = (message["error"] as? String)?.split(separator: ":", maxSplits: 1).first.map(String.init)
                let code = rawCode.flatMap { value -> String? in
                    let allowed = ["input_busy", "input_unavailable", "invalid_frame", "input_failed", "unsupported_key", "too_large", "invalid_message", "rate_limited", "live_text_unsupported", "live_text_conflict", "live_text_changed", "live_text_uncertain", "live_text_invalid"]
                    return allowed.contains(value) ? value : nil
                } ?? "unknown_error"
                // A failed injection can have typed a prefix. Unknown errors are conservative.
                let definitelyRejected = ["input_unavailable", "invalid_frame", "input_failed", "unsupported_key", "too_large", "invalid_message", "rate_limited", "live_text_unsupported", "live_text_conflict", "live_text_changed", "live_text_uncertain", "live_text_invalid"].contains(rawCode ?? "")
                if item.type == "volume" && ["volume_unknown", "input_unknown", "input_partial"].contains(rawCode ?? "") {
                    item.completion?(.uncertain)
                } else if item.type == "text" && !definitelyRejected {
                    notice = String(localized: "电脑未完整确认操作，文字可能已经部分输入。请先查看电脑屏幕。")
                    item.completion?(.uncertain)
                } else {
                    let displayCode = code == "unknown_error" ? String(localized: "操作未完成") : code
                    notice = String(localized: "电脑未接受操作：\(displayCode)")
                    item.completion?(.rejected(code))
                }
            }
            return true
        default: return false
        }
    }

    private func startTimers() {
#if SOFATAP_CONTROLLER_TESTING
        if testPairingConnect != nil { return }
#endif
        let currentGeneration = generation
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushMovement() }
        }
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                // New receivers report only an editable-state hint, never field contents.
                let interval = self?.receiverState.reportsTextFocus == true ? 0.75 : 5.0
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.generation == currentGeneration, self.foreground else { return }
                guard !self.pending.values.contains(where: { $0.type == "ping" }) else { continue }
                self.send("ping", fields: [:], timeout: 8) { result in
                    if case .uncertain = result {
                        self.transportFailed(message: String(localized: "电脑没有响应，已停止控制。"),
                                             retryable: true, generation: currentGeneration)
                    }
                }
            }
        }
    }

    private func send(_ type: String, fields: [String: Any], timeout: Double = 8,
                      completion: ((CommandResult) -> Void)? = nil) {
#if SOFATAP_CONTROLLER_TESTING
        if let testLiveSend {
            guard connected else { completion?(.uncertain); return }
            testLiveSend(type, fields) { reply in
                if reply["uncertain"] as? Bool == true { completion?(.uncertain); return }
                completion?(reply["ok"] as? Bool == true ? .accepted(reply) : .rejected(reply["error"] as? String ?? "live_text_uncertain"))
            }
            return
        }
        if let testSend {
            guard connected else { completion?(.rejected(String(localized: "尚未连接"))); return }
            testSend(type, fields) { completion?($0 ? .accepted([:]) : .rejected("test_rejected")) }
            return
        }
#endif
#if SOFATAP_CONTROLLER_TESTING
        let recordingWire = testWireSend
#else
        let recordingWire: ((String) -> Void)? = nil
#endif
        guard connected, socket != nil || recordingWire != nil else { completion?(.rejected(String(localized: "尚未连接"))); return }
        guard pending.count < 32 else { completion?(.rejected(String(localized: "操作过快，请稍后"))); return }
        let id = UUID().uuidString
        var frame = fields
        frame["type"] = type
        frame["id"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: frame), data.count <= 65_536,
              let text = String(data: data, encoding: .utf8) else {
            completion?(.rejected(String(localized: "文字编码后超过传输限制，请拆成几段"))); return
        }
        let currentGeneration = generation
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.commandTimedOut(id: id, generation: currentGeneration)
        }
        pending[id] = Pending(type: type, timer: timer, completion: completion)
        if let recordingWire { recordingWire(text); return }
        guard let socket else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                let retryable = Self.mayRetryTransport(error, diagnostic: self.sessionDelegate?.rejectionReason,
                                                      status: (socket.response as? HTTPURLResponse)?.statusCode,
                                                      closeCode: socket.closeCode, authenticated: self.connected)
                self.transportFailed(message: String(localized: "发送时连接中断。未确认的文字不会自动重发。"),
                                     retryable: retryable, generation: currentGeneration)
            }
        }
    }

    private func commandTimedOut(id: String, generation currentGeneration: UUID) {
        guard generation == currentGeneration, pending[id] != nil else { return }
        // Keep the timed-out item in pending. Disconnect first invalidates the
        // generation and removes all pending items, then completes each once as
        // uncertain. A drag completion cannot recursively disconnect and cancel
        // the reconnect, and a text completion still receives its uncertainty.
        transportFailed(message: String(localized: "电脑响应超时，已停止控制。文字可能已输入，请查看电脑屏幕。"),
                        retryable: true, generation: currentGeneration)
    }

    /// UIKit already paces touch delivery. Sending here avoids beating that clock
    /// against an independent timer (and saves up to one timer interval of latency).
    /// The bounded window still coalesces motion when the receiver falls behind.
    func moveFromTouch(dx: Double, dy: Double) {
        move(dx: dx, dy: dy)
        flushMovement()
    }

    func move(dx: Double, dy: Double) {
        guard canControl, dx.isFinite, dy.isFinite else { return }
        if demo { return }
        // Relative distances must accumulate even while earlier packets await ACK.
        // Bound the age of the entire unsent batch, not just its newest sample.
        let now = movementTime
        if now - queuedMovementStart > Self.movementLifetime || abs(queuedDX) + abs(queuedDY) <= 0.01 {
            queuedDX = 0; queuedDY = 0; queuedMovementStart = now
        }
        queuedDX = max(-500, min(500, queuedDX + dx * sensitivity))
        queuedDY = max(-500, min(500, queuedDY + dy * sensitivity))
    }

    func scroll(dy: Double) {
        guard canControl, dy.isFinite else { return }
        if demo { return }
        queuedScroll = max(-1200, min(1200, (scrollBusy ? 0 : queuedScroll) + dy * 8))
        lastScroll = Date()
    }

    private func flushMovement() {
        guard canControl else { queuedDX = 0; queuedDY = 0; queuedScroll = 0; return }
        let now = movementTime
        if now - queuedMovementStart > Self.movementLifetime {
#if DEBUG
            if abs(queuedDX) + abs(queuedDY) > 0.01 { PointerTiming.shared.count("expiredMovementBatches") }
#endif
            queuedDX = 0; queuedDY = 0
        }
        let hasQueuedMovement = abs(queuedDX) + abs(queuedDY) > 0.01
        // Share the bounded-window decision with diagnostics, avoiding a second
        // scan per touch/ACK while keeping the same limits and age boundary.
        let windowBlocked = movementFlights.count >= maximumMovementFlights ||
            movementFlights.values.contains { now - $0 > Self.movementLifetime }
#if DEBUG
        if hasQueuedMovement && windowBlocked { PointerTiming.shared.count("movementWindowBlocked") }
#endif
        // Stop adding packets when the oldest outstanding move has stalled.
        if hasQueuedMovement && !windowBlocked {
#if DEBUG
            PointerTiming.shared.sample("unsentAge", seconds: now - queuedMovementStart)
#endif
            let dx = queuedDX, dy = queuedDY
            queuedDX = 0; queuedDY = 0
            sendMovement(dx: dx, dy: dy)
        }
        if !scrollBusy, abs(queuedScroll) > 0.01 {
            let dy = queuedScroll
            queuedScroll = 0
            if Date().timeIntervalSince(lastScroll) <= 0.12 {
                scrollBusy = true
                send("scroll", fields: ["dx": 0, "dy": dy], timeout: 4) { [weak self] _ in self?.scrollBusy = false }
            }
        }
    }

    private func sendMovement(dx: Double, dy: Double) {
        let flight = UUID(), currentGeneration = generation
        let sentDuringDrag = dragging || dragReleasePending
        movementFlights[flight] = movementTime
#if DEBUG
        PointerTiming.shared.pulse("sendInterval")
        PointerTiming.shared.count("sentMoves")
#endif
        send("move", fields: ["dx": dx, "dy": dy], timeout: 4) { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
#if DEBUG
            if let sent = self.movementFlights[flight] {
                PointerTiming.shared.sample("moveRoundTrip", seconds: self.movementTime - sent)
            }
#endif
            self.movementFlights.removeValue(forKey: flight)
            if case .accepted = result {
                if self.dragReleasePending { self.finishDragRelease() }
                else { self.flushMovement() }
            } else if case .rejected(let reason) = result,
                      reason == "input_busy", !sentDuringDrag,
                      !self.dragging, !self.dragReleasePending {
                // The receiver explicitly refused before posting an event. Keep
                // the session for a fresh gesture, never replay the queued batch.
                self.queuedDX = 0; self.queuedDY = 0
                self.queuedMovementStart = self.movementTime
            } else {
                self.disconnect(message: String(localized: "拖拽移动未得到确认，已断开并释放鼠标。"))
            }
        }
    }

    func click(_ button: String) {
        guard canControl else { return }
        endLiveTextEditing()
        feedback()
        if demo { notice = button == "left" ? String(localized: "演示：左键单击。") : String(localized: "演示：右键单击。"); return }
        send("click", fields: ["button": button])
    }

    func setDragging(_ down: Bool) {
        guard down != dragging, !down || canControl else { return }
        if down { endLiveTextEditing() }
        dragging = down
        feedback()
        if demo { notice = down ? String(localized: "演示：按住拖拽，再用触控板移动。") : String(localized: "演示：已松开拖拽。"); return }
        if !down {
            // Freeze this gesture's tail before the next run-loop tick or UI
            // cancellation can clear it. It belongs before mouse-up even if an
            // earlier move is still awaiting its ACK or the sample ages out.
            dragTail = abs(queuedDX) + abs(queuedDY) > 0.01 ? (queuedDX, queuedDY) : nil
            queuedDX = 0; queuedDY = 0
            dragReleasePending = true
            finishDragRelease()
            return
        }
        let currentGeneration = generation
        send("button", fields: ["button": "left", "down": true]) { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            if case .accepted = result { return }
            self.disconnect(message: String(localized: "拖拽状态未得到确认，已断开并释放鼠标。"))
        }
    }

    private func finishDragRelease() {
        guard dragReleasePending, !motionBusy else { return }
        let currentGeneration = generation
        if let tail = dragTail {
            dragTail = nil
            sendMovement(dx: tail.dx, dy: tail.dy)
        } else {
            send("button", fields: ["button": "left", "down": false]) { [weak self] result in
                guard let self, self.generation == currentGeneration else { return }
                if case .accepted = result { self.dragReleasePending = false }
                else { self.disconnect(message: String(localized: "拖拽状态未得到确认，已断开并释放鼠标。")) }
            }
        }
    }

    func key(_ key: String, modifiers: [String] = []) {
        guard canControl else { return }
        endLiveTextEditing()
        feedback()
        if demo { notice = String(localized: "演示：\(key.uppercased()) 快捷键。"); return }
        send("key", fields: ["key": key, "modifiers": modifiers])
    }

    /// A remote movement multiplier, not a change to the desktop's OS preference.
    /// Clear old samples when settings change so they cannot escape at a new speed.
    func setPointerSpeed(_ value: Double) {
        sensitivity = value.isFinite ? min(3, max(0.25, value)) : 1
        queuedDX = 0; queuedDY = 0
    }

    func changeSystemVolume(_ command: SystemVolumeCommand) {
        guard canChangeSystemVolume else { return }
        volumeBusy = true
        volumeFeedback = nil
        feedback()
        let currentGeneration = generation
        send("volume", fields: ["command": command.rawValue]) { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            self.volumeBusy = false
            switch result {
            case .accepted:
                // An ACK is not a measured volume level; do not invent a percentage or mute state.
                self.volumeFeedback = nil
            case .rejected:
                self.volumeFeedback = String(localized: "无法调节系统音量，请检查电脑的输出设备和接收器。")
            case .uncertain:
                self.volumeFeedback = String(localized: "音量操作未确认，请查看电脑音量后再操作。")
            }
        }
    }

    func selectAll() {
        guard !composing else { return }
        if liveTextReady { editText(draft, selection: NSRange(location: 0, length: draft.utf16.count), marked: false) }
        else { key("a", modifiers: [receiverState.commandModifier]) }
    }

    var canRemoteBackspace: Bool {
        canControl && foreground && !dragging && !composing && !sendingText &&
        textDelivery != .uncertain && !draftRequiresTargetReview && !editorLoading && !liveTextPaused &&
        remoteTextFocus != .protected && remoteTextFocus != .other && (!usesLiveText || liveTextReady)
    }

    /// An empty fallback draft has nothing local to erase, so its keyboard key
    /// can act on the current computer field. Editing any retained draft stays
    /// local; a confirmed sent prefix is never guessed to mirror the remote caret.
    func keyboardBackspaceFromEmptyDraft() {
        guard draft.isEmpty, lastSentDraft == nil, !usesLiveText else { return }
        remoteBackspace()
    }

    /// The explicit shortcut targets the computer. A live session changes its
    /// acknowledged snapshot path, not a second OS key that could delete twice.
    /// In fallback mode, the local send receipt remains an append-only receipt;
    /// remote key presses never make previously submitted text sendable again.
    func remoteBackspace() {
        guard canRemoteBackspace else { return }
        if liveTextReady {
            let snapshot = LiveTextSnapshot(text: draft, selection: draftSelection)
            guard let deletion = snapshot.deletingBackward(), deletion != snapshot else { return }
            feedback()
            editText(deletion.text, selection: deletion.selection, marked: false)
        } else {
            key("backspace")
        }
    }

    func sendText() {
        guard canSendText, let payload = explicitTextToSend, !payload.isEmpty else { return }
        feedback()
        let snapshot = draft
        sentSnapshot = snapshot
        if demo {
            lastSentDraft = draft
            textDelivery = .sent
            notice = String(localized: "演示：没有将文字发送到任何电脑。")
            return
        }
        let attempt = UUID()
        explicitSendAttempt = attempt
        textDelivery = .sending
        send("text", fields: ["text": payload]) { [weak self] result in
            guard let self, self.explicitSendAttempt == attempt else { return }
            self.explicitSendAttempt = nil
            switch result {
            case .accepted:
                self.lastSentDraft = snapshot
                self.textDelivery = self.explicitTextToSend == "" ? .sent : .ready
            case .rejected(let error): self.textDelivery = .rejected(error)
            case .uncertain: self.textDelivery = .uncertain
            }
        }
    }

    func allowManualResend() {
        guard !sendingText else { return }
        if draftRequiresTargetReview {
            ephemeralDraft = false
            draftRequiresTargetReview = false
            // Imported field text remains ephemeral until the user explicitly
            // promotes it to a draft for this target. Persist that exact draft
            // before clearing its review receipt, without sending any input.
            if !demo { draftDefaults?.set(draft, forKey: "localTextDraft") }
        }
        lastSentDraft = nil
        textDelivery = .ready
    }

    func clearDraft() {
        guard !sendingText else { return }
        if draftRequiresTargetReview { ephemeralDraft = false; draftRequiresTargetReview = false }
        if liveTextReady { editText("", selection: NSRange(location: 0, length: 0), marked: false) }
        else { draft = ""; draftSelection = NSRange(location: 0, length: 0) }
        lastSentDraft = nil
        textDelivery = .ready
    }

    /// Opening is an explicit or editable-focus-triggered snapshot request. The
    /// editor stays disabled until its initial snapshot has been acknowledged.
    func openTextEditor(completion: (() -> Void)? = nil) {
        openTextEditor(replacingRetainedDraft: false, completion: completion)
    }

    private func openTextEditor(replacingRetainedDraft: Bool, completion: (() -> Void)? = nil) {
        guard canControl, remoteTextFocus != .protected else { return }
        guard usesLiveText || replacingRetainedDraft else { completion?(); return }
        if liveTextPaused { return }
        if liveTextReady { completion?(); return }
        if let completion { liveTextOpenCallbacks.append(completion) }
        if liveTextStatus == .starting { return }
        liveTextOpeningSnapshot = LiveTextSnapshot(text: draft, selection: draftSelection)
        liveTextStatus = .starting
        let epoch = UUID(); liveTextEpoch = epoch
        send("textBegin", fields: [:]) { [weak self] result in
            guard let self, self.liveTextEpoch == epoch else { return }
            switch result {
            case .accepted(let message):
                // A speech/Typeless binding update can bypass editText while a
                // snapshot is in flight. Never import over that newer local edit.
                guard self.liveTextOpeningSnapshot == LiveTextSnapshot(text: self.draft, selection: self.draftSelection),
                      !self.composing else { self.pauseLiveText("live_text_changed"); return }
                guard let reply = message["liveText"] as? [String: Any],
                      let session = reply["session"] as? String, UUID(uuidString: session) != nil,
                      LiveTextSnapshot.integer(reply["revision"]) == 0,
                      let snapshot = LiveTextSnapshot.parse(reply) else { self.pauseLiveText("live_text_uncertain"); return }
                self.liveTextSession = session; self.liveTextRevision = 0
                self.lastSentDraft = nil
                self.liveTextBaseline = snapshot; self.liveTextDesired = snapshot
                self.ephemeralDraft = true
                self.applyLiveSnapshot(snapshot)
                self.liveTextStatus = .active
                let callbacks = self.liveTextOpenCallbacks; self.liveTextOpenCallbacks.removeAll()
                callbacks.forEach { $0() }
            case .rejected(let code) where code == "live_text_unsupported":
                self.liveTextStatus = .unsupported
                // A previous imported field must never become an append-only
                // fallback draft which would duplicate that field on Send.
                if self.ephemeralDraft { self.draft = ""; self.draftSelection = NSRange(location: 0, length: 0) }
                self.ephemeralDraft = false
                self.lastSentDraft = nil
                self.textDelivery = .ready
                let callbacks = self.liveTextOpenCallbacks; self.liveTextOpenCallbacks.removeAll()
                callbacks.forEach { $0() }
            case .rejected(let code): self.pauseLiveText(code)
            case .uncertain: self.pauseLiveText("live_text_uncertain")
            }
        }
    }

    func restartLiveTextEditing() {
        guard usesLiveText, canControl else { return }
        // User explicitly asks to replace the retained draft with a new snapshot.
        invalidateLiveText(pause: false)
        liveTextStatus = .idle
        openTextEditor(replacingRetainedDraft: true)
    }

    func editText(_ text: String, selection: NSRange, marked: Bool) {
        draft = text; draftSelection = selection; composing = marked
        let desired = LiveTextSnapshot(text: text, selection: selection)
        if liveTextStatus == .starting && (desired != liveTextOpeningSnapshot || marked) {
            // A final native callback may race with the render which disables
            // the editor. Preserve that edit rather than importing over it.
            pauseLiveText("live_text_changed")
            return
        }
        guard liveTextReady else { return }
        liveTextDesired = desired
        guard !marked else { return } // IME's provisional Latin syllables stay local.
        guard desired.valid else { pauseLiveText("live_text_invalid"); return }
        flushLiveText()
    }

    private func flushLiveText() {
        guard liveTextStatus == .active, !composing,
              let session = liveTextSession, let desired = liveTextDesired,
              desired.valid, desired != liveTextBaseline else { return }
        let epoch = liveTextEpoch, revision = liveTextRevision + 1
        var fields = desired.fields; fields["session"] = session; fields["revision"] = revision
        liveTextStatus = .syncing
        send("textSync", fields: fields) { [weak self] result in
            guard let self, self.liveTextEpoch == epoch else { return }
            switch result {
            case .accepted(let message):
                guard let reply = message["liveText"] as? [String: Any],
                      reply["session"] as? String == session,
                      LiveTextSnapshot.integer(reply["revision"]) == revision,
                      let canonical = LiveTextSnapshot.parse(reply) else { self.pauseLiveText("live_text_uncertain"); return }
                self.liveTextBaseline = canonical; self.liveTextRevision = revision
                self.liveTextStatus = .active
                if self.liveTextDesired == desired && !self.composing {
                    self.liveTextDesired = canonical
                    self.applyLiveSnapshot(canonical)
                }
                self.flushLiveText()
            case .rejected(let code): self.pauseLiveText(code)
            case .uncertain: self.pauseLiveText("live_text_uncertain")
            }
        }
    }

    private func applyLiveSnapshot(_ snapshot: LiveTextSnapshot) {
        draft = snapshot.text; draftSelection = snapshot.selection
    }
    private func pauseLiveText(_ code: String) {
        invalidateLiveText(pause: true)
        liveTextStatus = .paused(code)
        notice = String(localized: "实时编辑已暂停。请检查电脑输入框；手机上的文字不会自动重发。")
    }
    func endLiveTextEditing() {
        guard liveTextSession != nil || liveTextStatus == .starting else { return }
        let unsynchronized = liveTextStatus == .syncing || composing || liveTextDesired != liveTextBaseline
        invalidateLiveText(pause: unsynchronized)
    }
    private func invalidateLiveText(pause: Bool) {
        let session = liveTextSession
        liveTextEpoch = UUID(); liveTextSession = nil; liveTextBaseline = nil; liveTextDesired = nil; liveTextOpeningSnapshot = nil
        liveTextOpenCallbacks.removeAll()
        if pause { liveTextStatus = .paused("live_text_changed") }
        else if !liveTextPaused { liveTextStatus = .idle }
        if let session, connected { send("textEnd", fields: ["session": session]) }
    }
    private func updateReceiverState(_ state: ReceiverState) {
        if state.focusRevision != receiverState.focusRevision || !state.inputAvailable || state.textFocus == .protected {
            endLiveTextEditing()
            // A field-focus refresh must not silently promote an explicit draft
            // to live editing, hide Send, or import over its unsent continuation.
            if liveTextStatus == .unsupported && draft.isEmpty && !sendingText && textDelivery != .uncertain {
                liveTextStatus = .idle
            }
        }
        receiverState = state; inputAvailable = state.inputAvailable
    }

    func startAirMouse() {
        guard canControl, foreground, !airMoving else { return }
        if demo { airMoving = true; feedback(); return }
        guard motion.isDeviceMotionAvailable else { notice = String(localized: "这台设备没有可用的陀螺仪，请使用触控板。"); return }
        airMoving = true
        feedback()
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.airMoving else { return }
                if error != nil {
                    self.stopAirMouse()
                    self.notice = String(localized: "无法读取陀螺仪，请检查运动权限或使用触控板。")
                    return
                }
                guard let data, ProcessInfo.processInfo.systemUptime - data.timestamp <= 0.15 else { return }
                // Portrait, screen facing the user: y is left/right yaw, x is up/down pitch.
                let yaw = abs(data.rotationRate.y) < 0.015 ? 0 : data.rotationRate.y
                let pitch = abs(data.rotationRate.x) < 0.015 ? 0 : data.rotationRate.x
                self.move(dx: -yaw * 18, dy: -pitch * 18)
            }
        }
    }

    func stopAirMouse() {
        motion.stopDeviceMotionUpdates()
        airMoving = false
        queuedDX = 0; queuedDY = 0
    }

    private func feedback() {
#if SOFATAP_CONTROLLER_TESTING
        if testSend != nil || testLiveSend != nil || testPairingConnect != nil { return }
#endif
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func persistDeliveryState() {
        guard !demo, let defaults = draftDefaults else { return }
        switch textDelivery {
        case .sending:
            defaults.set(digest(sentSnapshot), forKey: "sentDraftDigest")
            defaults.set("pending", forKey: "textDeliveryMarker")
        case .sent:
            defaults.set(digest(lastSentDraft ?? sentSnapshot), forKey: "sentDraftDigest")
            defaults.set((lastSentDraft ?? sentSnapshot).utf16.count, forKey: "sentDraftUTF16Length")
            defaults.set("sent", forKey: "textDeliveryMarker")
        case .uncertain:
            defaults.set("uncertain", forKey: "textDeliveryMarker")
        case .ready, .rejected:
            if let prefix = lastSentDraft {
                defaults.set(digest(prefix), forKey: "sentDraftDigest")
                defaults.set(prefix.utf16.count, forKey: "sentDraftUTF16Length")
                defaults.set("accepted-prefix", forKey: "textDeliveryMarker")
            } else {
                defaults.removeObject(forKey: "textDeliveryMarker")
                defaults.removeObject(forKey: "sentDraftDigest")
                defaults.removeObject(forKey: "sentDraftUTF16Length")
            }
        }
    }
}
