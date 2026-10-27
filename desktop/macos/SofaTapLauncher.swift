import AppKit
import CoreServices
import ImageIO
import SwiftUI

#if !SOFATAP_UI_FIXTURE
@main
enum SofaTapLauncher {
    @MainActor static func main() {
        let options: ReceiverLaunchOptions
        do { options = try ReceiverLaunchOptions.parse(Array(CommandLine.arguments.dropFirst())) }
        catch { failLaunch(error) }
        let application = NSApplication.shared
        // Resolve before entering the application loop or creating a window/helper.
        if let id = options.testDisplayID {
            do { _ = try ReceiverTestScreen.frame(displayID: id) }
            catch { failLaunch(error) }
        }
        let delegate = LauncherDelegate(options: options)
        application.delegate = delegate
        if options.testDisplayID != nil {
            guard application.setActivationPolicy(.accessory) else {
                failLaunch(ReceiverLaunchError.displayUnavailable)
            }
        } else {
            application.setActivationPolicy(.regular)
        }
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func failLaunch(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("Sofatap: \(error)\n".utf8))
        exit(64)
    }
}

#endif

@MainActor
final class LauncherDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let receiver = ReceiverController()
    private let options: ReceiverLaunchOptions
    private lazy var updater = ReceiverUpdater(receiver: receiver)
    private let loginItem: ReceiverLoginItem
    private var window: NSWindow?
    private var isTerminating = false

    init(options: ReceiverLaunchOptions) {
        self.options = options
        self.loginItem = ReceiverLoginItem.production(arguments: Array(CommandLine.arguments.dropFirst()))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let testFrame: NSRect?
        do { testFrame = try options.testDisplayID.map { try ReceiverTestScreen.frame(displayID: $0) } }
        catch {
            FileHandle.standardError.write(Data("Sofatap: \(error)\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Sofatap", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        updater.addMenuItems(to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Sofatap", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Sofatap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        let window: NSWindow
        if testFrame != nil {
            let panel = ReceiverTestPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 700),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = false
            panel.level = .normal
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.animationBehavior = .none
            window = panel
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        }
        window.title = "Sofatap"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 17 / 255, green: 25 / 255, blue: 27 / 255, alpha: 1)
        window.contentMinSize = NSSize(width: 380, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ReceiverView(receiver: receiver, loginItem: loginItem))
        self.window = window
        if let testFrame {
            window.setFrame(testFrame, display: false)
            window.orderFrontRegardless()
            NotificationCenter.default.addObserver(self, selector: #selector(testDisplayChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
        } else {
            window.center()
            // Login items should prepare the receiver without stealing focus or
            // opening a pairing window over the user's restored applications.
            let launchEvent = NSAppleEventManager.shared().currentAppleEvent
            let launchedAtLogin = launchEvent?.eventID == kAEOpenApplication
                && launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            if !launchedAtLogin {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        receiver.start()
        loginItem.configureFirstLaunch()
        updater.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if options.testDisplayID != nil { testDisplayChanged() }
            else { window?.makeKeyAndOrderFront(nil) }
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        loginItem.refresh()
    }

    @objc private func testDisplayChanged() {
        guard !isTerminating, let id = options.testDisplayID else { return }
        do {
            let frame = try ReceiverTestScreen.frame(displayID: id)
            window?.setFrame(frame, display: false)
            window?.orderFrontRegardless()
        } catch {
            // Never let AppKit recover a missing QA display onto a personal screen.
            window?.orderOut(nil)
            NSApp.terminate(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if options.testDisplayID != nil || CommandLine.arguments.contains("--dry-run") {
            NSApp.terminate(nil)
        } else {
            // Closing the pairing window must not disconnect a paired phone.
            // Dock reopening restores it; the native Quit command stops the app.
            sender.orderOut(nil)
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        receiver.stop { [weak self] stopped in
            // Reply on the next main-loop turn, after AppKit receives terminateLater.
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: stopped)
                if !stopped { self?.isTerminating = false }
                if !stopped, self?.options.testDisplayID == nil { self?.window?.makeKeyAndOrderFront(nil) }
            }
        }
        return .terminateLater
    }
}

/// A visible, nonactivating receiver for camera/transport QA only. It cannot take
/// key focus, and the corresponding launch option always forces dry-run input.
private final class ReceiverTestPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private enum ReceiverTestScreen {
    static func frame(displayID: UInt32) throws -> NSRect {
        let displays = NSScreen.screens.compactMap { screen -> ReceiverDisplaySnapshot? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let value = id.uint32Value
            return ReceiverDisplaySnapshot(id: value, visibleFrame: screen.visibleFrame,
                isPrimary: value == CGMainDisplayID(), isMirrored: CGDisplayIsInMirrorSet(value) != 0,
                isActive: CGDisplayIsActive(value) != 0)
        }
        let style: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel]
        return try ReceiverTestPlacement.frame(displayID: displayID, displays: displays,
            preferredSize: NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 470, height: 700), styleMask: style).size,
            minimumSize: NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 380, height: 440), styleMask: style).size)
    }
}

