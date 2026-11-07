import Foundation

@main
struct GestureConfigurationTests {
    static func main() throws {
        var passed = 0
        func check(_ label: String, _ value: @autoclosure () -> Bool) {
            precondition(value(), label)
            passed += 1
        }
        func decode(_ json: String) throws -> GestureConfiguration {
            try JSONDecoder().decode(GestureConfiguration.self, from: Data(json.utf8))
        }
        func decodePreferences(_ json: String) throws -> GesturePreferences {
            try JSONDecoder().decode(GesturePreferences.self, from: Data(json.utf8))
        }

        let legacy = GestureConfiguration()
        check("new desktop installation retains left-half double left click", legacy.action(for: .leftDoubleTap) == .doubleLeftClick)
        check("new desktop installation retains right-half double right click", legacy.action(for: .rightDoubleTap) == .doubleRightClick)
        check("long press opens the desktop shortcut panel", legacy.action(for: .longPress) == .shortcutPanel)
        check("holding the second tap still starts a drag", legacy.action(for: .doubleTapHold) == .drag)
        check("new tap gestures do not surprise existing users", legacy.action(for: .twoFingerTap) == .none && legacy.action(for: .threeFingerTap) == .none)
        check("legacy pointer and natural scrolling defaults are preserved", legacy.action(for: .oneFingerMove) == .movePointer && legacy.action(for: .twoFingerMove) == .scroll && legacy.naturalScrolling)
        check("new desktop installation preserves existing pointer distance", legacy.pointerSpeed == 1.0)
        let tv = GestureConfiguration(target: .television)
        check("TV defaults never introduce synthetic double click or hold", tv.action(for: .leftDoubleTap) == .none && tv.action(for: .rightDoubleTap) == .none && tv.action(for: .longPress) == .none && tv.action(for: .doubleTapHold) == .none)
        check("TV defaults preserve supported pointer click and scroll", tv.action(for: .singleTap) == .leftClick && tv.action(for: .oneFingerMove) == .movePointer && tv.action(for: .twoFingerMove) == .scroll)
        let trackpad = GestureConfiguration(preset: .trackpad)
        check("trackpad double click works on both halves", trackpad.action(for: .leftDoubleTap) == .doubleLeftClick && trackpad.action(for: .rightDoubleTap) == .doubleLeftClick)
        check("trackpad two-finger tap opens context menu", trackpad.action(for: .twoFingerTap) == .rightClick)
        let pressMenu = GestureConfiguration(preset: .pressMenu)
        check("menu preset separates context menu from drag", pressMenu.action(for: .longPress) == .rightClick && pressMenu.action(for: .doubleTapHold) == .drag)
        check("menu preset provides confirm and keyboard shortcuts", pressMenu.action(for: .twoFingerTap) == .confirm && pressMenu.action(for: .threeFingerTap) == .toggleKeyboard)
        check("desktop picker excludes TV-only home action", GestureID.allCases.allSatisfy { !GestureConfiguration.allowedActions(for: $0, target: .computer).contains(.home) })
        let tvMenu = GestureConfiguration(preset: .pressMenu, target: .television)
        check("TV menu preset uses actual navigation actions", tvMenu.action(for: .longPress) == .back && tvMenu.action(for: .twoFingerTap) == .confirm && tvMenu.action(for: .threeFingerTap) == .home)

        var custom = legacy
        custom.setAction(.scroll, for: .oneFingerMove)
        custom.setAction(.movePointer, for: .twoFingerMove)
        custom.setAction(.toggleDictation, for: .threeFingerTap)
        custom.holdDuration = 0.75
        custom.doubleTapInterval = 0.42
        custom.pointerSpeed = 2.25
        custom.naturalScrolling = false
        check("user can swap continuous pointer and scroll gestures", custom.action(for: .oneFingerMove) == .scroll && custom.action(for: .twoFingerMove) == .movePointer)
        let roundTrip = try JSONDecoder().decode(GestureConfiguration.self, from: JSONEncoder().encode(custom))
        check("custom actions timing pointer speed and scroll direction survive serialization", roundTrip == custom)
        custom.setAction(.drag, for: .singleTap)
        check("single tap cannot leave a mouse button held", custom.action(for: .singleTap) == .none)
        custom.setAction(.leftClick, for: .twoFingerMove)
        check("continuous motion cannot become repeated click events", custom.action(for: .twoFingerMove) == .none)
        custom.bindings[.twoFingerMove] = .doubleRightClick
        check("even direct dictionary writes cannot execute unsafe action", custom.action(for: .twoFingerMove) == .none)
        custom.bindings.removeValue(forKey: .singleTap)
        check("removed binding disables gesture", custom.action(for: .singleTap) == .none)

        let targetFiltered = pressMenu.sanitized(for: .television)
        check("desktop mappings cannot leak right click drag or keyboard into TV", targetFiltered.action(for: .longPress) == .none && targetFiltered.action(for: .doubleTapHold) == .none && targetFiltered.action(for: .threeFingerTap) == .none)
        check("supported confirm survives target sanitation", targetFiltered.action(for: .twoFingerTap) == .confirm)
        check("computer pointer speed never carries over to a TV profile", roundTrip.sanitized(for: .television).pointerSpeed == 1.0)
        for preset in GesturePreset.allCases {
            let tvPreset = GestureConfiguration(preset: preset, target: .television)
            let forbidden: Set<GestureAction> = [.rightClick, .doubleLeftClick, .doubleRightClick, .drag, .toggleKeyboard, .toggleDictation]
            check("TV preset \(preset.rawValue) cannot advertise desktop-only actions", Set(tvPreset.bindings.values).isDisjoint(with: forbidden))
        }
        for gesture in [GestureID.oneFingerMove, .twoFingerMove] {
            check("movement actions are continuous for \(gesture.rawValue)", GestureConfiguration.allowedActions(for: gesture, target: .computer) == [.none, .movePointer, .scroll])
        }

        let trackpadHabit = GestureConfiguration(preset: .trackpad)
        check("trackpad preset keeps long press drag", trackpadHabit.action(for: .longPress) == .drag)
        var panelEverywhere = GestureConfiguration()
        panelEverywhere.setAction(.shortcutPanel, for: .threeFingerTap)
        check("shortcut panel can be bound to a computer tap", panelEverywhere.action(for: .threeFingerTap) == .shortcutPanel)
        panelEverywhere.setAction(.shortcutPanel, for: .oneFingerMove)
        check("shortcut panel is never a continuous motion action", panelEverywhere.action(for: .oneFingerMove) == .none)
        check("shortcut panel never leaks into TV gestures", GestureConfiguration(target: .television).sanitized(for: .television).action(for: .longPress) == .none &&
              !GestureConfiguration.allowedActions(for: .longPress, target: .television).contains(.shortcutPanel))
        let storedPanel = try decode(#"{"target":"television","bindings":{"longPress":"shortcutPanel"}}"#)
        check("persisted TV shortcut panel binding is disabled", storedPanel.action(for: .longPress) == .none)

        let macCopy = DesktopShortcut.copy.keystroke(macOS: true), winCopy = DesktopShortcut.copy.keystroke(macOS: false)
        check("copy uses Command on a Mac and Ctrl elsewhere", macCopy == .init(key: "c", modifiers: ["win"]) && winCopy == .init(key: "c", modifiers: ["ctrl"]))
        check("window switching uses Command+Tab and Alt+Tab", DesktopShortcut.switchWindow.keystroke(macOS: true) == .init(key: "tab", modifiers: ["win"]) &&
              DesktopShortcut.switchWindow.keystroke(macOS: false) == .init(key: "tab", modifiers: ["alt"]))
        let allowedKeys: Set<String> = ["enter", "tab", "escape", "backspace", "delete", "up", "down", "left", "right", "home", "end", "pageup", "pagedown", "space", "a", "c", "v", "x", "z"]
        let allowedModifiers: Set<String> = ["ctrl", "alt", "shift", "win"]
        check("every panel shortcut stays inside the receiver allow-list", DesktopShortcut.allCases.allSatisfy { shortcut in
            [true, false].allSatisfy { mac in
                let stroke = shortcut.keystroke(macOS: mac)
                return allowedKeys.contains(stroke.key) && Set(stroke.modifiers).isSubset(of: allowedModifiers) && stroke.modifiers.count == Set(stroke.modifiers).count
            }
        })

        var pick = ShortcutPanelSelection(count: 5, start: 1, x: 100, y: 100)
        check("hold released in place keeps the panel open", pick.release == .keepOpen)
        check("small slide does not change the item", !pick.move(x: 130, y: 104) && pick.index == 1 && pick.release == .keepOpen)
        check("one step right highlights the next item", pick.move(x: 150, y: 104) && pick.index == 2)
        check("lifting after choosing sends the highlighted item", pick.release == .send(2))
        check("selection clamps at the last item", pick.move(x: 900, y: 100) && pick.index == 4 && !pick.move(x: 1200, y: 100))
        check("selection clamps at the first item", pick.move(x: -900, y: 100) && pick.index == 0)
        _ = pick.move(x: -900, y: 210)
        check("vertical travel arms cancel", pick.cancelling && pick.release == .close)
        _ = pick.move(x: -900, y: 120)
        check("returning disarms cancel", !pick.cancelling && pick.release == .send(0))
        var back = ShortcutPanelSelection(count: 5, start: 2, x: 0, y: 0)
        _ = back.move(x: 60, y: 0); _ = back.move(x: 0, y: 0)
        check("returning to the starting item still counts as a choice", back.index == 2 && back.release == .send(2))
        var bad = ShortcutPanelSelection(count: 3, start: 9, x: 0, y: 0)
        check("out of range start is clamped and non-finite moves ignored", bad.index == 2 && !bad.move(x: .nan, y: 0) && bad.release == .keepOpen)

        let partlyFuture = try decode(#"{"target":"computer","bindings":{"singleTap":"futureAction","threeFingerTap":"toggleDictation","unknownGesture":"rightClick","twoFingerTap":17},"naturalScrolling":false}"#)
        check("unknown future action is disabled without discarding other settings", partlyFuture.action(for: .singleTap) == .none && partlyFuture.action(for: .threeFingerTap) == .toggleDictation && !partlyFuture.naturalScrolling)
        check("malformed individual action is disabled", partlyFuture.action(for: .twoFingerTap) == .none)
        let disabledRoundTrip = try JSONDecoder().decode(GestureConfiguration.self, from: JSONEncoder().encode(partlyFuture))
        check("unknown action stays explicitly disabled after a save and relaunch", disabledRoundTrip.bindings[.singleTap] == GestureAction.none && disabledRoundTrip.bindings[.twoFingerTap] == GestureAction.none)
        check("absent known binding inherits installation behavior", partlyFuture.action(for: .leftDoubleTap) == .doubleLeftClick)
        let invalidBindings = try decode(#"{"bindings":["singleTap","leftClick"]}"#)
        check("damaged bindings object disables input instead of inventing clicks", GestureID.allCases.allSatisfy { invalidBindings.action(for: $0) == .none })
        let invalidCombination = try decode(#"{"target":"television","bindings":{"longPress":"drag","singleTap":"rightClick","oneFingerMove":"confirm","twoFingerTap":"back"}}"#)
        check("persisted unsupported TV and continuous actions become disabled", invalidCombination.action(for: .longPress) == .none && invalidCombination.action(for: .singleTap) == .none && invalidCombination.action(for: .oneFingerMove) == .none)
        check("safe neighboring action remains usable", invalidCombination.action(for: .twoFingerTap) == .back)
        let extreme = try decode(#"{"holdDuration":-9999,"doubleTapInterval":9999}"#)
        check("finite timing values are clamped to usable bounds", extreme.holdDuration == 0.2 && extreme.doubleTapInterval == 0.5)
        let malformedTiming = try decode(#"{"holdDuration":"NaN","doubleTapInterval":null,"naturalScrolling":"false"}"#)
        check("malformed timing and direction use safe defaults", malformedTiming.holdDuration == 0.3 && malformedTiming.doubleTapInterval == 0.28 && malformedTiming.naturalScrolling)
        let legacySettings = try decode(#"{"holdDuration":0.75,"doubleTapInterval":0.42,"naturalScrolling":false,"bindings":{"twoFingerTap":"rightClick"}}"#)
        check("older settings gain default speed without losing existing choices", legacySettings.pointerSpeed == 1.0 && legacySettings.holdDuration == 0.75 && legacySettings.doubleTapInterval == 0.42 && !legacySettings.naturalScrolling && legacySettings.action(for: .twoFingerTap) == .rightClick)
        let slow = try decode(#"{"pointerSpeed":-100}"#)
        let fast = try decode(#"{"pointerSpeed":100}"#)
        check("out of range saved speeds remain usable", slow.pointerSpeed == 0.25 && fast.pointerSpeed == 3.0)
        for invalid in [#""NaN""#, "null", "true", "{}"] {
            let invalidSpeed = try decode("{\"pointerSpeed\":\(invalid)}")
            check("malformed saved speed falls back to previous behavior: \(invalid)", invalidSpeed.pointerSpeed == 1.0)
        }
        let tvSpeed = try decode(#"{"target":"television","pointerSpeed":3}"#)
        check("persisted TV speed cannot alter TV pointer input", tvSpeed.pointerSpeed == 1.0)
        var nonFinite = legacy
        nonFinite.holdDuration = .nan
        nonFinite.doubleTapInterval = .infinity
        let safeNonFinite = nonFinite.sanitized(for: .computer)
        check("nonfinite values do not leave a stuck gesture timer", safeNonFinite.holdDuration == 0.3 && safeNonFinite.doubleTapInterval == 0.28)
        check("save can sanitize runtime nonfinite values", (try? JSONEncoder().encode(nonFinite)) != nil)
        for speed in [Double.nan, .infinity, -.infinity] {
            nonFinite.pointerSpeed = speed
            let safe = nonFinite.sanitized(for: .computer)
            let saved = try JSONDecoder().decode(GestureConfiguration.self, from: JSONEncoder().encode(nonFinite))
            check("nonfinite runtime speed cannot disable or reverse pointer input", safe.pointerSpeed == 1.0 && saved.pointerSpeed == 1.0)
        }

        var preferences = GesturePreferences()
        preferences[.computer] = roundTrip
        let desktopBeforeTVEdit = preferences.computer
        preferences[.television] = tvMenu
        check("TV profile edit does not change desktop habits", preferences.computer == desktopBeforeTVEdit)
        let tvBeforeReset = preferences.television
        preferences.reset(preset: .trackpad, for: .computer)
        check("preset reset restores timing speed direction and gestures together", preferences.computer == trackpad && preferences.computer.pointerSpeed == 1.0)
        check("resetting desktop preset never resets TV", preferences.television == tvBeforeReset)
        preferences.reset(for: .television)
        check("reset to TV defaults does not copy desktop bindings", preferences.television == tv && preferences.computer == trackpad)
        let partialPreferences = try decodePreferences(#"{"schemaVersion":1,"computer":"damaged","television":{"target":"television","bindings":{"twoFingerTap":"home"}}}"#)
        check("corrupt desktop profile does not discard intact TV profile", partialPreferences.computer == legacy && partialPreferences.television.action(for: .twoFingerTap) == .home)
        let forgedTarget = try decodePreferences(#"{"schemaVersion":1,"television":{"target":"computer","pointerSpeed":2.5,"bindings":{"singleTap":"rightClick","threeFingerTap":"back"}}}"#)
        check("profile family is authoritative over persisted target field", forgedTarget.television.target == .television && forgedTarget.television.action(for: .singleTap) == .none && forgedTarget.television.action(for: .threeFingerTap) == .back)
        check("forged TV target cannot retain desktop pointer speed", forgedTarget.television.pointerSpeed == 1.0)
        let future = try decodePreferences(#"{"schemaVersion":999,"computer":{"bindings":{"singleTap":"home"}}}"#)
        check("unsupported persistence version does not misinterpret mappings", future == GesturePreferences())

        let suite = "sofatap.gesture-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("kept", forKey: "unrelatedPreference")
        check("missing settings load as existing user behavior", GesturePreferences.load(from: defaults) == GesturePreferences())
        defaults.set(Data(#"{"schemaVersion":1,"computer":{"holdDuration":0.65,"naturalScrolling":false},"television":{"target":"television","bindings":{"twoFingerTap":"home"}}}"#.utf8), forKey: GesturePreferences.storageKey)
        let upgraded = GesturePreferences.load(from: defaults)
        check("existing storage schema upgrades in place with unchanged control feel", upgraded.computer.pointerSpeed == 1.0 && upgraded.computer.holdDuration == 0.65 && !upgraded.computer.naturalScrolling && upgraded.television.action(for: .twoFingerTap) == .home)
        preferences.computer.pointerSpeed = 2.75
        check("profile save succeeds", preferences.save(to: defaults))
        check("cold reload preserves independent profiles", GesturePreferences.load(from: defaults) == preferences)
        check("cold reload retains desktop speed without changing TV speed", GesturePreferences.load(from: defaults).computer.pointerSpeed == 2.75 && GesturePreferences.load(from: defaults).television.pointerSpeed == 1.0)
        check("gesture save leaves other application settings alone", defaults.string(forKey: "unrelatedPreference") == "kept")
        let stored = defaults.data(forKey: GesturePreferences.storageKey)!
        let envelope = try JSONSerialization.jsonObject(with: stored) as! [String: Any]
        check("persistent envelope identifies its schema", envelope["schemaVersion"] as? Int == 1)
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: GesturePreferences.storageKey)
        check("corrupt saved JSON falls back without crashing", GesturePreferences.load(from: defaults) == GesturePreferences())
        check("loading corrupt bytes never silently destroys evidence", defaults.data(forKey: GesturePreferences.storageKey) == corrupt)
        let futureData = Data(#"{"schemaVersion":99,"futureSettings":{"retained":true}}"#.utf8)
        defaults.set(futureData, forKey: GesturePreferences.storageKey)
        check("future stored format falls back safely", GesturePreferences.load(from: defaults) == GesturePreferences())
        check("reading future format preserves bytes for newer app", defaults.data(forKey: GesturePreferences.storageKey) == futureData)
        print("PASS \(passed) gesture configuration, capability, persistence and corruption checks; no device, network or live input access")
    }
}
