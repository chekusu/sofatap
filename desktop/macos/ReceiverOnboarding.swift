import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import SwiftUI

/// First-run guide and pairing panel for the menu-bar receiver: introduction, one page per
/// missing permission (Accessibility, plus any declared by an installed extension), then the
/// pairing code over an animated dot field. The panel closes itself once a phone connects.
@MainActor
final class ReceiverOnboarding: ObservableObject {
    @Published private(set) var step: ReceiverOnboardingStep = .intro
    @Published private(set) var granted: Set<ReceiverPermission> = []
    @Published private(set) var requested: Set<ReceiverPermission> = []
    let required: [ReceiverPermission]
    private let receiver: ReceiverController
    private let defaults: UserDefaults
    private var introSeen = false
    private var timer: Timer?
    private var observation: AnyCancellable?
    var onFinished: (() -> Void)?

    private static let onboardedKey = "SofatapReceiverOnboarded"

    init(receiver: ReceiverController, extensions: [ReceiverExtensionManifest], defaults: UserDefaults = .standard) {
        self.receiver = receiver
        self.defaults = defaults
        self.required = ReceiverOnboardingPolicy.required(extensions: extensions)
        self.introSeen = defaults.bool(forKey: Self.onboardedKey)
        update()
        observation = receiver.$state.dropFirst().sink { [weak self] _ in
            // Published delivers before the value changes; re-read on the next turn.
            DispatchQueue.main.async { self?.update() }
        }
    }

    var onboarded: Bool { defaults.bool(forKey: Self.onboardedKey) }
    /// True when the panel has something the person must do before Sofatap is useful.
    var needsAttention: Bool { if case .permission = step { return true }; return step == .intro || (!onboarded && step == .pair) }

    func continueFromIntro() { introSeen = true; update() }

    /// Re-checks permissions every two seconds while the panel is open, like Tuwa Device does
    /// while System Settings is in front.
    func setWatching(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    func update() {
        var now = Set<ReceiverPermission>()
        // The helper's own preflight is the authority once it reports; before that, ask
        // macOS directly so a returning user does not see a permission page flash by.
        if let state = receiver.state {
            if state.inputStatus != "accessibility_required" { now.insert(.accessibility) }
        } else if Self.accessibilityTrusted() {
            now.insert(.accessibility)
        }
        if CGPreflightScreenCaptureAccess() { now.insert(.screenRecording) }
        granted = now
        let paired = receiver.state?.connected == true
        let dryRun = receiver.state?.dryRun == true
        if paired && !onboarded && !required.contains(where: { !now.contains($0) }) {
            defaults.set(true, forKey: Self.onboardedKey)
            onFinished?()
        }
        let next = ReceiverOnboardingPolicy.step(required: required, granted: now, introSeen: introSeen,
                                                 paired: paired, onboarded: onboarded, dryRun: dryRun)
        if next != step { step = next }
    }

    private static func accessibilityTrusted() -> Bool {
        #if SOFATAP_MAC_APP_STORE
        CGPreflightPostEventAccess()
        #else
        AXIsProcessTrusted()
        #endif
    }

    func request(_ permission: ReceiverPermission) {
        requested.insert(permission)
        switch permission {
        case .accessibility: receiver.requestAccess()
        case .screenRecording: if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        }
        update()
    }

    func openSettings(_ permission: ReceiverPermission) {
        let pane = permission == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

private enum PanelPalette {
    static let background = Color(red: 17 / 255, green: 25 / 255, blue: 27 / 255)
    static let panel = Color(red: 30 / 255, green: 42 / 255, blue: 44 / 255)
    static let border = Color(red: 51 / 255, green: 67 / 255, blue: 70 / 255)
    static let mint = Color(red: 152 / 255, green: 233 / 255, blue: 196 / 255)
    static let text = Color(red: 240 / 255, green: 245 / 255, blue: 243 / 255)
    static let muted = Color(red: 168 / 255, green: 186 / 255, blue: 183 / 255)
    static let warning = Color(red: 232 / 255, green: 192 / 255, blue: 138 / 255)
}

/// The small panel opened from the menu bar.
struct ReceiverPanelView: View {
    @ObservedObject var onboarding: ReceiverOnboarding
    @ObservedObject var receiver: ReceiverController
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch onboarding.step {
            case .intro: intro
            case let .permission(permission, index, total): permissionPage(permission, index: index, total: total)
            case .pair, .done: pairing
            }
        }
        .frame(width: 380)
        .frame(minHeight: 500)
        .background(PanelPalette.background)
        .foregroundStyle(PanelPalette.text)
        .tint(PanelPalette.mint)
        .preferredColorScheme(.dark)
    }

    // MARK: Introduction

    private var intro: some View {
        VStack(spacing: 0) {
            ReceiverDotField(hole: nil).frame(height: 230)
            VStack(spacing: 10) {
                Text("把这台 Mac 交给沙发上的你").font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center)
                Text("Sofatap 让 iPhone 变成这台 Mac 的触控板和键盘。开始前需要你在系统设置里允许 \(onboarding.required.count) 项权限，大约一分钟。")
                    .font(.system(size: 13)).foregroundStyle(PanelPalette.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(onboarding.required, id: \.self) { permission in
                        Label(Self.title(permission), systemImage: Self.icon(permission)).font(.system(size: 13))
                    }
                    Label("用 iPhone 扫码配对", systemImage: "qrcode.viewfinder").font(.system(size: 13))
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 18)
            footer { Button("继续", action: onboarding.continueFromIntro).buttonStyle(PanelPrimaryButton()).keyboardShortcut(.defaultAction) }
        }
    }

    // MARK: Permissions

    private func permissionPage(_ permission: ReceiverPermission, index: Int, total: Int) -> some View {
        let done = onboarding.granted.contains(permission)
        return VStack(alignment: .leading, spacing: 14) {
            Text("第 \(index) 步，共 \(total) 步").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(PanelPalette.mint)
            Text(Self.heading(permission)).font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(Self.reason(permission)).font(.system(size: 13)).foregroundStyle(PanelPalette.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                stepRow(1, "打开 隐私与安全性 › \(Self.title(permission))") {
                    Button(onboarding.requested.contains(permission) ? "再次打开" : "打开系统设置") {
                        onboarding.request(permission)
                        onboarding.openSettings(permission)
                    }
                    .buttonStyle(PanelPrimaryButton(compact: true))
                }
                stepRow(2, "在列表里找到 \(Self.appName)，没有的话点 ＋ 选择已安装的 \(Self.appName)。") { EmptyView() }
                stepRow(3, "打开它旁边的开关。") { EmptyView() }
            }
            .padding(16)
            .background(PanelPalette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PanelPalette.border, lineWidth: 1))
            HStack(spacing: 8) {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PanelPalette.mint)
                    Text("已允许").foregroundStyle(PanelPalette.mint)
                } else {
                    ProgressView().controlSize(.small)
                    Text("正在等待授权…").foregroundStyle(PanelPalette.muted)
                }
            }
            .font(.system(size: 12))
            Text("开关已打开却没识别？在列表里选中 \(Self.appName)，点 − 删掉，再从这里重新打开系统设置。macOS 有时要求重新打开 Sofatap 才生效。")
                .font(.system(size: 11)).foregroundStyle(PanelPalette.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .safeAreaInset(edge: .bottom) {
            // Granting moves on by itself; this only puts the guide away until next launch.
            footer { Button("稍后", action: close).buttonStyle(PanelQuietButton()) }
        }
    }