private enum Palette {
    static let background = Color(red: 17 / 255, green: 25 / 255, blue: 27 / 255)
    static let panel = Color(red: 30 / 255, green: 42 / 255, blue: 44 / 255)
    static let border = Color(red: 51 / 255, green: 67 / 255, blue: 70 / 255)
    static let mint = Color(red: 152 / 255, green: 233 / 255, blue: 196 / 255)
    static let text = Color(red: 240 / 255, green: 245 / 255, blue: 243 / 255)
    static let muted = Color(red: 168 / 255, green: 186 / 255, blue: 183 / 255)
    static let warning = Color(red: 232 / 255, green: 192 / 255, blue: 138 / 255)
}

/// The live adapter owns no input or connection behavior. The same content can be
/// rendered offscreen with explicit, non-sensitive fixture values for layout QA.
struct ReceiverView: View {
    @ObservedObject var receiver: ReceiverController
    @ObservedObject var loginItem: ReceiverLoginItem

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ReceiverContent(
                    state: receiver.state,
                    selectedPairing: receiver.selectedPairing,
                    selectedHost: $receiver.selectedHost,
                    failure: receiver.failure,
                    isStarting: receiver.isStarting,
                    isStopping: receiver.isStopping,
                    copied: receiver.copied,
                    accessRequested: receiver.accessRequested,
                    accessNotice: receiver.accessNotice,
                    refresh: receiver.refresh,
                    requestAccess: receiver.requestAccess,
                    openAccessibilitySettings: receiver.openAccessibilitySettings,
                    copyPairing: receiver.copyPairing,
                    quit: { NSApp.terminate(nil) }
                )
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("蓝牙实验模式", isOn: Binding(
                        get: { receiver.bluetoothEnabled }, set: receiver.setBluetoothEnabled))
                        .accessibilityIdentifier("bluetoothExperimentalMode")
                    Text(receiver.bluetoothStatus).font(.footnote).foregroundStyle(Palette.muted)
                    Text("仅本次运行开启。在 iPhone 的连接模式中选择蓝牙，进行近距离对比。")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
                if loginItem.isAvailable {
                    Group {
                        if loginItem.needsFirstLaunchConsent {
                            ReceiverLoginConsentContent(requested: $loginItem.firstLaunchRequested,
                                                        confirm: loginItem.confirmFirstLaunch)
                        } else {
                            ReceiverLoginContent(
                                requested: Binding(get: { loginItem.isRequested }, set: loginItem.setRequested),
                                status: loginItem.status, failure: loginItem.failure,
                                openSettings: loginItem.openSystemSettings
                            )
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 530)
                }
            }
        }
        .background(Palette.background)
    }
}

