import Foundation

// Calls the actual ControllerModel through its compile-time-only recording
// transport. There is no session, pairing store, window, timer, or OS input.
@MainActor
private final class DragFixture {
    struct Frame {
        let type: String
        let fields: [String: Any]
        var ack: ((Bool) -> Void)?
        var tag: String {
            type == "button" ? ((fields["down"] as? Bool) == true ? "down" : "up") : type
        }
    }
    let peer: Bool
    init(peer: Bool = true) { self.peer = peer }
    var frames: [Frame] = []
    lazy var model = ControllerModel(testPeer: peer, testSend: { [unowned self] type, fields, ack in
        self.frames.append(Frame(type: type, fields: fields, ack: ack))
    })
    var tags: [String] { frames.map(\.tag) }
    func ack(_ index: Int, _ accepted: Bool = true) {
        guard let callback = frames[index].ack else { preconditionFailure("ACK replay in test") }
        frames[index].ack = nil
        callback(accepted)
    }
    func begin() { model.setDragging(true); ack(0) }
}

@MainActor
private final class AckFixture {
    var frames: [[String: Any]] = []
    lazy var model = ControllerModel(testRecordingWire: { [unowned self] text in
        frames.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    })
    func ack(_ index: Int, error: String? = nil) {
        var message: [String: Any] = ["type": "ack", "id": frames[index]["id"]!, "ok": error == nil]
        if let error { message["error"] = error }
        precondition(model.testReceiveAcknowledgement(message))
    }
}

@main
struct ControllerDragReleaseTests {
    @MainActor static func main() {
        var passed = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }

        // Failure cases: ordinary busy must preserve the session without replay;
        // unknown/partial failures, timeouts, held/releasing drags must disconnect.
        // Use serialized outbound frames and production ACK dispatch, not testLiveSend.
        for error in ["input_busy: physical button held", "input_busy"] {
            let busy = AckFixture()
            for _ in 0..<12 { busy.model.moveFromTouch(dx: 1, dy: 0) }
            busy.model.moveFromTouch(dx: 99, dy: 0)
            busy.ack(0, error: error)
            check("production busy ACK preserves connection", busy.model.connected)
            check("notice never echoes server suffix", !busy.model.notice.contains("physical button held"))
            for i in 1..<12 { busy.ack(i) }
            check("production busy ACK discards queued motion", busy.frames.count == 12)
            busy.model.moveFromTouch(dx: 2, dy: 0)
            check("fresh gesture resumes after production busy ACK", busy.frames.count == 13 && busy.frames.last?["dx"] as? Double == 2)
            busy.ack(12)
            busy.model.disconnect()
        }
        for error in ["input_partial: interrupted", "unknown: private server text", "input_busy_extra: held", "input_failed: failed"] {
            let failed = AckFixture()
            failed.model.moveFromTouch(dx: 1, dy: 0)
            failed.ack(0, error: error)
            check("unsafe production ACK disconnects: " + error, !failed.model.connected)
        }
        let timeout = AckFixture()
        timeout.model.moveFromTouch(dx: 1, dy: 0)
        timeout.model.testCommandTimeout("move")()
        check("uncertain movement timeout disconnects", !timeout.model.connected)
        for releasing in [false, true] {
            let held = AckFixture()
            held.model.setDragging(true); held.ack(0)
            held.model.moveFromTouch(dx: 1, dy: 0)
            if releasing { held.model.setDragging(false) }
            held.ack(1, error: "input_busy: physical button held")
            check("busy ACK during held/releasing drag disconnects", !held.model.connected && !held.model.dragging)
        }

        // A touch callback must not wait on a second periodic clock. A recovered
        // send window must drain fresh motion on ACK, not wait one more timer tick.
        let lan = DragFixture(peer: false)
        lan.begin()
        for _ in 0..<12 { lan.model.moveFromTouch(dx: 1, dy: 0) }
        check("LAN admits twelve bounded moves for 120Hz over 100ms RTT", lan.frames.count == 13)
        lan.model.moveFromTouch(dx: 2, dy: 0)
        check("LAN does not exceed twelve in flight", lan.frames.count == 13)
        lan.model.setDragging(false)
        for index in (2...12).reversed() { lan.ack(index) }
        check("LAN release still waits for the oldest move", !lan.tags.contains("up"))
        lan.ack(1)
        check("LAN frozen tail is sent after every prior ACK", lan.frames.count == 14 && lan.frames[13].fields["dx"] as? Double == 2)
        lan.ack(13)
        check("LAN release follows tail acknowledgement", lan.tags.last == "up")
        lan.ack(14)

