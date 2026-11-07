import Foundation

extension GestureID {
    var title: String {
        switch self {
        case .singleTap: return String(localized: "单指轻点")
        case .leftDoubleTap: return String(localized: "左半区双击")
        case .rightDoubleTap: return String(localized: "右半区双击")
        case .twoFingerTap: return String(localized: "双指轻点")
        case .threeFingerTap: return String(localized: "三指轻点")
        case .longPress: return String(localized: "单指长按")
        case .doubleTapHold: return String(localized: "双击并按住")
        case .oneFingerMove: return String(localized: "单指滑动")
        case .twoFingerMove: return String(localized: "双指滑动")
        }
    }
}

extension GestureAction {
    var title: String { title(for: .computer) }

    func title(for target: GestureTarget) -> String {
        switch self {
        case .none: return String(localized: "不执行操作")
        case .leftClick: return target == .computer ? String(localized: "左键单击") : String(localized: "点击")
        case .rightClick: return String(localized: "右键单击")
        case .doubleLeftClick: return String(localized: "左键双击")
        case .doubleRightClick: return String(localized: "右键双击")
        case .drag: return String(localized: "拖动")
        case .movePointer: return String(localized: "移动光标")
        case .scroll: return String(localized: "滚动页面")
        case .confirm: return target == .computer ? String(localized: "回车") : String(localized: "确认")
        case .back: return target == .computer ? String(localized: "Esc 键") : String(localized: "返回")
        case .home: return target == .computer ? String(localized: "Home 键") : String(localized: "主页")
        case .toggleKeyboard: return String(localized: "显示或隐藏键盘")
        case .toggleDictation: return String(localized: "开始或停止听写")
        case .shortcutPanel: return String(localized: "快捷键面板")
        }
    }
}

extension GesturePreset {
    var title: String {
        switch self {
        case .sofatap: return "Sofatap"
        case .trackpad: return String(localized: "触控板习惯")
        case .pressMenu: return String(localized: "长按快捷操作")
        }
    }

    func detail(for target: GestureTarget) -> String {
        switch (self, target) {
        case (.sofatap, .computer): return String(localized: "左右分区双击，长按快捷键，双击按住拖动。")
        case (.trackpad, .computer): return String(localized: "双指轻点右键，双击打开。")
        case (.pressMenu, .computer): return String(localized: "长按右键，双击按住拖动。")
        case (.sofatap, .television): return String(localized: "轻点选择，滑动移动光标。")
        case (.trackpad, .television): return String(localized: "双指轻点确认，长按返回。")
        case (.pressMenu, .television): return String(localized: "长按返回，三指轻点主页。")
        }
    }
}

extension GestureTarget {
    var title: String {
        switch self {
        case .computer: return String(localized: "电脑")
        case .television: return String(localized: "电视")
        }
    }
}

extension DesktopShortcut {
    var title: String {
        switch self {
        case .space: return String(localized: "空格")
        case .enter: return String(localized: "回车")
        case .escape: return String(localized: "Esc 键")
        case .left: return String(localized: "左方向键")
        case .right: return String(localized: "右方向键")
        case .up: return String(localized: "上方向键")
        case .down: return String(localized: "下方向键")
        case .tab: return String(localized: "Tab 键")
        case .copy: return String(localized: "复制")
        case .paste: return String(localized: "粘贴")
        case .undo: return String(localized: "撤销")
        case .selectAll: return String(localized: "全选")
        case .switchWindow: return String(localized: "切换窗口")
        }
    }

    var symbol: String {
        switch self {
        case .space: return "space"
        case .enter: return "return"
        case .escape: return "escape"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .tab: return "arrow.right.to.line"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .undo: return "arrow.uturn.backward"
        case .selectAll: return "selection.pin.in.out"
        case .switchWindow: return "rectangle.on.rectangle"
        }
    }

    /// Key caps are shown as printed on the computer's keyboard, not translated.
    func keyCap(macOS: Bool) -> String {
        let command = macOS ? "⌘" : "Ctrl+"
        switch self {
        case .space: return "Space"
        case .enter: return macOS ? "Return" : "Enter"
        case .escape: return "Esc"
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        case .tab: return "Tab"
        case .copy: return command + "C"
        case .paste: return command + "V"
        case .undo: return command + "Z"
        case .selectAll: return command + "A"
        case .switchWindow: return macOS ? "⌘Tab" : "Alt+Tab"
        }
    }
}
