import AppKit
import SwiftUI

/// The receiver lives in the menu bar, like Tuwa Device: a native NSMenu with the current
/// state at the top, and a small panel for the pairing code and first-run permissions.
@MainActor
final class ReceiverStatusMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let receiver: ReceiverController
    private let loginItem: ReceiverLoginItem
    private let updater: ReceiverUpdater
    private let showPanel: () -> Void

    init(receiver: ReceiverController, loginItem: ReceiverLoginItem, updater: ReceiverUpdater, showPanel: @escaping () -> Void) {
        self.receiver = receiver
        self.loginItem = loginItem
        self.updater = updater
        self.showPanel = showPanel
        super.init()
        item.button?.image = Self.icon
        item.button?.toolTip = "Sofatap"
        item.button?.setAccessibilityLabel("Sofatap")
        menu.delegate = self
        item.menu = menu
    }

    /// Rebuilt every time it opens, so it always reflects the helper's latest state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        loginItem.refresh()
        let state = receiver.state

        let header = NSMenuItem()
        let headerView = NSHostingView(rootView: ReceiverMenuHeader(title: state?.name ?? "Sofatap",
                                                                    status: Self.status(receiver), tone: Self.tone(receiver)))
        headerView.frame.size = headerView.fittingSize
        header.view = headerView
        menu.addItem(header)
        menu.addItem(.separator())

        if state?.inputStatus == "accessibility_required", state?.dryRun == false {
            add("允许控制这台 Mac…", #selector(openPanel))
        }
        add(state?.connected == true ? "配对新 iPhone…" : "显示配对二维码…", #selector(openPanel))
        if let state, state.pairings.count > 1 {
            let hosts = NSMenu()
            for pairing in state.pairings {
                let entry = hosts.addItem(withTitle: pairing.host, action: #selector(selectHost(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = pairing.host
                entry.state = receiver.selectedPairing?.host == pairing.host ? .on : .off
            }
            let parent = NSMenuItem(title: "连接地址", action: nil, keyEquivalent: "")
            parent.submenu = hosts
            menu.addItem(parent)
        }
        add("复制配对链接", #selector(copyPairing))
        add("刷新", #selector(refresh), key: "r")
        menu.addItem(.separator())
        if loginItem.isAvailable {
            add("登录时启动", #selector(toggleLogin)).state = loginItem.isRequested ? .on : .off
        }
        updater.addMenuItems(to: menu)
        menu.addItem(.separator())
        add("关于 Sofatap", #selector(about))
        add("退出 Sofatap", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copyPairing) ? receiver.selectedPairing != nil : true
    }

    @objc private func openPanel() { showPanel() }
    @objc private func selectHost(_ sender: NSMenuItem) { receiver.selectedHost = sender.representedObject as? String }
    @objc private func copyPairing() { receiver.copyPairing() }
    @objc private func refresh() { receiver.refresh() }
    @objc private func toggleLogin() { loginItem.setRequested(!loginItem.isRequested) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    static func status(_ receiver: ReceiverController) -> String {
        if receiver.failure != nil { return "接收器出错，点“刷新”重试" }
        guard let state = receiver.state else { return receiver.isStarting ? "正在启动…" : "未运行" }
        if state.dryRun { return "演示模式，不会控制这台 Mac" }
        if state.inputStatus == "accessibility_required" { return "需要辅助功能权限" }
        if state.connected { return "iPhone 已连接" }
        return state.pairings.isEmpty ? "没有可用的网络" : "等待 iPhone 连接"
    }

    static func tone(_ receiver: ReceiverController) -> ReceiverMenuHeader.Tone {
        guard receiver.failure == nil, let state = receiver.state else { return receiver.failure == nil ? .idle : .warning }
        if state.inputStatus == "accessibility_required" && !state.dryRun || state.pairings.isEmpty { return .warning }
        return state.connected ? .live : .idle
    }

    /// A template glyph drawn in code: a phone outline with three dots, so the bundle needs no
    /// extra asset and the menu bar tints it for light, dark and highlighted states.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let body = NSBezierPath(roundedRect: NSRect(x: 5, y: 1.5, width: 8, height: 15), xRadius: 2, yRadius: 2)
            body.lineWidth = 1.4
            body.stroke()
            NSColor.black.setFill()
            for (x, y) in [(7.2, 10.5), (10.8, 10.5), (9.0, 7.0)] {
                NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct ReceiverMenuHeader: View {
    enum Tone { case live, idle, warning }
    let title: String
    let status: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 260, alignment: .leading)
    }

    private var color: Color {
        switch tone {
        case .live: Color(red: 152 / 255, green: 233 / 255, blue: 196 / 255)
        case .idle: Color.secondary
        case .warning: Color(red: 232 / 255, green: 192 / 255, blue: 138 / 255)
        }
    }
}