        let direct = DragFixture()
        direct.model.moveFromTouch(dx: 3, dy: -2)
        check("touch sample sends before an unrelated timer tick", direct.frames.count == 1)
        direct.ack(0)
        for _ in 0..<8 { direct.model.moveFromTouch(dx: 3, dy: -2) }
        check("touch stream keeps the bounded eight-frame window", direct.frames.count == 9)
        direct.model.moveFromTouch(dx: 2, dy: -1)
        direct.model.moveFromTouch(dx: 4, dy: -2)
        check("full touch window retains a coalesced batch", direct.frames.count == 9)
        direct.ack(1)
        check("ACK sends the fresh batch without timer-phase delay", direct.frames.count == 10 && direct.frames[9].fields["dx"] as? Double == 6)
        for index in 2..<10 { direct.ack(index) }

        // Failure modes: ACK latency drops relative distance; stop-and-wait reduces
        // cadence; congestion grows stale motion; out-of-order ACK releases a drag
        // early; rejection leaks motion; old-generation ACK corrupts a new session.
        let stream = DragFixture()
        for _ in 0..<8 {
            stream.model.move(dx: 3, dy: -2)
            stream.model.testFlushMovement()
        }
        check("eight frames can travel before the first ACK", stream.frames.count == 8)
        for _ in 0..<3 { stream.model.move(dx: 3, dy: -2); stream.model.testFlushMovement() }
        check("congestion never exceeds eight in-flight moves", stream.frames.count == 8)
        stream.ack(0)
        stream.model.testFlushMovement()
        check("waiting relative samples accumulate instead of overwrite", stream.frames.count == 9 &&
              stream.frames[8].fields["dx"] as? Double == 9 && stream.frames[8].fields["dy"] as? Double == -6)
        for index in 1..<9 { stream.ack(index) }
        check("all fresh relative displacement is conserved", stream.frames.reduce(0.0) { $0 + ($1.fields["dx"] as? Double ?? 0) } == 33)

        let pipelinedDrag = DragFixture()
        pipelinedDrag.begin()
        for _ in 0..<3 { pipelinedDrag.model.move(dx: 4, dy: 0); pipelinedDrag.model.testFlushMovement() }
        pipelinedDrag.model.setDragging(false)
        pipelinedDrag.ack(3)
        pipelinedDrag.ack(1)
        check("out-of-order ACKs cannot release drag before every move", !pipelinedDrag.tags.contains("up"))
        pipelinedDrag.ack(2)
        check("all movement ACKs permit one release", pipelinedDrag.tags == ["down", "move", "move", "move", "up"])
        pipelinedDrag.ack(4)

        let stalled = DragFixture()
        stalled.model.move(dx: 10, dy: 0); stalled.model.testFlushMovement()
        Thread.sleep(forTimeInterval: 0.14)
        stalled.model.move(dx: 8, dy: 0); stalled.model.testFlushMovement()
        check("old outstanding frame closes the send window", stalled.frames.count == 1)
        stalled.ack(0); stalled.model.testFlushMovement()
        check("recovered window sends only fresh queued movement", stalled.frames.count == 2 && stalled.frames[1].fields["dx"] as? Double == 8)
        stalled.ack(1)
        stalled.model.move(dx: 9, dy: 0)
        Thread.sleep(forTimeInterval: 0.14)
        stalled.model.testFlushMovement()
        check("expired unsent motion is never replayed", stalled.frames.count == 2)

        let tail = DragFixture()
        tail.begin()
        tail.model.move(dx: 20, dy: -18)
        tail.model.setDragging(false)
        check("release flushes tail immediately ahead of mouse-up", tail.tags == ["down", "move"])
        check("frozen tail preserves both axes", tail.frames[1].fields["dx"] as? Double == 20 && tail.frames[1].fields["dy"] as? Double == -18)
        check("input stays paused while the remote button may still be held", !tail.model.canControl)
        check("pending release does not report session loss to the UI", tail.model.controlAvailable)
        tail.model.testFlushMovement()
        tail.model.pauseInput()
        tail.model.setDragging(false)
        check("timer and UI cancellation cannot drop or duplicate the tail", tail.tags == ["down", "move"])
        check("release waiting keeps the same UI availability state", tail.model.controlAvailable)
        tail.ack(1)
        check("tail ACK permits exactly one mouse-up", tail.tags == ["down", "move", "up"])
        check("button-up ACK is required before next gesture", !tail.model.canControl)
        check("waiting for mouse-up ACK does not stop dictation via availability", tail.model.controlAvailable)
        tail.ack(2)
        tail.model.testFlushMovement()
        check("no old movement escapes after mouse-up", tail.tags == ["down", "move", "up"] && tail.model.canControl)
        check("completed release never toggles the session availability gate", tail.model.controlAvailable)

