import Foundation
import Combine

/// The free Android receiver adapter. It sends only explicit manual input and never replays it.
@MainActor
final class AndroidTVController: ObservableObject {
    enum Phase: Equatable { case idle, connecting, ready, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var saved: AndroidTVPairing?
    @Published private(set) var savedDevices: [SavedDevice<AndroidTVPairing>] = []
    @Published private(set) var selectedDeviceID: UUID?
    @Published private(set) var managementError: String?
    @Published private(set) var name = ""
    @Published private(set) var status: AndroidTVStatus?
    @Published private(set) var notice = String(localized: "扫描 Android TV 接收器中的二维码。")
    @Published private(set) var inputFeedback: String?
    @Published var textDraft = AndroidTVTextDraft()
    @Published private(set) var textCommandPending = false
    @Published private(set) var acceptedInputFeedback = 0
    @Published private(set) var rejectedInputFeedback = 0
    private var savedDrafts: [UUID: AndroidTVTextDraft] = [:]
#if SOFATAP_TV_UI_TESTING
    @Published var fixtureModeSelection: AndroidTVControlMode? = nil
    @Published private(set) var fixtureActionSummary = "UI test: no TV command"
    private var fixtureActionCount = 0
    private var uiFixture = false
    func configureUIFixture(pairingRequired: Bool, editorReady: Bool = false) {
        guard !enabled else { return }
        uiFixture = true; targetSelected = true; foreground = true; paused = false; phase = .ready
        name = "UI test · No TV"
        status = AndroidTVStatus(available: true, inputStatus: .ready,
            capabilities: .init(overlayCursor: true, nodeClick: true, scroll: true, back: true, home: true, directionalFocus: true),
            tvControls: .init(navigationStatus: pairingRequired ? .pairingRequired : .ready,
                              textStatus: editorReady ? .ready : .noEditor, editorEpoch: editorReady ? UUID() : nil),
            appShortcuts: .init(availableApps: [.youtube, .netflix]))
    }
#endif
    @Published private var paused = false
    var busy: Bool { phase == .connecting }
    var connectionReady: Bool { phase == .ready && targetSelected && foreground }
    var canControl: Bool { connectionReady && !paused && (status?.available == true || canNavigate || canInputText) }
    var canNavigate: Bool { connectionReady && !paused && status?.tvControls?.navigationStatus == .ready }
    func canLaunchApp(_ app: AndroidTVAppShortcut) -> Bool {
        connectionReady && !paused && status?.available == true && status?.appShortcuts?.availableApps.contains(app) == true
    }
    var canInputText: Bool { connectionReady && !paused && status?.tvControls?.textStatus == .ready && status?.tvControls?.editorEpoch != nil }
    var canSendText: Bool { canInputText && !textCommandPending && textDraft.delivery != .uncertain && !textDraft.text.isEmpty && textDraft.text.utf8.count <= 4096 && !textDraft.text.unicodeScalars.contains(where: { $0.value == 0 }) }
    var canEditTVText: Bool { canInputText && !textCommandPending && textDraft.delivery != .uncertain }
    var title: String {
        switch phase {
        case .idle, .failed: return String(localized: "Android TV 未连接")
        case .connecting: return String(localized: "正在连接 Android TV…")
        case .ready:
            if status?.tvControls?.navigationStatus == .ready || status?.tvControls?.textStatus == .ready { return "Android TV · " + String(localized: "已连接") }
            return status?.available == true ? String(localized: "Android TV · 实验性遥控") : String(localized: "Android TV · 等待权限")
        }
    }
    private let enabled: Bool
    private var targetSelected: Bool
    private var foreground = true
    private var manuallyDisconnected = false
    private var reconnectBlocked = false
    private var savedSelectionAvailable = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectID: UUID?
    private var reconnectAttempt = 0
#if SOFATAP_ANDROID_TV_TESTING
    var testScheduleReconnect: ((TimeInterval, @escaping () -> Void) -> Void)?
    var testInputTime: (() -> TimeInterval)?
#endif
    private var inputTime: TimeInterval {
#if SOFATAP_ANDROID_TV_TESTING
        if let testInputTime { return testInputTime() }
#endif
        return Date.timeIntervalSinceReferenceDate
    }
    private let storage: AndroidTVPairingStorage
    private let makeSocket: @MainActor () -> AndroidTVSocket
    private var socket: AndroidTVSocket?
    private var pairing: AndroidTVPairing?
    private var bootstrap = false
    private var epoch = UUID()
    private var deadline: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private struct Input {
        let action: AndroidTVAction
        let time: TimeInterval
        func isExpired(at now: TimeInterval) -> Bool {
            // Explicit page navigation waits for the single in-flight ACK, whose
            // three-second deadline closes the connection and clears this queue.
            // It must not disappear under the shorter stale-gesture deadline.
            if action.isLeavingPage || action.isText || action.isPairing || action == .remoteKey(.confirm) { return false }
            return now - time > 0.5
        }
    }
    private var queue: [Input] = []
    private var pending: (id: String, action: AndroidTVAction)?
    private var navigationInterrupted = false