struct ReceiverLoginConsentContent: View {
    @Binding var requested: Bool
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("登录时自动启动", isOn: $requested)
                .toggleStyle(.checkbox)
            Text("确认后，Sofatap 可在你登录 Mac 时自动准备好接收手机操作。可随时在这里关闭。")
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("确认设置", action: confirm)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.text)
        .tint(Palette.mint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReceiverLoginContent: View {
    @Binding var requested: Bool
    let status: ReceiverLoginStatus
    let failure: String?
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("登录时自动启动", isOn: $requested)
                .toggleStyle(.checkbox)
                .help("登录这台 Mac 后自动运行。关闭窗口后，Sofatap 仍可接收手机操作；选择退出才会停止。")
            if status == .requiresApproval {
                Text("等待系统允许；目前不会自动启动。")
                    .foregroundStyle(Palette.warning)
            } else if status == .unavailable {
                Text("登录项不可用，请将 Sofatap 放入应用程序后重新启用。")
                    .foregroundStyle(Palette.warning)
            }
            if let failure { Text(failure).foregroundStyle(Palette.warning) }
            if status == .requiresApproval || status == .unavailable || failure != nil {
                Button(action: openSettings) {
                    Text("打开登录项设置").underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.mint)
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Palette.text)
        .tint(Palette.mint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReceiverContent: View {
    let state: ReceiverState?
    let selectedPairing: ReceiverPairing?
    @Binding var selectedHost: String?
    let failure: String?
    let isStarting: Bool
    let isStopping: Bool
    let copied: Bool
    let accessRequested: Bool
    let accessNotice: String?
    let refresh: () -> Void
    let requestAccess: () -> Void
    let openAccessibilitySettings: () -> Void
    let copyPairing: () -> Void
    let quit: () -> Void
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable { case copy, requestAccess, settings, refresh, quit }

    var body: some View {
        VStack(spacing: 18) {
            statusPill
            heading
            notices
            #if SOFATAP_MAC_APP_STORE
            Text("商店基础版支持鼠标、滚动和文字发送；不支持自动识别输入框或实时编辑。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            #endif
            if let state, failure == nil, !isStarting, !isStopping {
                pairingCard(state)
            }
            footer
            actions
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: 530)
        .frame(maxWidth: .infinity)
        .background(Palette.background)
        .foregroundStyle(Palette.text)
        .tint(Palette.mint)
        .preferredColorScheme(.dark)
    }

    private var heading: some View {
        VStack(spacing: 8) {
            Text("扫码，坐回沙发")
                .font(.system(size: 30, weight: .semibold))
                .tracking(0.2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("在 iPhone 上打开 Sofatap，扫描二维码")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusTitle: String {
        if isStopping { return "正在退出" }
        if failure != nil { return "接收器暂不可用" }
        if isStarting { return "正在准备接收器" }
        guard let state else { return "等待接收器状态" }
        let connection = state.connected ? "手机已连接" : "等待 iPhone"
        if state.dryRun || state.inputStatus == "dry_run" { return "演练模式 · \(connection)" }
        if state.inputStatus == "accessibility_required" {
            return state.connected ? "手机已连接 · 需要授权" : "需要辅助功能授权"
        }
        guard state.inputStatus == "ready" else {
            return state.connected ? "手机已连接 · 桌面不可用" : "Mac 桌面暂不可用"
        }
        if !state.connected && state.pairings.isEmpty { return "没有可配对地址" }
        return state.connected ? "手机已连接 · 桌面已就绪" : "已就绪 · 等待 iPhone"
    }

    private var statusColor: Color {
        if isStarting || isStopping { return Palette.muted }
        guard failure == nil, let state else { return Palette.warning }
        return !state.dryRun && state.inputStatus == "ready" && (state.connected || !state.pairings.isEmpty) ? Palette.mint : Palette.warning
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            if isStarting || isStopping {
                Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(Palette.muted).accessibilityHidden(true)
            } else {
                Circle().fill(statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(statusTitle)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Palette.panel, in: Capsule())
        .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var notices: some View {
        if isStopping {
            notice(icon: "hourglass", title: "正在断开连接", message: "正在断开手机并停止接收组件。", color: Palette.muted)
        } else if let failure {
            notice(icon: "exclamationmark.triangle", title: "暂时无法连接", message: failure, color: Palette.warning)
        } else if isStarting {
            notice(icon: "desktopcomputer", title: "正在准备 Mac 接收器", message: "接收组件就绪后，二维码会显示在这里。", color: Palette.muted)
        } else if let state {
            if state.dryRun || state.inputStatus == "dry_run" {
                notice(icon: "testtube.2", title: "演练模式", message: "可测试连接，但不会向 Mac 提交鼠标或键盘操作。", color: Palette.warning)
            } else if state.inputStatus == "accessibility_required" {
                permissionNotice
            } else if state.inputStatus != "ready" {
                notice(icon: "lock.display", title: "Mac 桌面暂时不可用", message: "请登录并解锁这台 Mac，再重新检查。", color: Palette.warning)
            }
        }
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("允许 Sofatap 操作 Mac", systemImage: "hand.raised")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(accessNotice ?? "需要辅助功能权限才能控制鼠标和输入文字。请在系统提示中允许 Sofatap Receiver。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { permissionButtons }
                VStack(alignment: .leading, spacing: 8) { permissionButtons }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.border, lineWidth: 1))
    }

    @ViewBuilder private var permissionButtons: some View {
        Button(accessRequested ? "再次请求授权" : "请求辅助功能授权", action: requestAccess)
            .buttonStyle(MintButtonStyle(focused: focusedAction == .requestAccess))
            .focused($focusedAction, equals: .requestAccess)
        Button("打开系统设置", action: openAccessibilitySettings)
            .buttonStyle(QuietButtonStyle(focused: focusedAction == .settings))
            .focused($focusedAction, equals: .settings)
    }

    private func pairingCard(_ state: ReceiverState) -> some View {
        VStack(spacing: 16) {
            if let pairing = selectedPairing, let data = pairing.pngData, let image = ReceiverQRCode.decode(data) {
                // Preserve every module and the complete QR quiet zone. No brand mark,
                // caption or decorative element is painted over the pairing code.
                ReceiverQRCode(image: image)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("用 iPhone 的 Sofatap 扫描此二维码以配对 Mac")
                deviceAndNetwork(state, pairing: pairing)
                Button(action: copyPairing) {
                    Label(copied ? "已复制配对链接" : "复制配对链接", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MintButtonStyle(focused: focusedAction == .copy))
                .focused($focusedAction, equals: .copy)
                .disabled(isStopping || failure != nil)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 28)).foregroundStyle(Palette.muted)
                    .padding(.top, 16).accessibilityHidden(true)
                Text(state.pairings.isEmpty ? "没有可配对的网络地址" : "无法显示二维码")
                    .font(.system(size: 16, weight: .semibold))
                Text(state.pairings.isEmpty ? "连接 Wi-Fi 或网线后，点下方刷新重新检查。" : "点下方刷新，重新获取配对二维码。")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.border, lineWidth: 1))
    }

    private func deviceAndNetwork(_ state: ReceiverState, pairing: ReceiverPairing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Label {
                Text(state.name).lineLimit(2).truncationMode(.middle)
            } icon: {
                Image(systemName: "laptopcomputer").font(.system(size: 18))
            }
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(state.name)
            Rectangle().fill(Palette.border).frame(width: 1, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                if state.pairings.count > 1 {
                    Picker("连接地址", selection: $selectedHost) {
                        ForEach(state.pairings) { address in
                            Text(address.host).tag(Optional(address.host))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .help("有多个网络时，请选择 iPhone 能访问的地址。")
                    .accessibilityLabel("连接地址：选择 iPhone 能访问的网络地址")
                } else {
                    Label("连接地址", systemImage: "network")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Text(pairing.host)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(pairing.host)
        }
        .frame(minHeight: 34)
    }

    private func notice(icon: String, title: String, message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.border, lineWidth: 1))
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                Label("iPhone 与电脑连接同一网络", systemImage: "info.circle")
                Label("配对码请勿分享", systemImage: "lock.shield")
            }
            VStack(spacing: 7) {
                Label("iPhone 与电脑连接同一网络", systemImage: "info.circle")
                Label("配对码请勿分享", systemImage: "lock.shield")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.muted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .help("二维码和配对链接可以控制这台 Mac，请勿分享。")
        .accessibilityLabel("iPhone 与电脑连接同一网络。二维码和配对链接可以控制这台 Mac，请勿分享。")
    }

    private var actions: some View {
        HStack(spacing: 24) {
            Button(action: refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                .buttonStyle(QuietButtonStyle(focused: focusedAction == .refresh))
                .focused($focusedAction, equals: .refresh)
                .disabled(isStarting || isStopping)
            Rectangle().fill(Palette.border).frame(width: 1, height: 22)
            Button(action: quit) { Label("退出", systemImage: "power") }
                .buttonStyle(QuietButtonStyle(focused: focusedAction == .quit))
                .focused($focusedAction, equals: .quit)
                .keyboardShortcut("q", modifiers: .command)
                .disabled(isStopping)
        }
    }
}

/// Decode the source pixels directly. NSImage may rasterize a small representation
/// with interpolation before SwiftUI sees it, even when Image uses `.none`.
/// Keeping CGImage pixels intact makes the production and fixture paths identical.
struct ReceiverQRCode: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: 224, height: 224)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private struct MintButtonStyle: ButtonStyle {
    var focused = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.background)
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .background(Palette.mint.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused && isEnabled ? Palette.text : .clear, lineWidth: 2).padding(-3))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct QuietButtonStyle: ButtonStyle {
    var focused = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.text.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(configuration.isPressed ? Palette.border.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused && isEnabled ? Palette.mint : .clear, lineWidth: 2).padding(-2))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
