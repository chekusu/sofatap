import Foundation

@main
struct DeviceGuideContextTests {
    static func main() {
        var passed = 0
        func check(_ label: String, _ value: @autoclosure () -> Bool) {
            precondition(value(), label)
            passed += 1
        }

        let fullTV: Set<GestureAction> = [.movePointer, .leftClick, .scroll, .confirm, .back, .home]
        let sony = DeviceGuideContext(kind: .androidTV, deviceName: "Living room TV", connected: true, availableActions: fullTV)
        check("Android TV guide never includes desktop text or backspace instructions", !sony.showsTextInputHelp && sony.target == .television)
        check("device alias is carried into the guide", sony.deviceName == "Living room TV")
        check("reported TV actions can be displayed as available", fullTV.allSatisfy { sony.availability(of: $0) == .supported })
        check("a disabled binding is not described as a supported action", sony.availability(of: .none) == .disabled)

        let restricted = DeviceGuideContext(kind: .androidTV, deviceName: "TV", connected: true, availableActions: [.movePointer, .scroll, .back])
        check("no nodeClick capability means click is unavailable, not confirm", restricted.availability(of: .leftClick) == .unsupported && restricted.availability(of: .confirm) == .unsupported)
        check("capability checks distinguish Back from Home", restricted.availability(of: .back) == .supported && restricted.availability(of: .home) == .unsupported)
        let unknown = DeviceGuideContext(kind: .androidTV, deviceName: "TV", connected: true, availableActions: nil)
        check("missing capability report never advertises TV control", fullTV.allSatisfy { unknown.availability(of: $0) == .unknown })
        let disconnected = DeviceGuideContext(kind: .androidTV, deviceName: "TV", connected: false, availableActions: fullTV)
        check("disconnected session cannot use stale capabilities as current proof", fullTV.allSatisfy { disconnected.availability(of: $0) == .unknown })
        let untrusted = DeviceGuideContext(kind: .androidTV, deviceName: "TV", connected: true, availableActions: Set(GestureAction.allCases))
        check("desktop-only gestures remain unavailable even with overbroad reported capabilities", [.rightClick, .doubleLeftClick, .doubleRightClick, .drag, .toggleKeyboard, .toggleDictation, .shortcutPanel].allSatisfy { untrusted.availability(of: $0) == .unsupported })

        var customized = GestureConfiguration(preset: .pressMenu, target: .television)
        customized.setAction(.back, for: .singleTap)
        customized.setAction(.leftClick, for: .twoFingerTap)
        customized.setAction(.scroll, for: .oneFingerMove)
        customized.setAction(.movePointer, for: .twoFingerMove)
        check("guide preserves actual custom actions instead of teaching default tap and swipe behavior", sony.configuration(customized) == customized)
        let staleDesktop = GestureConfiguration(preset: .trackpad, target: .computer)
        check("a TV guide never teaches desktop double-clicks or dragging", sony.configuration(staleDesktop).action(for: .leftDoubleTap) == .none && sony.configuration(staleDesktop).action(for: .longPress) == .none)
        check("TV example distinguishes pointer movement from confirmation", sony.televisionActions.contains(.movePointer) && sony.televisionActions.contains(.confirm))

        let lg = DeviceGuideContext(kind: .webOS, deviceName: "LG TV", connected: true, availableActions: fullTV)
        check("LG help uses the TV profile and omits text instructions", lg.target == .television && !lg.showsTextInputHelp)
        for platform in ["windows", "macos", "linux"] {
            let context = DeviceGuideContext(kind: .computer(platform: platform), deviceName: "Computer", connected: true, availableActions: Set(GestureAction.allCases))
            check("\(platform) retains desktop guide and text help", context.target == .computer && context.showsTextInputHelp)
            check("\(platform) keeps desktop drag and double-click mappings", context.configuration(staleDesktop) == staleDesktop)
        }
        let nativeTV = DeviceGuideContext(kind: .androidTV, deviceName: "Bedroom TV", connected: true, availableActions: [],
                                          tvNavigation: true, tvNavigationReady: true, tvTextStatus: "ready")
        check("native TV guide distinguishes remote navigation from pointer gestures", nativeTV.televisionActions == [.confirm, .back, .home] && nativeTV.availability(of: .confirm) == .supported && nativeTV.availability(of: .leftClick) == .unsupported)
        check("TV text help uses its own instructions, never desktop live edit guidance", nativeTV.showsTVTextInputHelp && !nativeTV.showsTextInputHelp)
        let pendingNative = DeviceGuideContext(kind: .androidTV, deviceName: "TV", connected: true, availableActions: fullTV, tvNavigation: true)
        check("legacy focus capability never proves native remote pairing", pendingNative.availability(of: .confirm) == .unsupported)
        let fallback = DeviceGuideContext(kind: .computer(platform: nil), deviceName: "Select device", connected: false, availableActions: nil)
        check("unknown desktop platform remains a generic computer guide", fallback.kind == .computer && fallback.availability(of: .leftClick) == .unknown)
        print("PASS: \(passed) device-aware guide checks; no devices or input used.")
    }
}