    private func stepRow<Accessory: View>(_ number: Int, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.system(size: 11, weight: .bold)).frame(width: 20, height: 20)
                .background(PanelPalette.border, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }

    // MARK: Pairing

    private var pairing: some View {
        VStack(spacing: 0) {
            ZStack {
                ReceiverDotField(hole: CGSize(width: 176, height: 176))
                if let pairing = receiver.selectedPairing, let data = pairing.pngData, let image = ReceiverQRCode.decode(data) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
                        .frame(width: 150, height: 150).padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("用 iPhone 的 Sofatap 扫描此二维码以配对 Mac")
                } else if receiver.state?.connected == true {
                    Image(systemName: "checkmark.circle").font(.system(size: 54)).foregroundStyle(PanelPalette.mint)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 260)
            VStack(spacing: 8) {
                Text(receiver.state?.connected == true ? "iPhone 已连接" : "扫码，坐回沙发").font(.system(size: 22, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(PanelPalette.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let state = receiver.state, state.pairings.count > 1 {
                    Picker("连接地址", selection: $receiver.selectedHost) {
                        ForEach(state.pairings) { Text($0.host).tag(Optional($0.host)) }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(maxWidth: 220)
                }
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 16)
            footer {
                Button(receiver.copied ? "已复制" : "复制配对链接", action: receiver.copyPairing)
                    .buttonStyle(PanelQuietButton()).disabled(receiver.selectedPairing == nil)
                Spacer()
                Button("完成", action: close).buttonStyle(PanelPrimaryButton()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var subtitle: String {
        guard let state = receiver.state else { return "正在准备接收器…" }
        if state.connected { return "现在可以把手机当触控板用了。窗口关闭后，Sofatap 会留在菜单栏。" }
        let host = receiver.selectedPairing?.host ?? "没有可用的网络地址"
        return "\(state.name) · \(host)\n配对码只给自己的手机用，不要发给别人"
    }

    private func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { Spacer(minLength: 0); content() }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(PanelPalette.background)
    }

    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Sofatap Receiver"
    static func title(_ p: ReceiverPermission) -> String { p == .accessibility ? "辅助功能" : "屏幕录制" }
    static func icon(_ p: ReceiverPermission) -> String { p == .accessibility ? "accessibility" : "rectangle.dashed.badge.record" }
    static func heading(_ p: ReceiverPermission) -> String { p == .accessibility ? "允许 Sofatap 控制鼠标和键盘" : "允许 Sofatap 看到屏幕" }
    static func reason(_ p: ReceiverPermission) -> String {
        p == .accessibility
            ? "手机上的滑动、点击和打字，要通过辅助功能才能变成这台 Mac 上的鼠标和键盘操作。随时可以在系统设置里关掉。"
            : "语音操作需要看到屏幕，才能找到要点的按钮。画面只在你发起任务时读取。随时可以在系统设置里关掉。"
    }
}

/// The receiver's dot matrix, the same visual language as the iPhone touch surface. A slow
/// wave runs through it; the optional hole keeps the pairing code clear. Still when Reduce
/// Motion is on.
struct ReceiverDotField: View {
    let hole: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let spacing: CGFloat = 16
                let cols = Int(size.width / spacing) + 1, rows = Int(size.height / spacing) + 1
                let ox = (size.width - CGFloat(cols - 1) * spacing) / 2, oy = (size.height - CGFloat(rows - 1) * spacing) / 2
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for r in 0..<rows {
                    for c in 0..<cols {
                        let x = ox + CGFloat(c) * spacing, y = oy + CGFloat(r) * spacing
                        if let hole, abs(x - center.x) < hole.width / 2 + 6, abs(y - center.y) < hole.height / 2 + 6 { continue }
                        let wave = sin(Double(c) * 0.22 + Double(r) * 0.13 - t * 1.1)
                        let d = hypot(x - center.x, y - center.y)
                        let ripple = exp(-pow((Double(d) - (t * 90).truncatingRemainder(dividingBy: 420)) / 26, 2))
                        let level = min(1, 0.22 + 0.12 * wave + 0.7 * ripple)
                        let radius = 1.1 + 0.5 * wave + 1.2 * ripple
                        let dot = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                        g.fill(dot, with: .color(ripple > 0.3 ? PanelPalette.mint.opacity(level) : PanelPalette.muted.opacity(level * 0.7)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PanelPrimaryButton: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(PanelPalette.background)
            .padding(.horizontal, compact ? 12 : 18).frame(minHeight: compact ? 28 : 34)
            .background(PanelPalette.mint.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4), in: Capsule())
            .contentShape(Capsule())
    }
}

private struct PanelQuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(PanelPalette.text.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 10).frame(minHeight: 30)
            .background(configuration.isPressed ? PanelPalette.border.opacity(0.5) : .clear, in: Capsule())
            .contentShape(Capsule())
    }
}

/// Starts each extension declared by `Contents/Resources/Extensions/<id>.json` in this signed
/// app. The executable named by the manifest must sit in `Contents/Helpers/`, where codesign
/// seals nested code, and runs as a direct child of the receiver so macOS attributes its
/// privacy grants to Sofatap. It is restarted with backoff when it exits. Open source builds
/// ship no extensions.
@MainActor
final class ReceiverExtensionHost {
    private struct Entry { let manifest: ReceiverExtensionManifest; let executable: URL; var process: Process?; var failures = 0; var startedAt = Date() }
    private var entries: [Entry] = []
    private var stopping = false

    let manifests: [ReceiverExtensionManifest]

    init(bundle: Bundle = .main) {
        var found: [Entry] = []
        let contents = bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let root = contents.appendingPathComponent("Resources/Extensions", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? ReceiverExtensionManifest.decode(data),
                  !found.contains(where: { $0.manifest.id == manifest.id }) else { continue }
            let executable = helpers.appendingPathComponent(manifest.executable)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
            found.append(Entry(manifest: manifest, executable: executable))
        }
        entries = found
        manifests = found.map(\.manifest)
    }

    func startAll() { stopping = false; for index in entries.indices { launch(index) } }

    func stopAll() {
        stopping = true
        for entry in entries where entry.process?.isRunning == true { entry.process?.terminate() }
    }

    private func launch(_ index: Int) {
        guard !stopping, entries[index].process?.isRunning != true else { return }
        let entry = entries[index]
        let process = Process()
        process.executableURL = entry.executable
        process.arguments = entry.manifest.arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        environment.merge(entry.manifest.environment) { _, new in new }
        environment["SOFATAP_EXTENSION_ID"] = entry.manifest.id
        environment["SOFATAP_RECEIVER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let id = entry.manifest.id
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.exited(id: id) }
        }
        entries[index].startedAt = Date()
        do {
            try process.run()
            entries[index].process = process
        } catch {
            exited(id: id)
        }
    }

    private func exited(id: String) {
        guard !stopping, let index = entries.firstIndex(where: { $0.manifest.id == id }) else { return }
        entries[index].failures = ReceiverExtensionBackoff.failures(previous: entries[index].failures,
                                                                    ranFor: Date().timeIntervalSince(entries[index].startedAt))
        entries[index].process = nil
        let delay = ReceiverExtensionBackoff.delay(afterFailures: entries[index].failures)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let i = self.entries.firstIndex(where: { $0.manifest.id == id }) else { return }
            self.launch(i)
        }
    }
}
