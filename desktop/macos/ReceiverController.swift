import AppKit
#if SOFATAP_MAC_APP_STORE
import CoreGraphics
#else
@preconcurrency import ApplicationServices
#endif
import Combine
import Darwin
import Foundation

/// All UI state lives on the main actor. Pipe readers and the writer run independently of AppKit.
@MainActor
final class ReceiverController: ObservableObject {
    @Published private(set) var state: ReceiverState?
    @Published var selectedHost: String?
    @Published private(set) var failure: String?
    @Published private(set) var isStarting = true
    @Published private(set) var isStopping = false
    @Published private(set) var copied = false
    @Published private(set) var accessRequested = false
    @Published private(set) var accessNotice: String?

    @Published private(set) var bluetoothEnabled = false
    @Published private(set) var bluetoothStatus = "蓝牙实验模式已关闭"
    private var bluetoothRelay: MacBluetoothRelay?
    private var bluetoothKey: String?

    func setBluetoothEnabled(_ enabled: Bool) {
        bluetoothEnabled = enabled
        if let state { updateBluetoothRelay(state) }
        else { stopBluetoothRelay() }
    }

    private func stopBluetoothRelay() {
        bluetoothKey = nil
        bluetoothRelay?.stop(); bluetoothRelay = nil
        bluetoothStatus = "蓝牙实验模式已关闭"
    }

    private func updateBluetoothRelay(_ update: ReceiverState) {
        guard bluetoothEnabled, let peer = update.peer else { stopBluetoothRelay(); return }
        let key = "\(peer.port):\(peer.fingerprint.lowercased())"
        guard key != bluetoothKey else { return }
        stopBluetoothRelay(); bluetoothKey = key
        bluetoothStatus = "正在启动蓝牙实验模式…"
        let relay = MacBluetoothRelay(backendPort: peer.port, fingerprint: peer.fingerprint) { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.bluetoothKey == key else { return }
                self.bluetoothStatus = status
            }
        }
        bluetoothRelay = relay; relay.start()
    }

    private var peerRelay: MacPeerRelay?
    private var peerRelayTask: Task<Void, Never>?
    private var peerRelayKey: String?
    private var process: Process?
    private var generation = UUID()
    private var pipes: [Pipe] = []
    private var pipeReaders: [ReceiverPipeReader] = []
    private var stateReader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var commandStream: AsyncStream<ReceiverCommand>.Continuation?
    private var watchdog: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var stopCompletion: ((Bool) -> Void)?

#if SOFATAP_RECEIVER_TESTING
    func testPeerState(_ state: ReceiverState) { updatePeerRelay(state) }
    var testPeerIdentity: ObjectIdentifier? { peerRelay.map(ObjectIdentifier.init) }
    var testPeerKey: String? { peerRelayKey }
    var testPeerReady: Bool { peerRelay?.isActive == true && peerRelayTask == nil }
    func testHelperStopped() { cleanUp() }