        let busy = DragFixture()
        busy.begin()
        busy.model.move(dx: 94, dy: -76)
        busy.model.testFlushMovement()
        busy.model.move(dx: 20, dy: -18)
        busy.model.setDragging(false)
        check("release waits for an already in-flight move", busy.tags == ["down", "move"])
        busy.model.move(dx: 200, dy: 200)
        busy.model.click("right")
        busy.model.setDragging(true)
        busy.model.testFlushMovement()
        check("a new gesture cannot overtake the pending release", busy.tags == ["down", "move"])
        Thread.sleep(forTimeInterval: 0.14)
        busy.ack(1)
        check("drag tail survives the normal movement freshness cutoff", busy.tags == ["down", "move", "move"] && busy.frames[2].fields["dx"] as? Double == 20)
        busy.ack(2)
        check("in-flight move then tail then up remain ordered", busy.tags == ["down", "move", "move", "up"])
        busy.ack(3)
        busy.model.setDragging(true)
        check("next drag begins only after the previous up ACK", busy.tags == ["down", "move", "move", "up", "down"])
        busy.ack(4)
        busy.model.setDragging(false)
        busy.ack(5)

        let noTail = DragFixture()
        noTail.begin()
        noTail.model.setDragging(false)
        check("stationary hold releases without an invented move", noTail.tags == ["down", "up"])
        noTail.ack(1)

        let busyNoTail = DragFixture()
        busyNoTail.begin()
        busyNoTail.model.move(dx: 10, dy: 0)
        busyNoTail.model.testFlushMovement()
        busyNoTail.model.setDragging(false)
        check("even empty tail waits for the last in-flight move", busyNoTail.tags == ["down", "move"])
        busyNoTail.ack(1)
        check("empty tail follows ACK with up", busyNoTail.tags == ["down", "move", "up"])
        busyNoTail.ack(2)

        let failedTail = DragFixture()
        failedTail.begin()
        failedTail.model.move(dx: 20, dy: -18)
        failedTail.model.setDragging(false)
        failedTail.ack(1, false)
        check("tail rejection disconnects for receiver release cleanup", !failedTail.model.connected && !failedTail.model.canControl)
        check("real disconnect while input is already gated still requests UI cleanup", !failedTail.model.controlAvailable)
        failedTail.model.testFlushMovement()
        check("rejected tail is never replayed", failedTail.tags == ["down", "move"])

        let failedFlight = DragFixture()
        failedFlight.begin()
        failedFlight.model.move(dx: 94, dy: -76)
        failedFlight.model.testFlushMovement()
        failedFlight.model.move(dx: 20, dy: -18)
        failedFlight.model.setDragging(false)
        failedFlight.ack(1, false)
        check("in-flight rejection disconnects instead of continuing a partial drag", !failedFlight.model.connected && failedFlight.tags == ["down", "move"])

        let failedUp = DragFixture()
        failedUp.begin()
        failedUp.model.setDragging(false)
        failedUp.ack(1, false)
        check("mouse-up rejection keeps the disconnect release protection", !failedUp.model.connected)

        let staleAck = DragFixture()
        staleAck.begin()
        staleAck.model.move(dx: 10, dy: 5)
        staleAck.model.setDragging(false)
        staleAck.model.disconnect(message: "test interruption")
        staleAck.ack(1)
        check("late ACK after disconnect cannot advance the old drag", staleAck.tags == ["down", "move"] && !staleAck.model.connected)
        check("late ACK cannot restore the disconnected availability gate", !staleAck.model.controlAvailable)

        let television = DragFixture()
        television.begin()
        television.model.pauseInput()
        check("switching away releases held desktop input first", television.tags == ["down", "up"])
        television.model.setDesktopControlEnabled(false)
        check("TV selection disables computer transport and input", !television.model.desktopControlEnabled && !television.model.connected && !television.model.canControl)
        television.ack(1)
        television.model.becameActive()
        television.model.connect()
        television.model.move(dx: 100, dy: 20)
        television.model.testFlushMovement()
        television.model.click("left")
        television.model.key("enter")
        check("scene activation and late ACK cannot resume desktop while TV selected", television.tags == ["down", "up"] && !television.model.canControl && !television.model.connecting)
        television.model.setDesktopControlEnabled(true)
        check("explicit computer selection restores mode but does not invent a connection", television.model.desktopControlEnabled && !television.model.connected)

        let androidTV = DragFixture()
        androidTV.begin()
        androidTV.model.pauseInput()
        androidTV.model.setDesktopControlEnabled(false, televisionTarget: "androidtv")
        androidTV.ack(1)
        androidTV.model.becameActive()
        androidTV.model.connect()
        androidTV.model.move(dx: 50, dy: 10)
        androidTV.model.testFlushMovement()
        androidTV.model.click("left")
        check("Android TV selection releases drag and blocks desktop reconnect/input", androidTV.tags == ["down", "up"] && !androidTV.model.desktopControlEnabled && !androidTV.model.canControl && !androidTV.model.connecting)
        androidTV.model.setDesktopControlEnabled(false, televisionTarget: "webos")
        androidTV.model.becameActive()
        check("switching TV adapters stays disconnected from the computer", !androidTV.model.connected && !androidTV.model.connecting)
        androidTV.model.setDesktopControlEnabled(true)
        check("explicit return from Android TV restores only desktop mode", androidTV.model.desktopControlEnabled && !androidTV.model.connected)

        print("Controller drag release: \(passed) recording-transport checks passed without windows or OS input")
    }
}
