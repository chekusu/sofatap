import Foundation
import Combine

private enum StorageFailure: Error { case failed }
private final class MemoryStore: AndroidTVPairingStorage {
    var value: AndroidTVPairing?
    var reads = 0
    var writes = 0
    var deletes = 0
    var refuseWrite = false
    var refuseRead = false
    func library() throws -> DeviceLibrary<AndroidTVPairing> {
        if refuseRead { throw StorageFailure.failed }
        var library = DeviceLibrary<AndroidTVPairing>()
        if let value = read() { library.upsert(value) }
        return library
    }
    func read() -> AndroidTVPairing? { reads += 1; return value }
    func write(_ pairing: AndroidTVPairing) throws {
        if refuseWrite { throw StorageFailure.failed }
        writes += 1; value = pairing
    }
    func delete() throws { deletes += 1; value = nil }
}
@MainActor private final class Socket: AndroidTVSocket {
    var onText: ((String) -> Void)?
    var onFailure: ((AndroidTVSocketFailure) -> Void)?
    var pairing: AndroidTVPairing?
    var sent: [[String: Any]] = []
    var closed = 0
    var completions: [(Bool) -> Void] = []
    func open(_ pairing: AndroidTVPairing) { self.pairing = pairing }
    func send(_ text: String, completion: @escaping (Bool) -> Void) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
        completions.append(completion)
    }
    func close() { closed += 1 }
    func reply(_ object: [String: Any]) {
        onText?(String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
    }
    func ack(_ index: Int, ok: Bool = true, extra: [String: Any] = [:]) {
        var object: [String: Any] = ["type": "ack", "id": sent[index]["id"]!, "ok": ok]
        extra.forEach { object[$0.key] = $0.value }
        reply(object)
    }
}
@MainActor private final class Rig {
    let store = MemoryStore()
    var sockets: [Socket] = []
    var scheduled: [(delay: TimeInterval, retry: () -> Void)] = []
    lazy var controller: AndroidTVController = {
        let controller = AndroidTVController(storage: store, makeSocket: { [unowned self] in
            let socket = Socket(); sockets.append(socket); return socket
        })
        controller.testScheduleReconnect = { [unowned self] delay, retry in scheduled.append((delay, retry)) }
        return controller
    }()
    func pair() -> Socket { controller.pair(Self.link); return sockets.last! }
    func ready() -> Socket { let socket = pair(); socket.reply(Self.hello()); return socket }
    nonisolated static let token = String(repeating: "a", count: 43)
    nonisolated static let replacement = String(repeating: "b", count: 43)
    nonisolated static let pin = String(repeating: "a", count: 64)
    nonisolated static let link = "sofatap://tv?host=192.168.1.2&port=53319&token=\(token)&fingerprint=\(pin)"
    static func status(_ available: Bool = true) -> [String: Any] {
        ["inputAvailable": available, "inputStatus": available ? "ready" : "accessibility_required",
         "capabilities": ["overlayCursor": true, "nodeClick": true, "scroll": true, "back": true,
                          "home": true, "directionalFocus": true, "text": false, "rawMouse": false,
                          "rightClick": false, "drag": false]]
    }
    static func hello(token: String? = replacement, available: Bool = true) -> [String: Any] {
        var object = status(available)
        object["type"] = "hello"; object["version"] = 1; object["platform"] = "androidtv"; object["name"] = "Fixture TV"
        if let token { object["pairingToken"] = token }
        return object
    }
}
@main struct AndroidTVControllerTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ title: String, _ condition: Bool) { precondition(condition, title); count += 1 }
        func rejected(_ title: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(title) } catch { count += 1 }
        }
        func encoded(_ value: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
        let pairing = try AndroidTVPairing.parse(Rig.link)
        check("TV uses pinned secure endpoint", pairing.endpoint.absoluteString == "wss://192.168.1.2:53319/control")
        check("TV QR does not replace PC", (try? Pairing.parse(Rig.link)) == nil)
        for host in ["127.0.0.1", "8.8.8.8", "169.254.1.1", "tv.local", "192.168.01.2", "192.168.1.256", "172.32.0.1", "10.1.2", "::1"] {
            rejected("reject non-private or noncanonical endpoint") { _ = try AndroidTVPairing.parse(Rig.link.replacingOccurrences(of: "192.168.1.2", with: host)) }
        }
        for bad in [Rig.link + "&host=10.0.0.1", Rig.link + "&extra=1", Rig.link + "#fragment", Rig.link.replacingOccurrences(of: "//tv?", with: "//pair?"), Rig.link.replacingOccurrences(of: "53319", with: "65536"), Rig.link.replacingOccurrences(of: Rig.token, with: "short")] {
            rejected("malformed QR fails closed") { _ = try AndroidTVPairing.parse(bad) }
        }
        for mutation: (String, Any) in [("version", true), ("version", 1.5), ("version", 2), ("platform", "windows"), ("name", "bad\nname"), ("inputAvailable", 1), ("inputStatus", "unknown"), ("pairingToken", "short")] {
            var hello = Rig.hello(); hello[mutation.0] = mutation.1
            rejected("invalid hello fails closed") { _ = try AndroidTVProtocol.parse(encoded(hello)) }
        }
        var wrongCaps = Rig.hello(); var caps = wrongCaps["capabilities"] as! [String: Any]; caps["rawMouse"] = true; wrongCaps["capabilities"] = caps
        rejected("unexpected raw mouse capability not assumed compatible") { _ = try AndroidTVProtocol.parse(encoded(wrongCaps)) }
        rejected("binary-like JSON disallowed") { _ = try AndroidTVProtocol.parse("[]") }
        rejected("oversize response disallowed") { _ = try AndroidTVProtocol.parse(String(repeating: "x", count: 16385)) }
        rejected("nonfinite movement disallowed") { _ = try AndroidTVProtocol.encode(.move(dx: .nan, dy: 1), id: UUID().uuidString) }
        rejected("unbounded movement disallowed") { _ = try AndroidTVProtocol.encode(.scroll(dx: 0, dy: 501), id: UUID().uuidString) }
        check("click carries no raw button", try AndroidTVProtocol.encode(.click, id: UUID().uuidString).contains("click"))
        let editorID = UUID()
        func extendedStatus(navigation: String = "ready", text: String = "ready", editor: UUID? = editorID, accessible: Bool = false) -> [String: Any] {
            var status = Rig.status(accessible)
            var controls: [String: Any] = ["version": 1, "navigationStatus": navigation, "textStatus": text]
            if text == "ready", let editor { controls["editorEpoch"] = editor.uuidString }
            status["tvControls"] = controls
            return status
        }
        func extendedReady(_ rig: Rig, _ status: [String: Any]) -> Socket {
            let socket = rig.pair()
            var hello = Rig.hello()
            for (key, value) in status { hello[key] = value }
            socket.reply(hello)
            return socket
        }
        do {
            let status = extendedStatus()
            var hello = Rig.hello(); status.forEach { hello[$0.key] = $0.value }
            guard case .hello(_, let parsed, _) = try AndroidTVProtocol.parse(encoded(hello)) else { preconditionFailure() }
            check("native TV extension keeps legacy text false and reads separate editor epoch", parsed.tvControls?.editorEpoch == editorID && !parsed.available)
            for changes: [String: Any] in [["version": true], ["version": 2], ["navigationStatus": "invented"], ["textStatus": "invented"], ["editorEpoch": "bad"], ["textStatus": "sensitive"], ["extra": true]] {
                var bad = hello, controls = bad["tvControls"] as! [String: Any]
                changes.forEach { controls[$0.key] = $0.value }; bad["tvControls"] = controls
                rejected("malformed TV controls fail closed") { _ = try AndroidTVProtocol.parse(encoded(bad)) }
            }
            var missing = hello, controls = missing["tvControls"] as! [String: Any]
            controls.removeValue(forKey: "editorEpoch"); missing["tvControls"] = controls
            rejected("ready text requires an epoch") { _ = try AndroidTVProtocol.parse(encoded(missing)) }
            rejected("pairing code cannot contain other characters") { _ = try AndroidTVProtocol.encode(.remotePairCode("12345!"), id: UUID().uuidString) }
            rejected("text is byte bounded, not character bounded") { _ = try AndroidTVProtocol.encode(.textCommit(editorEpoch: editorID, text: String(repeating: "猫", count: 1366)), id: UUID().uuidString) }
            rejected("text NUL is refused") { _ = try AndroidTVProtocol.encode(.textCommit(editorEpoch: editorID, text: "a\0b"), id: UUID().uuidString) }
            check("multilingual insertion is encoded without shell or key emulation", try AndroidTVProtocol.encode(.textCommit(editorEpoch: editorID, text: "你好 こんにちは 👩🏽‍💻"), id: UUID().uuidString).contains("text_commit"))
        }
        do {
            let rig = Rig(), state = extendedStatus(), socket = extendedReady(rig, state)
            check("native navigation and text do not depend on accessibility", rig.controller.canNavigate && rig.controller.canInputText && rig.controller.canControl)
            check("direction accepted", rig.controller.remoteKey(.down))
            check("native key is never a legacy node click", socket.sent[0]["type"] as? String == "remote_key" && socket.sent[0]["key"] as? String == "down")
            check("press feedback is immediate before ACK", rig.controller.acceptedInputFeedback == 1)
            socket.ack(0, ok: false, extra: state.merging(["error": "remote_unavailable"], uniquingKeysWith: { _, new in new }))
            check("rejected discrete action has separate feedback", rig.controller.rejectedInputFeedback == 1 && rig.controller.inputFeedback != nil)
            rig.controller.textDraft.text = "第一段"
            check("first text sends", rig.controller.sendTextDraft())
            rig.controller.textDraft.text += "追加内容"
            socket.ack(1, extra: state)
            check("ACK removes only sent prefix and keeps appended dictation", rig.controller.textDraft.text == "追加内容" && rig.controller.canSendText)
            _ = rig.controller.sendTextDraft()
            check("second text is only unsent append", socket.sent[2]["text"] as? String == "追加内容")
            socket.ack(2, extra: state)
            check("acknowledged insertions are not retained for automatic resend", rig.controller.textDraft.text.isEmpty && !rig.controller.canSendText)
            check("backspace supported after draft is empty", rig.controller.textBackspace())
            socket.ack(3, extra: state)
            check("editor action has epoch", rig.controller.performTextAction() && socket.sent[4]["editorEpoch"] as? String == editorID.uuidString)
            socket.ack(4, extra: state)
            rig.controller.disconnect()
        }
        do {
            var hello = Rig.hello()
            hello["appShortcuts"] = ["schema": 1, "availableApps": ["youtube", "netflix"]]
            guard case .hello(_, let parsed, _) = try AndroidTVProtocol.parse(encoded(hello)) else { preconditionFailure() }
            check("app shortcuts remain separate from legacy controls", parsed.tvControls == nil && parsed.appShortcuts?.availableApps == [.youtube, .netflix])
            for bad: [String: Any] in [["schema": true, "availableApps": ["youtube"]],
                                      ["schema": 2, "availableApps": ["youtube"]],
                                      ["schema": 1, "availableApps": ["youtube", "youtube"]],
                                      ["schema": 1, "availableApps": ["https://example.com"]],
                                      ["schema": 1, "availableApps": [42]]] {
                hello["appShortcuts"] = bad
                rejected("malformed shortcuts cannot enable a launch") { _ = try AndroidTVProtocol.parse(encoded(hello)) }
            }
            hello["appShortcuts"] = ["schema": 1, "availableApps": ["youtube", "future_app"]]
            guard case .hello(_, let future, _) = try AndroidTVProtocol.parse(encoded(hello)) else { preconditionFailure() }
            check("future app identifiers are ignored rather than executed", future.appShortcuts?.availableApps == [.youtube])
            let launch = try AndroidTVProtocol.encode(.appLaunch(.netflix), id: UUID().uuidString)
            let object = try JSONSerialization.jsonObject(with: Data(launch.utf8)) as! [String: Any]
            check("launch carries only a fixed app identifier", object["type"] as? String == "app_launch" && object["app"] as? String == "netflix" && object.count == 3)
        }
        do {
            let rig = Rig()
            var state = extendedStatus(accessible: true)
            state["appShortcuts"] = ["schema": 1, "availableApps": ["youtube", "netflix"]]
            let socket = extendedReady(rig, state)
            check("advertised TV apps can launch", rig.controller.canLaunchApp(.youtube) && rig.controller.canLaunchApp(.netflix))
            check("launch accepted once", rig.controller.launchApp(.youtube) && socket.sent.count == 1 && socket.sent[0]["app"] as? String == "youtube")
            check("launch has immediate discrete feedback", rig.controller.acceptedInputFeedback == 1)
            socket.ack(0, extra: state)
            _ = rig.controller.remoteKey(.right)
            rig.controller.textDraft.text = "keep this on the phone"
            _ = rig.controller.sendTextDraft()
            _ = rig.controller.launchApp(.netflix)
            socket.ack(1, extra: state)
            check("app launch drops queued text for the old editor", socket.sent.count == 3 && socket.sent[2]["type"] as? String == "app_launch" && rig.controller.textDraft.text == "keep this on the phone" && !rig.controller.textCommandPending)
            state["appShortcuts"] = ["schema": 1, "availableApps": ["youtube"]]
            socket.ack(2, ok: false, extra: state.merging(["error": "app_not_installed"], uniquingKeysWith: { _, new in new }))
            check("uninstalled app disables after fresh ACK and shows useful feedback", !rig.controller.canLaunchApp(.netflix) && rig.controller.canLaunchApp(.youtube) && rig.controller.inputFeedback == String(localized: "电视上未安装此应用。"))
            rig.controller.pauseInput()
            check("modal pause blocks app launch", !rig.controller.launchApp(.youtube))
            rig.controller.disconnect()
        }
        do {
            let legacy = Rig(), legacySocket = legacy.ready()
            check("old receivers never receive app launch", !legacy.controller.launchApp(.youtube) && legacySocket.sent.isEmpty)
            legacy.controller.disconnect()
            let rig = Rig()
            var state = extendedStatus(accessible: false)
            state["appShortcuts"] = ["schema": 1, "availableApps": ["youtube"]]
            let socket = extendedReady(rig, state)
            check("installed shortcut still requires receiver control permission", !rig.controller.launchApp(.youtube) && socket.sent.isEmpty)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig()
            var state = extendedStatus(accessible: true)
            state["appShortcuts"] = ["schema": 1, "availableApps": ["youtube"]]
            let socket = extendedReady(rig, state)
            _ = rig.controller.launchApp(.youtube)
            socket.onFailure?(.transient)
            rig.scheduled.last!.retry()
            var hello = Rig.hello(token: nil); state.forEach { hello[$0.key] = $0.value }
            let resumed = rig.sockets.last!; resumed.reply(hello)
            check("unknown launch outcome never replays on reconnect", resumed.sent.isEmpty && rig.controller.canLaunchApp(.youtube))
            rig.controller.disconnect()
        }
        do {
            let rig = Rig()
            var state = extendedStatus(accessible: true)
            state["appShortcuts"] = ["schema": 1, "availableApps": ["youtube"]]
            let socket = extendedReady(rig, state)
            _ = rig.controller.launchApp(.youtube)
            socket.ack(0, extra: extendedStatus(accessible: true))
            check("launch ACK requires current shortcut capability", rig.controller.phase == .failed)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), state = extendedStatus(), socket = extendedReady(rig, state)
            var now = 100.0
            rig.controller.testInputTime = { now }
            _ = rig.controller.remoteKey(.right)
            _ = rig.controller.remoteKey(.down)
            _ = rig.controller.remoteKey(.confirm)
            now += 0.6
            socket.ack(0, extra: state)
            check("expired direction also cancels dependent OK instead of opening old focus", socket.sent.count == 1 && rig.controller.rejectedInputFeedback == 1)
            check("a later OK cannot revive the interrupted selection", !rig.controller.remoteKey(.confirm) && socket.sent.count == 1)
            _ = rig.controller.remoteKey(.left)
            _ = rig.controller.remoteKey(.confirm)
            socket.ack(1, extra: state)
            check("new deliberate navigation restores confirmation", socket.sent.count == 3 && socket.sent[1]["key"] as? String == "left" && socket.sent[2]["key"] as? String == "confirm")
            rig.controller.disconnect()
        }
        for navigation in [AndroidTVKey.back, .home] {
            let rig = Rig(), state = extendedStatus(), socket = extendedReady(rig, state)
            var now = 100.0
            rig.controller.testInputTime = { now }
            _ = rig.controller.remoteKey(.right)
            _ = rig.controller.remoteKey(.down)
            _ = rig.controller.remoteKey(.confirm)
            _ = rig.controller.remoteKey(navigation)
            now += 0.6
            socket.ack(0, extra: state)
            check("Back and Home survive an expired direction and cancelled OK", socket.sent.count == 2 && socket.sent[1]["key"] as? String == navigation.rawValue)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), state = extendedStatus(), socket = extendedReady(rig, state)
            var now = 100.0
            rig.controller.testInputTime = { now }
            _ = rig.controller.remoteKey(.right)
            _ = rig.controller.remoteKey(.down)
            now += 0.6
            check("OK added after queued direction expires is rejected immediately", !rig.controller.remoteKey(.confirm))
            socket.ack(0, extra: state)
            check("rejected late OK never reaches the wire", socket.sent.count == 1 && rig.controller.phase == .ready)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), state = extendedStatus(), socket = extendedReady(rig, state)
            rig.controller.textDraft.text = "potentially sent"
            _ = rig.controller.sendTextDraft()
            socket.onFailure?(.transient)
            check("lost text ACK is uncertain and retains local text", rig.controller.textDraft.delivery == .uncertain && rig.controller.textDraft.text == "potentially sent")
            rig.scheduled.last!.retry()
            let resumed = rig.sockets.last!
            var hello = Rig.hello(token: nil); state.forEach { hello[$0.key] = $0.value }; resumed.reply(hello)
            check("reconnect never repeats uncertain insertion", resumed.sent.isEmpty && !rig.controller.canSendText)
            rig.controller.textDraft.resolve()
            check("only explicit local acknowledgement permits another send", rig.controller.canSendText)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), state = extendedStatus(), socket = extendedReady(rig, state)
            _ = rig.controller.remoteKey(.right)
            rig.controller.textDraft.text = "unsent target-bound text"
            _ = rig.controller.sendTextDraft()
            socket.ack(0, extra: extendedStatus(editor: UUID()))
            check("a queued insertion cannot cross editor epochs", socket.sent.count == 1 && !rig.controller.textCommandPending && rig.controller.textDraft.text == "unsent target-bound text")
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), state = extendedStatus(navigation: "pairing_required", text: "ime_required"), socket = extendedReady(rig, state)
            rig.controller.pauseInput()
            check("pairing is explicit and remains available while input is paused for its sheet", rig.controller.startRemotePairing())
            check("pairing cannot start twice concurrently", !rig.controller.startRemotePairing())
            socket.ack(0, extra: extendedStatus(navigation: "pairing", text: "ime_required"))
            check("valid code accepted while sheet pauses gestures", rig.controller.submitRemotePairingCode("Ab12cD"))
            check("code sent in canonical hexadecimal form", socket.sent[1]["code"] as? String == "AB12CD")
            socket.ack(1, extra: extendedStatus(navigation: "ready", text: "ime_required"))
            rig.controller.resumeInput()
            check("paired remote works without enabling text or accessibility", rig.controller.canNavigate && !rig.controller.canInputText)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            check("legacy receiver cannot receive extended commands", !rig.controller.remoteKey(.confirm) && !rig.controller.startRemotePairing())
            rig.controller.textDraft.text = "local only"
            check("legacy receiver cannot receive draft", !rig.controller.sendTextDraft() && socket.sent.isEmpty)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), state = extendedStatus(), socket = extendedReady(rig, state)
            _ = rig.controller.remoteKey(.down)
            rig.controller.textDraft.text = "never sent"
            _ = rig.controller.sendTextDraft()
            _ = rig.controller.remoteKey(.back)
            socket.ack(0, extra: state)
            check("Back discards only queued text before leaving a page", socket.sent.count == 2 && socket.sent[1]["key"] as? String == "back" && rig.controller.textDraft.text == "never sent" && rig.controller.textDraft.delivery != .uncertain)
            socket.ack(1, extra: state)
            _ = rig.controller.textBackspace()
            socket.onFailure?(.transient)
            check("unacknowledged backspace is uncertain too", rig.controller.textDraft.delivery == .uncertain)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), state = extendedStatus(), socket = extendedReady(rig, state)
            rig.controller.textDraft.text = "awaiting ack"
            _ = rig.controller.sendTextDraft()
            socket.ack(0)
            check("extended text ACK must include fresh control status", rig.controller.phase == .failed && rig.controller.textDraft.delivery == .uncertain)
            rig.controller.disconnect()
        }
        for textStatus in ["ime_required", "no_editor", "sensitive"] {
            let rig = Rig(), socket = extendedReady(rig, extendedStatus(text: textStatus))
            rig.controller.textDraft.text = "not an editor"
            check("text never sends while IME absent, no field or sensitive", !rig.controller.sendTextDraft() && !rig.controller.textBackspace() && !rig.controller.performTextAction() && socket.sent.isEmpty)
            rig.controller.disconnect()
        }
        do {
            var draft = AndroidTVTextDraft(); draft.text = "old"
            _ = draft.begin(); draft.text = "edited before ACK"; draft.accepted()
            check("editing submitted prefix cannot guess duplicate-free resend", draft.delivery == .uncertain && draft.text == "edited before ACK")
            draft.clear(); draft.text = "new"; _ = draft.begin(); draft.interrupted(wasSent: false)
            check("cancelled unsent queue remains safely editable", draft.delivery == .ready && draft.text == "new")
            var gesture = AndroidTVNavigationGesture()
            check("small movement does not navigate", gesture.move(x: 8, y: 3, time: 1) == nil)
            check("horizontal swipe emits remote right", gesture.move(x: 29, y: 3, time: 1.01) == .right)
            check("fast motion is rate limited", gesture.move(x: 70, y: 3, time: 1.03) == nil)
            check("later movement emits one step without replaying backlog", gesture.move(x: 130, y: 3, time: 1.14) == .right)
            gesture.reset()
            check("reset prevents prior movement leaking to next gesture", gesture.move(x: 0, y: -29, time: 2) == .up)
            check("invalid movement emits no key", gesture.move(x: .nan, y: 50, time: 3) == nil)
            var contact = AndroidTVNavigationContact()
            contact.begin(x: 200, y: 300, time: 1)
            check("finger contact uses local start position", contact.move(x: 230, y: 300, time: 1.04) == .right)
            check("a navigation swipe cannot end as OK", contact.end(x: 230, y: 300, time: 1.1) == nil)
            contact.begin(x: 200, y: 300, time: 2)
            check("a short single contact confirms", contact.end(x: 202, y: 302, time: 2.1) == .confirm)
            check("release never confirms twice", contact.end(x: 202, y: 302, time: 2.2) == nil)
            contact.begin(x: 200, y: 300, time: 3)
            check("small swipe without a direction does not misfire OK", contact.end(x: 220, y: 300, time: 3.1) == nil)
            contact.begin(x: 200, y: 300, time: 4)
            check("stationary long hold does not confirm", contact.end(x: 200, y: 300, time: 5) == nil)
            contact.begin(x: 200, y: 300, time: 6); contact.cancel()
            check("cancelled or multi-touch contact cannot send delayed direction", contact.move(x: 260, y: 300, time: 6.1) == nil)
            check("cancelled or multi-touch contact cannot send OK on release", contact.end(x: 200, y: 300, time: 6.2) == nil)
            contact.begin(x: 200, y: 300, time: 7)
            check("upward finger swipe maps to remote up", contact.move(x: 200, y: 270, time: 7.1) == .up)
            _ = contact.end(x: 200, y: 270, time: 7.2)
            contact.begin(x: 200, y: 300, time: 8)
            check("invalid final contact is never a confirmation", contact.end(x: .nan, y: 300, time: 8.1) == nil)
            contact.begin(x: 200, y: 300, time: 9)
            check("fast swipe without intermediate samples still navigates once", contact.end(x: 160, y: 300, time: 9.1) == .left)
            contact.begin(x: 200, y: 300, time: 10)
            // An auxiliary button cancels contact synchronously before issuing
            // Back/Home, even when its touch belongs to a different native view.
            contact.cancel()
            check("cross-view Back/Home cancels a resting finger before its release", contact.end(x: 200, y: 300, time: 10.15) == nil)



        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.scroll(dy: -12)
            check("negative wheel delta emits Android document-down action", socket.sent.count == 1 && socket.sent[0]["type"] as? String == "scroll" && socket.sent[0]["dy"] as? Double == 12)
            socket.ack(0)
            rig.controller.scroll(dy: 9)
            check("positive wheel delta emits Android document-up action", socket.sent.count == 2 && socket.sent[1]["dy"] as? Double == -9)
            socket.ack(1)
            rig.controller.scroll(dy: .nan)
            check("direction normalization still rejects nonfinite input", socket.sent.count == 2)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.pair()
            check("QR bootstrap never persisted", rig.store.writes == 0 && rig.controller.saved == nil)
            check("connecting cannot control", !rig.controller.canControl)
            socket.reply(Rig.hello())
            check("valid hello rotates secret", rig.controller.saved?.token == Rig.replacement && rig.store.value?.token != Rig.token && rig.store.writes == 1)
            check("ready only after hello", rig.controller.canControl)
            rig.controller.move(dx: 4, dy: 2); rig.controller.click(); rig.controller.move(dx: 3, dy: 1)
            check("one ACK outstanding", socket.sent.count == 1)
            socket.ack(0)
            check("movement precedes click", socket.sent[1]["type"] as? String == "click")
            socket.ack(1)
            check("movement after click retained", socket.sent[2]["type"] as? String == "move")
            rig.controller.pauseInput(); rig.controller.click(); socket.ack(2)
            check("paused input cleared", socket.sent.count == 3)
            rig.controller.resumeInput(); rig.controller.key(.back)
            check("explicit back key", socket.sent[3]["key"] as? String == "back")
            rig.controller.click(); socket.ack(3, ok: false)
            check("rejected action discards queue", socket.sent.count == 4)
            rig.controller.disconnect(); rig.controller.reconnect()
            let resumed = rig.sockets.last!
            check("manual resume uses returned credential", resumed.pairing?.token == Rig.replacement)
            resumed.reply(Rig.hello(token: nil))
            check("resume accepts no replacement", rig.controller.canControl && rig.store.writes == 1)
            socket.onFailure?(.transient); socket.reply(Rig.hello())
            check("old callbacks isolated", rig.controller.canControl && rig.store.writes == 1)
            check("no replay after reconnect", resumed.sent.isEmpty)
            rig.controller.forget()
            check("forget removes credential", rig.store.deletes == 1 && rig.controller.saved == nil)
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.scroll(dy: -12)
            for _ in 0..<120 { rig.controller.scroll(dy: -12) }
            check("fast scroll while an ACK is delayed keeps the connection", rig.controller.canControl && socket.sent.count == 1)
            socket.ack(0)
            check("fast scroll coalesces to one bounded pending wheel action", socket.sent.count == 2 && socket.sent[1]["type"] as? String == "scroll" && socket.sent[1]["dy"] as? Double == 500)
            socket.ack(1)
            check("scroll burst does not leave a long action backlog", socket.sent.count == 2)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.move(dx: 1, dy: 1)
            rig.controller.scroll(dy: -20); rig.controller.scroll(dy: -30)
            rig.controller.click()
            rig.controller.scroll(dy: 7); rig.controller.scroll(dy: 9)
            socket.ack(0)
            check("scroll before a click preserves direction and magnitude", socket.sent[1]["type"] as? String == "scroll" && socket.sent[1]["dy"] as? Double == 50)
            socket.ack(1)
            check("coalescing cannot cross a click boundary", socket.sent[2]["type"] as? String == "click")
            socket.ack(2)
            check("scroll after a click stays ordered and separate", socket.sent[3]["type"] as? String == "scroll" && socket.sent[3]["dy"] as? Double == -16)
            socket.ack(3)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.click()
            socket.ack(0, ok: false, extra: ["error": "no_accessible_target"])
            let feedback = rig.controller.inputFeedback
            check("rejected pointer click exposes an actionable message", feedback == String(localized: "此位置无法点击。请移动到可点击控件，或使用确认高亮项。") && rig.controller.canControl)
            rig.controller.move(dx: 1, dy: 1); socket.ack(1)
            check("pointer motion does not erase click feedback", rig.controller.inputFeedback == feedback)
            rig.controller.scroll(dy: -10); socket.ack(2)
            check("successful scrolling does not erase click feedback", rig.controller.inputFeedback == feedback)
            rig.controller.key(.confirm); socket.ack(3)
            check("successful deliberate confirmation clears input feedback", rig.controller.inputFeedback == nil)
            rig.controller.scroll(dy: -10); socket.ack(4, ok: false, extra: ["error": "no_accessible_target"])
            check("rejected scroll does not suggest clicking", rig.controller.inputFeedback == String(localized: "此区域无法滚动。请把光标移到可滚动区域。"))
            rig.controller.click(); socket.ack(5, ok: false, extra: ["error": "arbitrary_server_message"])
            check("unknown rejection never displays raw server text", rig.controller.inputFeedback == String(localized: "电视未接受这次操作。请查看电视；此应用或控件可能不支持遥控。"))
            rig.controller.disconnect()
            check("disconnect removes feedback for the old device", rig.controller.inputFeedback == nil)
        }
        for navigation in [AndroidTVKey.back, .home] {
            let rig = Rig(), socket = rig.ready()
            rig.controller.scroll(dy: -12)
            for _ in 0..<120 { rig.controller.scroll(dy: -12) }
            rig.controller.click()
            rig.controller.key(navigation)
            check("navigation waits for the single in-flight action", rig.controller.canControl && socket.sent.count == 1)
            socket.ack(0)
            check("a scroll burst stays coalesced ahead of deliberate actions", socket.sent.count == 2 && socket.sent[1]["type"] as? String == "scroll")
            socket.ack(1)
            check("navigation cannot silently discard an explicit queued click", socket.sent.count == 3 && socket.sent[2]["type"] as? String == "click")
            socket.ack(2)
            check("navigation follows earlier accepted input in FIFO order", socket.sent.count == 4 && socket.sent[3]["key"] as? String == navigation.rawValue)
            socket.ack(3)
            check("coalesced burst has no remaining backlog", socket.sent.count == 4)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.move(dx: 12, dy: -3)
            rig.controller.click(); rig.controller.scroll(dy: -9)
            rig.controller.key(.back); rig.controller.key(.home)
            for index in 0..<5 { socket.ack(index) }
            check("legacy move-click-scroll-Back-Home preserves every accepted action", socket.sent.map { $0["type"] as? String } == ["move", "click", "scroll", "key", "key"] && socket.sent[3]["key"] as? String == "back" && socket.sent[4]["key"] as? String == "home")
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), state = extendedStatus(), socket = extendedReady(rig, state)
            _ = rig.controller.remoteKey(.right); _ = rig.controller.remoteKey(.confirm)
            _ = rig.controller.remoteKey(.back); _ = rig.controller.remoteKey(.home)
            for index in 0..<4 { socket.ack(index, extra: state) }
            check("native Home never erases queued confirmation or Back", socket.sent.compactMap { $0["key"] as? String } == ["right", "confirm", "back", "home"])
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.scroll(dy: -12)
            rig.controller.key(.back)
            socket.ack(0, ok: false, extra: ["error": "no_accessible_target"])
            check("a rejected scroll cannot swallow an explicit queued Back", socket.sent.count == 2 && socket.sent[1]["key"] as? String == "back" && rig.controller.canControl)
            socket.ack(1)
            check("accepted Back clears the failed-scroll message", rig.controller.inputFeedback == nil)
            rig.controller.disconnect()
        }
        for navigation in [AndroidTVKey.back, .home] {
            for accepted in [true, false] {
                let rig = Rig(), socket = rig.ready()
                rig.controller.scroll(dy: -12)
                rig.controller.key(navigation)
                try await Task.sleep(nanoseconds: 600_000_000)
                // New gestures also run queue expiry before the delayed ACK.
                rig.controller.move(dx: 1, dy: 0)
                socket.ack(0, ok: accepted, extra: accepted ? [:] : ["error": "action_rejected"])
                check("navigation survives a slow scroll ACK and gesture expiry", socket.sent.count == 2 && socket.sent[1]["key"] as? String == navigation.rawValue)
                rig.controller.disconnect()
            }
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.scroll(dy: -12); rig.controller.key(.back)
            socket.onFailure?(.transient)
            rig.controller.reconnect(); let resumed = rig.sockets.last!
            resumed.reply(Rig.hello(token: nil))
            check("navigation is never replayed after a connection failure", resumed.sent.isEmpty)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.pair()
            socket.reply(Rig.hello(token: nil))
            check("bootstrap requires replacement", rig.controller.phase == .failed && rig.store.writes == 0)
        }
        do {
            let rig = Rig(); rig.store.refuseWrite = true
            let socket = rig.pair(); socket.reply(Rig.hello())
            check("failed secure save never enables control", rig.controller.phase == .failed && !rig.controller.canControl)
        }
        do {
            let rig = Rig(), socket = rig.pair(); socket.reply(Rig.hello(available: false))
            check("paired without permissions remains disabled", rig.controller.phase == .ready && !rig.controller.canControl && rig.store.writes == 1)
            rig.controller.click(); check("no input while permissions missing", socket.sent.isEmpty)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.click(); socket.ack(0, extra: Rig.status(false))
            check("revoked permission disables immediately", !rig.controller.canControl)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.click()
            socket.reply(["type": "ack", "id": UUID().uuidString, "ok": true])
            check("wrong ACK cannot acknowledge input", rig.controller.phase == .failed)
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.click(); rig.controller.click(); socket.onFailure?(.transient)
            check("disconnect clears queued actions", rig.controller.phase == .failed && socket.sent.count == 1)
            rig.controller.reconnect(); let resumed = rig.sockets.last!; resumed.reply(Rig.hello(token: nil))
            check("uncertain clicks never retried", resumed.sent.isEmpty)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.click()
            for _ in 0..<25 { rig.controller.click() }
            check("bounded action queue fails closed", rig.controller.phase == .failed && socket.sent.count == 1)
        }
        do {
            let rig = Rig(), socket = rig.ready()
            rig.controller.click(); rig.controller.click()
            try await Task.sleep(nanoseconds: 600_000_000)
            socket.ack(0)
            check("stale queued clicks expire rather than replaying late", socket.sent.count == 1)
            rig.controller.disconnect()
        }
        do {
            let timed = Rig(), timedSocket = timed.ready()
            timed.controller.click()
            let heartbeat = Rig(), heartbeatSocket = heartbeat.ready()
            try await Task.sleep(nanoseconds: 3_250_000_000)
            check("unacknowledged action expires without retry", timed.controller.phase == .failed && timedSocket.sent.count == 1)
            check("heartbeat requests fresh capability state", heartbeatSocket.sent.count == 1 && heartbeatSocket.sent[0]["type"] as? String == "ping")
            heartbeatSocket.ack(0, extra: Rig.status(false))
            check("heartbeat detects permission revocation", !heartbeat.controller.canControl)
            heartbeat.controller.disconnect()
        }
        do {
            let rig = Rig(), first = rig.ready()
            rig.controller.click(); rig.controller.click()
            first.onFailure?(.transient)
            check("lost connection schedules first retry after one second", rig.scheduled.map(\.delay) == [1] && rig.controller.phase == .failed)
            let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30, 30]
            for index in delays.indices {
                check("automatic retry has bounded exponential backoff", rig.scheduled[index].delay == delays[index])
                rig.scheduled[index].retry()
                let socket = rig.sockets.last!
                check("retry authenticates only with persisted credential", socket.pairing?.token == Rig.replacement && socket.pairing?.fingerprint == Rig.pin)
                check("retry starts with no pending or queued input", socket.sent.isEmpty)
                if index + 1 < delays.count { socket.onFailure?(.transient) }
            }
            let recovered = rig.sockets.last!
            recovered.reply(Rig.hello(token: nil))
            check("recovery preserves one saved device and credential", rig.controller.canControl && rig.controller.savedDevices.count == 1 && rig.store.writes == 1)
            first.onFailure?(.permanent); first.completions.first?(false)
            check("old callbacks cannot terminate recovered transport", rig.controller.canControl)
            recovered.onFailure?(.transient)
            check("successful authenticated hello resets retry delay", rig.scheduled.last?.delay == 1)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            socket.onFailure?(.transient)
            let stale = rig.scheduled[0].retry
            rig.controller.disconnect(); stale(); rig.controller.becameActive()
            check("manual disconnect cancels pending and foreground retries", rig.sockets.count == 1 && rig.controller.phase == .idle)
            rig.controller.reconnect()
            check("explicit reconnect resumes manually paused target", rig.sockets.count == 2)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            socket.onFailure?(.transient)
            let stale = rig.scheduled[0].retry
            rig.controller.becameInactive(); stale(); rig.controller.reconnect()
            check("background cancels timers and rejects explicit connection attempts", rig.sockets.count == 1 && rig.controller.phase == .idle)
            rig.controller.becameActive()
            let resumed = rig.sockets.last!
            resumed.reply(Rig.hello(token: nil))
            check("returning foreground resumes saved target without a scan", rig.sockets.count == 2 && rig.controller.canControl && resumed.sent.isEmpty)
            rig.controller.pauseInput(); resumed.onFailure?(.transient)
            rig.scheduled.last!.retry(); rig.sockets.last!.reply(Rig.hello(token: nil))
            check("reconnect while a sheet is open cannot unpause input", !rig.controller.canControl)
            rig.controller.resumeInput()
            check("dismissed sheet can resume authenticated current target", rig.controller.canControl)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig(), socket = rig.ready()
            socket.onFailure?(.transient)
            let stale = rig.scheduled[0].retry
            rig.controller.setTargetSelected(false); stale(); rig.controller.becameActive(); rig.controller.reconnect()
            check("computer or webOS selection disables Android retry", rig.sockets.count == 1)
            rig.controller.becameInactive(); rig.controller.setTargetSelected(true)
            check("changing selected adapter does not invent foreground activation", rig.sockets.count == 1)
            rig.controller.becameActive()
            check("active selected adapter can reconnect only its saved TV", rig.sockets.count == 2 && rig.sockets.last?.pairing?.token == Rig.replacement)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig()
            rig.store.value = pairing.replacingToken(Rig.replacement)
            rig.controller.becameActive()
            check("app relaunch restores selected saved TV without scanning", rig.sockets.count == 1 && rig.sockets[0].pairing?.token == Rig.replacement)
            rig.controller.becameActive()
            check("repeated active notification cannot duplicate connection", rig.sockets.count == 1)
            rig.sockets[0].onFailure?(.permanent)
            rig.controller.becameInactive(); rig.controller.becameActive()
            check("authentication or TLS rejection stops all automatic attempts", rig.scheduled.isEmpty && rig.sockets.count == 1)
            rig.controller.reconnect()
            check("user can explicitly retry after permanent rejection", rig.sockets.count == 2)
            rig.controller.disconnect()
        }
        do {
            let rig = Rig()
            rig.store.value = pairing.replacingToken(Rig.replacement)
            let bootstrap = rig.pair()
            bootstrap.onFailure?(.transient)
            rig.controller.becameActive()
            check("uncertain QR bootstrap never retries QR or falls back to old saved TV", rig.scheduled.isEmpty && rig.sockets.count == 1)
        }
        do {
            let rig = Rig()
            rig.store.value = pairing.replacingToken(Rig.replacement)
            _ = rig.pair()
            rig.controller.becameInactive(); rig.controller.becameActive()
            check("backgrounding an unfinished scan cannot reconnect a previous TV", rig.sockets.count == 1 && rig.scheduled.isEmpty)
        }
        do {
            let rig = Rig(), socket = rig.ready()
            socket.reply(["type": "hello", "version": 100])
            rig.controller.becameActive()
            check("malformed response cannot trigger automatic reconnect loop", rig.scheduled.isEmpty && rig.sockets.count == 1 && rig.controller.phase == .failed)
        }
        do {
            let rig = Rig(), socket = rig.ready()
            socket.onFailure?(.transient)
            let stale = rig.scheduled[0].retry
            rig.controller.removeDevice(rig.controller.selectedDeviceID!)
            stale(); rig.controller.becameActive()
            check("forgetting current TV cancels reconnection and retains no selected fallback", rig.sockets.count == 1 && rig.controller.saved == nil)
        }
        do {
            let rig = Rig(), socket = rig.ready()
            socket.onFailure?(.transient)
            let stale = rig.scheduled[0].retry
            rig.store.refuseRead = true
            rig.controller.becameActive(); stale()
            check("unreadable saved selection prevents cached credential retry", rig.sockets.count == 1)
            rig.store.refuseRead = false
            rig.controller.becameActive()
            check("restored secure storage can reconnect on next foreground activation", rig.sockets.count == 2)
            rig.controller.disconnect()
        }
        do {
            func classify(_ error: Error = URLError(.networkConnectionLost), diagnostic: String? = nil,
                          status: Int? = nil, close: URLSessionWebSocketTask.CloseCode = .invalid,
                          received: Bool = false) -> AndroidTVSocketFailure {
                AndroidTVNetworkSocket.classify(error, diagnostic: diagnostic, status: status, closeCode: close, receivedText: received)
            }
            for code: URLError.Code in [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet] {
                check("network interruption is retryable", classify(URLError(code)) == .transient)
            }
            for status in [408, 409, 429, 500, 503] {
                check("temporary receiver unavailability is retryable", classify(status: status) == .transient)
            }
            for status in [301, 302, 400, 401, 403, 404] {
                check("redirect or credential rejection is permanent", classify(status: status) == .permanent)
            }
            for code: URLError.Code in [.serverCertificateUntrusted, .secureConnectionFailed, .userAuthenticationRequired] {
                check("TLS and authentication errors are permanent", classify(URLError(code)) == .permanent)
            }
            check("pin rejection dominates even apparently temporary status", classify(diagnostic: "TLS_PIN", status: 503) == .permanent)
            for close: URLSessionWebSocketTask.CloseCode in [.protocolError, .policyViolation, .messageTooBig, .unsupportedData] {
                check("protocol close is permanent even after hello", classify(close: close, received: true) == .permanent)
            }
            check("clean receiver shutdown is retryable after hello", classify(URLError(.cancelled), close: .goingAway, received: true) == .transient)
            check("unexpected errors fail closed", classify(NSError(domain: "unexpected", code: 1)) == .permanent)
        }
        do {
            let store = MemoryStore(); var created = 0
            let demo = AndroidTVController(enabled: false, storage: store, makeSocket: { created += 1; return Socket() })
            demo.pair(Rig.link); demo.reconnect(); demo.forget(); demo.click(); demo.becameActive()
            check("demo has no Keychain or network", created == 0 && store.reads == 0 && store.writes == 0 && store.deletes == 0)
        }
        print("\(count) Android TV iOS protocol/lifecycle checks passed; no device, Keychain or desktop input.")
    }
}