    init(enabled: Bool = true, targetSelected: Bool = true, storage: AndroidTVPairingStorage = AndroidTVKeychain(),
         makeSocket: @escaping @MainActor () -> AndroidTVSocket = { AndroidTVNetworkSocket() }) {
        self.enabled = enabled; self.targetSelected = targetSelected
        self.storage = storage; self.makeSocket = makeSocket
        if enabled { refreshSavedDevices() }
    }

    var currentDisplayName: String {
        if let pairing, pairing.deviceIdentity != saved?.deviceIdentity { return pairing.name ?? pairing.deviceAddress }
        return savedDevices.first { $0.id == selectedDeviceID }?.displayName ?? saved?.deviceAddress ?? name
    }
    @discardableResult private func refreshSavedDevices() -> Bool {
        do {
            let library = try storage.library()
            if selectedDeviceID != library.selectedID {
                if let selectedDeviceID { savedDrafts[selectedDeviceID] = textDraft }
                textDraft = library.selectedID.flatMap { savedDrafts[$0] } ?? AndroidTVTextDraft()
            }
            savedDevices = library.devices; selectedDeviceID = library.selectedID
            saved = library.selected?.credential
            managementError = nil; savedSelectionAvailable = true
            return true
        } catch {
            managementError = error.localizedDescription; savedSelectionAvailable = false
            cancelReconnect()
            return false
        }
    }
    func selectDevice(_ id: UUID) {
        guard enabled else { return }
        do {
            try storage.select(id); disconnect()
            guard refreshSavedDevices(), selectedDeviceID == id else { return }
            reconnect()
        }
        catch { managementError = error.localizedDescription }
    }
    func renameDevice(_ id: UUID, name: String) {
        guard enabled else { return }
        do { try storage.rename(id, name: name); refreshSavedDevices() }
        catch { managementError = error.localizedDescription }
    }
    func removeDevice(_ id: UUID) {
        guard enabled else { return }
        do {
            try storage.remove(id)
            if selectedDeviceID == id { disconnect() }
            refreshSavedDevices()
        } catch { managementError = error.localizedDescription }
    }