#endif

    var selectedPairing: ReceiverPairing? {
        state?.pairings.first { $0.host == selectedHost }
    }

    func start() {
        guard process == nil, !isStopping else { return }
        let id = UUID()
        generation = id
        state = nil
        selectedHost = nil
        failure = nil
        isStarting = true
        copied = false
        accessRequested = false
        accessNotice = nil
        #if SOFATAP_MAC_APP_STORE
        #if arch(arm64)
        let helperPath = "Contents/Helpers/arm64/SofaTapHost"
        #elseif arch(x86_64)
        let helperPath = "Contents/Helpers/x64/SofaTapHost"
        #else
        #error("Unsupported Mac App Store helper architecture")
        #endif
        #else
        let helperPath = "Contents/Helpers/SofaTapHost"
        #endif
        let helper = Bundle.main.bundleURL.appendingPathComponent(helperPath)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            fail("找不到 Mac 接收组件。请重新安装 Sofatap。")
            return
        }

        let child = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = helper
        child.arguments = ["--native-ui"] + (CommandLine.arguments.contains("--dry-run") ? ["--dry-run"] : [])
        #if SOFATAP_MAC_APP_STORE
        do {
            let directories = try ReceiverStoreDirectories.production()
            child.arguments?.append(contentsOf: ["--data-dir", directories.data.path])
            child.environment = directories.helperEnvironment(inherited: ProcessInfo.processInfo.environment)
        } catch {
            fail("无法打开 Sofatap 的应用存储空间。请确认正在使用完整的 Mac App Store 应用。")
            return
        }
        #endif
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        // Writing after a child exit must throw EPIPE instead of terminating the UI with SIGPIPE.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            fail("无法建立接收组件连接。请退出后重新打开 Sofatap。")
            return
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.didExit(id: id) }
        }
        process = child
        pipes = [input, output, errors]
        do {
            try child.run()
        } catch {
            cleanUp()
            fail("无法启动 Mac 接收组件。请确认安装完整，并检查是否已打开另一个 Sofatap。")
            return
        }
        // Only the child owns these ends after launch; close our copies so EOF is observable.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        let (commands, continuation) = AsyncStream<ReceiverCommand>.makeStream(bufferingPolicy: .bufferingOldest(16))
        commandStream = continuation
        let stdin = input.fileHandleForWriting
        writer = Task.detached { [weak self] in
            do {
                for await command in commands {
                    if Task.isCancelled { return }
                    try stdin.write(contentsOf: command.line)
                }
            } catch {
                await self?.pipeFailed(id: id)
            }
        }
        do {
            let stdout = try ReceiverPipeReader(handle: output.fileHandleForReading, parsesStates: true)
            let stderr = try ReceiverPipeReader(handle: errors.fileHandleForReading, parsesStates: false)
            pipeReaders = [stdout, stderr]
            stateReader = Task { [weak self] in
                for await event in stdout.events {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .state(let update): self?.receive(update, id: id)
                    case .ended: self?.pipeFailed(id: id)
                    }
                }
            }
        } catch {
            pipeFailed(id: id)
            return
        }
        scheduleWatchdog(id: id)
    }

    func refresh() {
        if process == nil { start() } else { send(.refresh) }
    }

    func requestAccess() {
        guard state?.inputStatus == "accessibility_required", state?.dryRun == false, !isStopping else { return }
        // Ask from the user-visible, signed .app, so macOS can identify Sofatap rather
        // than only its helper. Apple documents this prompt as asynchronous: the
        // return value is current trust, not the user's response or helper readiness.
        #if SOFATAP_MAC_APP_STORE
        // App Sandbox cannot use AXUIElement. Basic control asks only for event
        // posting access from an explicit native button click. A granted parent
        // preflight does not prove that the bundled helper can inject events.
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        #else
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        #endif
        accessRequested = true
        accessNotice = "请在系统提示中打开设置，并允许 Sofatap Receiver。若没有出现提示，可点“打开系统设置”；列表中没有应用时，点 + 选择已安装的 Sofatap Receiver.app。"
        // Leave the asynchronous system prompt in front. Do not concurrently ask
        // the helper to open Settings. Its periodic permission preflight remains the
        // authority for whether real input is available.
        send(.refresh)
    }

    func openAccessibilitySettings() {
        guard state?.inputStatus == "accessibility_required", state?.dryRun == false, !isStopping else { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(url) {
            accessNotice = "请手动打开系统设置 → 隐私与安全 → 辅助功能，允许 Sofatap Receiver，然后回到这里重新检查。"
        }
    }

    func copyPairing() {
        guard let pairing = selectedPairing, !isStopping else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(pairing.uri, forType: .string) else { return }
        copied = true
        copyTask?.cancel()
        copyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    /// Never terminate an unrelated process. If this child does not exit, keep the UI alive to retry.
    func stop(completion: @escaping (Bool) -> Void) {
        guard !isStopping else { return }
        guard let child = process, child.isRunning else { cleanUp(); completion(true); return }
        isStopping = true
        stopPeerRelay()
        stopBluetoothRelay()
        stopCompletion = completion
        state = nil
        selectedHost = nil
        watchdog?.cancel()
        send(.quit)
        stopTask = Task { [weak self, child] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, self.isStopping else { return }
            if child.isRunning { child.terminate() }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self.isStopping else { return }
            if child.isRunning {
                self.isStopping = false
                self.fail("接收组件尚未退出。请稍后再点“退出 Sofatap”。")
                let callback = self.stopCompletion
                self.stopCompletion = nil
                callback?(false)
            } else { self.didExit(id: self.generation) }
        }
    }

    private func send(_ command: ReceiverCommand) {
        guard let commandStream else { return }
        if case .dropped = commandStream.yield(command) {
            fail("接收组件暂时没有响应。请稍后重新检查。")
        }
    }

    private func receive(_ update: ReceiverState, id: UUID) {
        guard id == generation, process?.isRunning == true, !isStopping else { return }
        selectedHost = update.selectedHost(preserving: selectedHost)
        state = update
        updatePeerRelay(update)
        updateBluetoothRelay(update)
        failure = nil
        isStarting = false
        scheduleWatchdog(id: id)
    }

    private func scheduleWatchdog(id: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.generation == id, !self.isStopping else { return }
            self.fail("接收组件没有及时响应。请重新检查，或退出后再打开 Sofatap。")
        }
    }

    private func pipeFailed(id: UUID) {
        guard id == generation, process != nil, !isStopping else { return }
        fail("与 Mac 接收组件的连接已中断。请重新打开 Sofatap。")
        if process?.isRunning == true { process?.terminate() }
    }

    private func didExit(id: UUID) {
        guard id == generation, process != nil else { return }
        let wasStopping = isStopping
        let callback = stopCompletion
        stopCompletion = nil
        cleanUp()
        isStopping = false
        if wasStopping { callback?(true) }
        else { fail(failure ?? "Mac 接收组件已停止。请重新检查，或退出后再打开 Sofatap。") }
    }

    private func stopPeerRelay() {
        peerRelayTask?.cancel(); peerRelayTask = nil
        peerRelay?.stop(); peerRelay = nil
        peerRelayKey = nil
    }

    private func updatePeerRelay(_ update: ReceiverState) {
        guard MacPeerRelay.isEnabled(), let peer = update.peer else {
            stopPeerRelay(); return
        }
        let port = peer.port, fingerprint = peer.fingerprint
        let key = "\(port):\(fingerprint.lowercased())"
        guard key != peerRelayKey || (peerRelayTask == nil && peerRelay?.isActive != true) else { return }
        stopPeerRelay()
        peerRelayKey = key
        let relay = MacPeerRelay(backendPort: port, serviceName: "Sofatap-" + fingerprint.lowercased().prefix(40))
        peerRelay = relay
        peerRelayTask = Task { [weak self] in
            do {
                _ = try await relay.start()
                guard !Task.isCancelled, let self, self.peerRelayKey == key else { relay.stop(); return }
                self.peerRelayTask = nil
            } catch {
                relay.stop()
                guard !Task.isCancelled, let self, self.peerRelayKey == key else { return }
                // LAN remains available; retry discovery on the next receiver state.
                self.stopPeerRelay()
            }
        }
    }

    private func fail(_ message: String) {
        stopPeerRelay()
        stopBluetoothRelay()
        state = nil
        selectedHost = nil
        copied = false
        isStarting = false
        failure = message
    }

    private func cleanUp() {
        stopPeerRelay()
        stopBluetoothRelay()
        generation = UUID()
        watchdog?.cancel()
        stopTask?.cancel()
        copyTask?.cancel()
        commandStream?.finish()
        commandStream = nil
        writer?.cancel()
        writer = nil
        stateReader?.cancel()
        stateReader = nil
        pipeReaders.forEach { $0.cancel() }
        pipeReaders.removeAll()
        pipes.forEach {
            try? $0.fileHandleForReading.close()
            try? $0.fileHandleForWriting.close()
        }
        pipes.removeAll()
        process?.terminationHandler = nil
        process = nil
    }
}
