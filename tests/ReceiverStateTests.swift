import Foundation

@main
struct ReceiverStateTests {
    static func main() {
        var passed = 0
        func check(_ name: String, _ value: Bool) {
            precondition(value, name); passed += 1
        }
        let old = ReceiverState.hello(["inputAvailable": true])!
        check("legacy Windows shortcut remains Control", old.inputAvailable && old.commandModifier == "ctrl")
        let locked = ReceiverState.hello(["inputAvailable": false])!
        check("legacy unavailable does not claim dry-run", !locked.dryRun && locked.status == .unavailable)
        let mac = ReceiverState.hello(["platform": "macos", "inputAvailable": false, "dryRun": false, "inputStatus": "accessibility_required"])!
        check("Mac authorization state", mac.status == .accessibility_required && !mac.inputAvailable && mac.commandModifier == "win")
        let ready = mac.updating(["inputAvailable": true, "dryRun": false, "inputStatus": "ready"])!
        check("permission can become available without reconnect", ready.platform == .macos && ready.inputAvailable)
        let revoked = ready.updating(["inputAvailable": false, "dryRun": false, "inputStatus": "desktop_unavailable"])!
        check("lock disables input", !revoked.inputAvailable && revoked.status == .desktop_unavailable)
        check("legacy ACK ignored", ready.updating(["ok": true]) == nil)
        check("incomplete heartbeat metadata ignored", ready.updating(["inputAvailable": true]) == nil)
        let inconsistent = ReceiverState.hello(["inputAvailable": true, "dryRun": true, "inputStatus": "ready"])!
        check("dry-run overrides claimed availability", !inconsistent.inputAvailable && inconsistent.status == .dry_run)
        let unknown = ReceiverState.hello(["inputAvailable": true, "inputStatus": "future_state", "platform": "future_os"])!
        check("unknown state fails closed", !unknown.inputAvailable && unknown.platform == .unknown)
        check("missing availability rejected", ReceiverState.hello([:]) == nil)
        check("legacy hello has no volume capability", !old.supportsSystemVolume)
        let volume = ReceiverState.hello(["inputAvailable": true, "systemVolume": ["version": 1]])!
        check("explicit volume v1 is recognized", volume.supportsSystemVolume)
        for version: Any in [true, 0, 2, 1.5, "1", NSNull()] {
            check("invalid or unknown volume version is disabled", !ReceiverState.hello(["inputAvailable": true, "systemVolume": ["version": version]])!.supportsSystemVolume)
        }
        let ping: [String: Any] = ["inputAvailable": true, "dryRun": false, "inputStatus": "ready"]
        check("legacy ping preserves negotiated volume support", volume.updating(ping)!.supportsSystemVolume)
        var revokedVolume = ping; revokedVolume["systemVolume"] = NSNull()
        check("explicit null revokes support on output removal", !volume.updating(revokedVolume)!.supportsSystemVolume)
        var availableVolume = ping; availableVolume["systemVolume"] = ["version": 1]
        check("output change can enable support without reconnect", old.updating(availableVolume)!.supportsSystemVolume)
        let focusBase: [String: Any] = ["platform": "macos", "inputAvailable": true, "dryRun": false, "inputStatus": "ready"]
        func focused(_ value: Any) -> ReceiverState {
            var frame = focusBase; frame["textFocus"] = value
            return ReceiverState.hello(frame)!
        }
        check("legacy receiver does not trigger keyboard", old.textFocus == .unknown && !old.reportsTextFocus)
        let editable = focused(["state": "editable", "revision": 4])
        check("editable field carries only state and revision", editable.textFocus == .editable && editable.focusRevision == 4 && editable.reportsTextFocus)
        let nextField = editable.updating(focusBase.merging(["textFocus": ["state": "editable", "revision": 5]]) { _, new in new })!
        check("moving between editable fields changes revision", nextField.textFocus == .editable && nextField.focusRevision == 5 && nextField != editable)
        check("password field is not editable hint", focused(["state": "protected", "revision": 6]).textFocus == .protected)
        for revision: Any in [-1, 0.5, true, "3", Double.infinity, Int64(Int32.max) + 1] {
            check("invalid focus revision ignored: \(revision)", focused(["state": "editable", "revision": revision]).textFocus == .unknown)
        }
        check("unknown focus kind ignored", focused(["state": "future", "revision": 1]).textFocus == .unknown)
        check("missing revision cannot auto-open", focused(["state": "editable"]).textFocus == .unknown)
        var unavailableFocus = focusBase
        unavailableFocus["inputAvailable"] = false
        unavailableFocus["inputStatus"] = "desktop_unavailable"
        unavailableFocus["textFocus"] = ["state": "editable", "revision": 4]
        check("unavailable receiver suppresses stale focus", ReceiverState.hello(unavailableFocus)!.textFocus == .unknown)
        unavailableFocus["inputAvailable"] = true; unavailableFocus["inputStatus"] = "ready"; unavailableFocus["dryRun"] = true
        check("dry run suppresses focus even if inconsistent", ReceiverState.hello(unavailableFocus)!.focusRevision == 0)
        for code in ["permission_required", "permission_pending", "permission_denied", "unsupported_session", "dependency_missing", "input_unavailable"] {
            let linux = ReceiverState.hello(["platform": "linux", "inputAvailable": true, "dryRun": false, "inputStatus": code])!
            check("Linux unavailable cannot enable input: \(code)", !linux.inputAvailable && linux.status.rawValue == code)
            check("Linux permission status preserves Control shortcuts", linux.commandModifier == "ctrl")
            check("Linux becomes ready after native authorization", linux.updating(["inputAvailable": true, "dryRun": false, "inputStatus": "ready"])!.inputAvailable)
        }
        print("PASS \(passed) receiver state checks (no device input)")
    }
}