    func pair(_ raw: String) {
        guard enabled, targetSelected, foreground else { return }
        manuallyDisconnected = false; reconnectBlocked = false
        guard let pairing = try? AndroidTVPairing.parse(raw) else {
            fail(String(localized: "Android TV 配对二维码无效，请在电视上生成新的二维码。")); return
        }
        connect(pairing, bootstrap: true)
    }
    /// An explicit device selection/reconnect can retry a previously rejected credential.
    func reconnect() {
        guard enabled, targetSelected, foreground, refreshSavedDevices(), let saved else { return }
        manuallyDisconnected = false; reconnectBlocked = false
        cancelReconnect()
        connect(saved, bootstrap: false)
    }
    func setTargetSelected(_ selected: Bool, reconnect: Bool = true) {
        guard selected != targetSelected else { return }
        targetSelected = selected
        closeConnection()
        if selected {
            manuallyDisconnected = false
            if reconnect, refreshSavedDevices() { connectAutomatically() }
        }
    }
    func becameActive() {
        foreground = true
#if SOFATAP_TV_UI_TESTING
        if uiFixture { paused = false; return }
#endif
        guard enabled, refreshSavedDevices() else { return }
        if reconnectID == nil { connectAutomatically() }
    }
    func becameInactive() {
#if SOFATAP_TV_UI_TESTING
        if uiFixture { foreground = false; pauseInput(); return }
#endif
        if bootstrap && phase == .connecting { reconnectBlocked = true }
        foreground = false
        closeConnection()
        notice = String(localized: "切回 App 会重新连接电视。")
    }
    private var mayReconnectAutomatically: Bool {
        enabled && targetSelected && foreground && !manuallyDisconnected && !reconnectBlocked &&
            savedSelectionAvailable && saved != nil && selectedDeviceID != nil &&
            savedDevices.first(where: { $0.id == selectedDeviceID })?.credential == saved
    }
    private func connectAutomatically() {
        guard mayReconnectAutomatically, phase != .ready, phase != .connecting, let saved else { return }
        connect(saved, bootstrap: false, preservingRetryAttempt: true)
    }
    private func connect(_ pairing: AndroidTVPairing, bootstrap: Bool, preservingRetryAttempt: Bool = false) {
        closeConnection(preservingRetryAttempt: preservingRetryAttempt)
        self.pairing = pairing; self.bootstrap = bootstrap
        phase = .connecting
        notice = String(localized: "正在验证电视加密连接…")
        let current = epoch
        let socket = makeSocket(); self.socket = socket
        socket.onFailure = { [weak self] failure in self?.failIfCurrent(current, failure: failure) }
        socket.onText = { [weak self] text in
            guard let self, self.epoch == current else { return }
            self.receive(text)
        }
        armDeadline(seconds: 12)
        socket.open(pairing)
    }
    private func receive(_ text: String) {
        do {
            switch try AndroidTVProtocol.parse(text) {
            case .hello(let name, let status, let token):
                guard phase == .connecting, let pairing,
                      bootstrap ? token != nil : token == nil else { throw AndroidTVError.malformedMessage }
                if let token {
                    // The five-minute QR token is never persisted or retried.
                    let resumed = pairing.replacingToken(token)
                    try storage.write(resumed)
                    saved = resumed; self.pairing = resumed
                }
                if let credential = self.pairing {
                    try? storage.metadata(SavedDevice(credential: credential).id, name: name, platform: "androidtv")
                }
                guard refreshSavedDevices(), saved?.deviceIdentity == self.pairing?.deviceIdentity else { throw DeviceLibraryError.unavailable }
                deadline?.cancel(); deadline = nil
                self.name = name; self.status = status; phase = .ready
                bootstrap = false
                cancelReconnect()
                updateNotice()
                startHeartbeat()
            case .ack(let id, let ok, let newStatus, let error):
                guard phase == .ready, let pending, pending.id == id else { throw AndroidTVError.malformedMessage }
                if pending.action == .ping, newStatus == nil { throw AndroidTVError.malformedMessage }
                if pending.action.isText || pending.action.isPairing || { if case .remoteKey = pending.action { return true }; return false }() {
                    guard newStatus?.tvControls != nil else { throw AndroidTVError.malformedMessage }
                }
                if case .appLaunch = pending.action {
                    guard newStatus?.appShortcuts != nil else { throw AndroidTVError.malformedMessage }
                }
                deadline?.cancel(); deadline = nil; self.pending = nil
                if let newStatus {
                    status = newStatus
                    discardUnavailableQueuedInput()
                }
                if pending.action.isText {
                    textCommandPending = false
                    if case .textCommit = pending.action {
                        if ok { textDraft.accepted() } else { textDraft.rejected() }
                    }
                }
                if ok {
                    // Motion and heartbeat acknowledgements must not immediately hide a rejected click.
                    switch pending.action {
                    case .click, .key, .remoteKey, .appLaunch, .remotePairStart, .remotePairCode, .textCommit, .textBackspace, .textAction: inputFeedback = nil
                    default: break
                    }
                    updateNotice()
                }
                else {
                    // A rejected scroll/click must not swallow a Back/Home the user
                    // already pressed to leave that page. All other queued input is stale.
                    discardQueue { !$0.action.isLeavingPage && !$0.action.isPairing }
                    if pending.action != .ping { rejectedInputFeedback &+= 1 }
                    inputFeedback = Self.inputFailureMessage(error, action: pending.action)
                    notice = inputFeedback!
                }
                drain()
            }
        } catch { fail(String(localized: "电视连接或配对未确认。请在电视上生成新二维码后重新连接。")) }
    }
    private static func inputFailureMessage(_ error: String?, action: AndroidTVAction) -> String {
        switch error {
        case "app_not_installed":
            return String(localized: "电视上未安装此应用。")
        case "app_launch_failed":
            return String(localized: "电视未能打开此应用，请在电视上检查。")
        case "pairing_required", "remote_not_ready", "remote_unavailable":
            return String(localized: "请先连接电视系统遥控服务。")
        case "invalid_pairing_code", "pairing_failed", "invalid_code":
            return String(localized: "配对码未被接受，请核对电视上显示的代码。")
        case "ime_required":
            return String(localized: "请在电视的键盘设置中启用并选择 Sofatap 输入法。")
        case "no_editor", "stale_editor", "editor_changed":
            return String(localized: "电视输入框已变化，请重新选中输入框后发送。")
        case "sensitive", "sensitive_editor", "protected_window", "protected_target":
            return String(localized: "此界面受系统保护，无法遥控。")
        case "no_focused_target", "no_focus_target":
            return String(localized: "当前没有可确认的高亮项，请先用电视方向键选择。")
        case "no_accessible_target", "action_rejected":
            if action == .click {
                return String(localized: "此位置无法点击。请移动到可点击控件，或使用确认高亮项。")
            }
            if case .scroll = action {
                return String(localized: "此区域无法滚动。请把光标移到可滚动区域。")
            }
            fallthrough
        default:
            // Do not display untrusted receiver strings verbatim.
            return String(localized: "电视未接受这次操作。请查看电视；此应用或控件可能不支持遥控。")
        }
    }
    private func updateNotice() {
        if status?.tvControls?.navigationStatus == .ready || status?.tvControls?.textStatus == .ready {
            notice = String(localized: "已连接")
            return
        }
        switch status?.inputStatus {
        case .ready:
            notice = String(localized: "实验性控制：移动屏幕上的指示光标，点击可访问控件。操作结果请以电视画面为准。")
        case .accessibilityRequired:
            notice = String(localized: "已连接。请在电视设置中启用 Sofatap 辅助功能服务，然后返回接收器。")
        case .screenLocked:
            notice = String(localized: "电视当前已锁定，请先使用电视遥控器解锁。")
        case .unavailable, nil:
            notice = String(localized: "电视输入当前不可用，请查看接收器中的权限与兼容性提示。")
        }
    }
    func move(dx: Double, dy: Double) {
        guard status?.capabilities.overlayCursor == true else { return }
        enqueue(.move(dx: dx, dy: dy))
    }
    @discardableResult func click() -> Bool {
        guard status?.capabilities.nodeClick == true else { return false }
        return enqueue(.click)
    }
    func scroll(dy: Double) {
        guard status?.capabilities.scroll == true else { return }
        // Phone gestures emit desktop wheel deltas: negative scrolls the document down.
        // Android's accessible-container action uses a positive delta for document down.
        enqueue(.scroll(dx: 0, dy: -dy))
    }
    @discardableResult func key(_ key: AndroidTVKey) -> Bool {
        let caps = status?.capabilities
        guard key == .back ? caps?.back == true : key == .home ? caps?.home == true : caps?.directionalFocus == true else { return false }
        return enqueue(.key(key))
    }
    @discardableResult func remoteKey(_ key: AndroidTVKey) -> Bool {
        guard canNavigate else { return false }
        return enqueue(.remoteKey(key))
    }
    @discardableResult func launchApp(_ app: AndroidTVAppShortcut) -> Bool {
        guard canLaunchApp(app) else { return false }
        return enqueue(.appLaunch(app))
    }
    @discardableResult func startRemotePairing() -> Bool {
        guard connectionReady, let controls = status?.tvControls, controls.navigationStatus != .unsupported else { return false }
        return enqueue(.remotePairStart)
    }
    @discardableResult func submitRemotePairingCode(_ code: String) -> Bool {
        guard connectionReady, status?.tvControls?.navigationStatus == .pairing else { return false }
        return enqueue(.remotePairCode(code))
    }
    @discardableResult func sendTextDraft() -> Bool {
        guard canSendText, let editor = status?.tvControls?.editorEpoch, let text = textDraft.begin() else { return false }
        textCommandPending = true
        guard enqueue(.textCommit(editorEpoch: editor, text: text)) else {
            textCommandPending = false; textDraft.interrupted(wasSent: false); return false
        }
        return true
    }
    @discardableResult func textBackspace() -> Bool {
        guard canEditTVText, let editor = status?.tvControls?.editorEpoch else { return false }
        textCommandPending = true
        guard enqueue(.textBackspace(editorEpoch: editor)) else { textCommandPending = false; return false }
        return true
    }
    @discardableResult func performTextAction() -> Bool {
        guard canEditTVText, let editor = status?.tvControls?.editorEpoch else { return false }
        textCommandPending = true
        guard enqueue(.textAction(editorEpoch: editor)) else { textCommandPending = false; return false }
        return true
    }
    private func permits(_ action: AndroidTVAction) -> Bool {
        guard connectionReady else { return false }
        if action.isPairing { return status?.tvControls != nil }
        guard !paused else { return false }
        switch action {
        case .remoteKey: return status?.tvControls?.navigationStatus == .ready
        case .appLaunch(let app): return canLaunchApp(app)
        case .textCommit(let editor, _), .textBackspace(let editor), .textAction(let editor):
            return status?.tvControls?.textStatus == .ready && status?.tvControls?.editorEpoch == editor
        case .ping: return true
        default: return status?.available == true
        }
    }
    private func discardQueue(where shouldRemove: (Input) -> Bool) {
        if queue.contains(where: { shouldRemove($0) && $0.action.isText }) {
            textCommandPending = false; textDraft.interrupted(wasSent: false)
        }
        queue.removeAll(where: shouldRemove)
    }
    private func discardUnavailableQueuedInput() {
        discardQueue { !permits($0.action) }
    }
    private func discardExpiredInput(at now: TimeInterval) {
        var retained: [Input] = []
        var interrupted = navigationInterrupted
        var removedConfirmation = false
        for input in queue {
            if input.isExpired(at: now) {
                if input.action.isDirectionalNavigation { interrupted = true }
                continue
            }
            if interrupted && input.action == .remoteKey(.confirm) {
                removedConfirmation = true
                continue
            }
            // Explicitly leaving the page no longer depends on its old focus.
            if input.action.isLeavingPage { interrupted = false }
            retained.append(input)
        }
        queue = retained
        navigationInterrupted = interrupted
        if removedConfirmation { reportInterruptedNavigation() }
    }
    private func reportInterruptedNavigation() {
        rejectedInputFeedback &+= 1
        inputFeedback = String(localized: "电视操作等待过久，请重新选择后确认。")
        notice = inputFeedback!
    }
    @discardableResult private func enqueue(_ action: AndroidTVAction) -> Bool {
        guard permits(action), (try? AndroidTVProtocol.encode(action, id: UUID().uuidString)) != nil else { return false }
        if action.isPairing && (pending?.action.isPairing == true || queue.contains(where: { $0.action.isPairing })) { return false }
#if SOFATAP_TV_UI_TESTING
        if uiFixture {
            fixtureActionCount += 1
            let label: String
            switch action {
            case .remoteKey(let key): label = "remote_key:" + key.rawValue
            case .appLaunch(let app): label = "app_launch:" + app.rawValue
            case .key(let key): label = "legacy_key:" + key.rawValue
            case .click: label = "legacy_click"
            case .move: label = "legacy_move"
            case .scroll: label = "legacy_scroll"
            case .ping: label = "ping"
            case .remotePairStart: label = "remote_pair_start"
            case .remotePairCode: label = "remote_pair_code"
            case .textCommit: label = "text_commit"
            case .textBackspace: label = "text_backspace"
            case .textAction: label = "text_action"
            }
            fixtureActionSummary = "UI test \(fixtureActionCount): " + label
            if action.isDiscrete { acceptedInputFeedback &+= 1 }
            if action == .remotePairStart || { if case .remotePairCode = action { return true }; return false }() {
                if var status, let controls = status.tvControls {
                    status.tvControls = .init(navigationStatus: action == .remotePairStart ? .pairing : .ready,
                                              textStatus: controls.textStatus, editorEpoch: controls.editorEpoch)
                    self.status = status
                }
            }
            if case .textCommit = action { textDraft.accepted() }
            if action.isText { textCommandPending = false }
            return true
        }
#endif
        let now = inputTime
        discardExpiredInput(at: now)
        if navigationInterrupted && action == .remoteKey(.confirm) {
            reportInterruptedNavigation(); return false
        }
        // A new deliberate navigation starts a new selection. If it expires
        // too, the next drain invalidates confirmations again.
        if action.isDirectionalNavigation || action.isLeavingPage { navigationInterrupted = false }
        if action.isLeavingPage {
            // Preserve explicit click / Back / Home ordering. Only an insertion
            // still waiting in the queue becomes unsafe when leaving its editor.
            // Motion already coalesces and expires; it cannot grow an unbounded backlog.
            discardQueue { $0.action.isText }
        }
        // Both pointer movement and wheel gestures can arrive faster than TV ACKs.
        // Coalesce only adjacent actions of the same kind, preserving click/key ordering.
        if let last = queue.last, let merged = Self.coalescing(last.action, with: action) {
            queue[queue.count - 1] = Input(action: merged, time: now)
        } else {
            guard queue.count < 24 else { fail(String(localized: "电视响应过慢，已停止发送。请查看电视后手动重新连接。")); return false }
            queue.append(Input(action: action, time: now))
        }
        if action.isDiscrete { acceptedInputFeedback &+= 1 }
        drain()
        return true
    }
    private static func coalescing(_ previous: AndroidTVAction, with next: AndroidTVAction) -> AndroidTVAction? {
        func bounded(_ value: Double) -> Double { max(-500, min(500, value)) }
        switch (previous, next) {
        case let (.move(x, y), .move(dx, dy)):
            return .move(dx: bounded(x + dx), dy: bounded(y + dy))
        case let (.scroll(x, y), .scroll(dx, dy)):
            return .scroll(dx: bounded(x + dx), dy: bounded(y + dy))
        default: return nil
        }
    }
    private func drain() {
        guard phase == .ready, pending == nil else { return }
        discardUnavailableQueuedInput()
        discardExpiredInput(at: inputTime)
        guard !queue.isEmpty else { return }
        send(queue.removeFirst().action)
    }
    private func send(_ action: AndroidTVAction) {
        guard phase == .ready, pending == nil else { return }
        let id = UUID().uuidString, current = epoch
        guard let message = try? AndroidTVProtocol.encode(action, id: id) else { return }
        pending = (id, action)
        armDeadline(seconds: 3)
        socket?.send(message) { [weak self] ok in if !ok { self?.failIfCurrent(current) } }
    }
    private func startHeartbeat() {
        let current = epoch
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, self.epoch == current, self.phase == .ready else { return }
                if self.pending == nil { self.send(.ping) }
            }
        }
    }
    private func armDeadline(seconds: UInt64) {
        deadline?.cancel()
        let current = epoch
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            self?.failIfCurrent(current)
        }
    }
    private func failIfCurrent(_ current: UUID, failure: AndroidTVSocketFailure = .transient) {
        guard epoch == current else { return }
        // A QR credential is one-use. Even a lost bootstrap hello must require a new scan.
        let retryable = failure == .transient && !bootstrap
        closeConnection(preservingRetryAttempt: true)
        phase = .failed
        if retryable && mayReconnectAutomatically {
            notice = String(localized: "电视连接中断，正在自动重连；未确认的操作不会重发。")
            scheduleReconnect()
        } else {
            reconnectBlocked = true
            notice = String(localized: "电视连接或配对未确认。请在电视上生成新二维码后重新连接。")
        }
    }
    private func scheduleReconnect() {
        guard mayReconnectAutomatically, let saved else { return }
        let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt = min(reconnectAttempt + 1, delays.count - 1)
        let id = UUID(), current = epoch, selected = selectedDeviceID
        reconnectID = id
        let retry: () -> Void = { [weak self] in
            guard let self, self.reconnectID == id, self.epoch == current,
                  self.selectedDeviceID == selected, self.saved == saved,
                  self.mayReconnectAutomatically else { return }
            self.reconnectID = nil; self.reconnectTask = nil
            self.connectAutomatically()
        }
#if SOFATAP_ANDROID_TV_TESTING
        if let testScheduleReconnect { testScheduleReconnect(delay, retry); return }
#endif
        reconnectTask = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            retry()
        }
    }
    private func cancelReconnect(resetAttempt: Bool = true) {
        reconnectID = nil; reconnectTask?.cancel(); reconnectTask = nil
        if resetAttempt { reconnectAttempt = 0 }
    }
    private func fail(_ message: String) {
        closeConnection(); reconnectBlocked = true; phase = .failed; notice = message
    }
    func pauseInput() { paused = true; discardQueue { !$0.action.isPairing } }
    func resumeInput() { paused = false }
    func disconnect() {
        manuallyDisconnected = true
        closeConnection()
        notice = String(localized: "Android TV 已断开。请手动重新连接。")
    }
    private func closeConnection(preservingRetryAttempt: Bool = false) {
        cancelReconnect(resetAttempt: !preservingRetryAttempt)
        epoch = UUID()
        deadline?.cancel(); deadline = nil; heartbeat?.cancel(); heartbeat = nil
        if pending?.action.isText == true {
            textDraft.markUncertain()
            rejectedInputFeedback &+= 1
        } else { textDraft.interrupted(wasSent: false) }
        textCommandPending = false
        socket?.close(); socket = nil; pairing = nil; pending = nil; queue.removeAll()
        status = nil; inputFeedback = nil; navigationInterrupted = false; phase = .idle
    }
    func forget() {
        guard enabled else { return }
        disconnect()
        do { try storage.delete(); refreshSavedDevices() }
        catch { fail(String(localized: "无法移除电视配对，请稍后重试。")) }
    }
}
