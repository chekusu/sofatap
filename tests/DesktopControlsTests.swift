import Foundation

@MainActor private final class ControlsFixture {
    struct Frame {
        let type: String
        let fields: [String: Any]
        let reply: ([String: Any]) -> Void
    }
    var frames: [Frame] = []
    lazy var model = ControllerModel(testLiveSend: { [unowned self] type, fields, reply in
        frames.append(Frame(type: type, fields: fields, reply: reply))
    })
    func ready(volume: Bool = true) {
        model.testReceiveState(ReceiverState(platform: .macos, status: .ready, inputAvailable: true,
                                            supportsLiveText: true, supportsSystemVolume: volume))
    }
}

@main struct DesktopControlsTests {
    @MainActor static func main() throws {
        var passed = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        let volume = ControlsFixture()
        volume.ready(volume: false)
        volume.model.changeSystemVolume(.up)
        check("old receiver never receives a volume action", volume.frames.isEmpty && !volume.model.canChangeSystemVolume)
        volume.ready()
        volume.model.changeSystemVolume(.up)
        check("volume uses its dedicated command", volume.frames.count == 1 && volume.frames[0].type == "volume" && volume.frames[0].fields["command"] as? String == "up")
        volume.model.changeSystemVolume(.mute)
        check("rapid repeat is not queued while ACK is outstanding", volume.frames.count == 1 && volume.model.volumeBusy)
        volume.frames[0].reply(["ok": true])
        check("ACK enables the next deliberate tap", volume.model.canChangeSystemVolume && !volume.model.volumeBusy)
        volume.model.changeSystemVolume(.down)
        volume.frames[1].reply(["ok": false, "error": "volume_unavailable"])
        check("receiver refusal surfaces an error without retry", volume.model.volumeFeedback != nil && volume.frames.count == 2 && !volume.model.volumeBusy)
        volume.model.changeSystemVolume(.mute)
        check("mute is explicit and does not claim an on/off state", volume.frames[2].fields["command"] as? String == "mute")
        volume.frames[2].reply(["uncertain": true])
        check("uncertain delivery is reported without replay", volume.model.volumeFeedback != nil && volume.frames.count == 3 && !volume.model.volumeBusy)
        volume.model.changeSystemVolume(.up)
        volume.model.disconnect()
        check("disconnect clears busy but retains uncertainty", !volume.model.volumeBusy && volume.model.volumeFeedback != nil)
        volume.model.testSwitchDeviceBoundary()
        volume.ready()
        volume.model.changeSystemVolume(.down)
        volume.frames[3].reply(["ok": false])
        check("late ACK from previous connection cannot unlock new command", volume.model.volumeBusy && volume.model.volumeFeedback == nil)
        volume.frames[4].reply(["ok": true])
        volume.model.testReceiveState(ReceiverState(platform: .macos, status: .desktop_unavailable, supportsSystemVolume: true))
        volume.model.changeSystemVolume(.up)
        check("locked or unavailable input rejects volume locally", volume.frames.count == 5 && !volume.model.canChangeSystemVolume)
        volume.ready()
        volume.model.setDesktopControlEnabled(false)
        volume.model.changeSystemVolume(.up)
        check("TV selection cannot send a desktop volume action", volume.frames.count == 5 && !volume.model.canChangeSystemVolume)

        let motion = ControlsFixture()
        motion.ready()
        motion.model.move(dx: 8, dy: -6); motion.model.testFlushMovement()
        check("default speed preserves previous deltas", motion.frames[0].fields["dx"] as? Double == 8 && motion.frames[0].fields["dy"] as? Double == -6)
        motion.frames[0].reply(["ok": true])
        motion.model.setPointerSpeed(2)
        motion.model.move(dx: 8, dy: -6); motion.model.testFlushMovement()
        check("speed scales both axes exactly once", motion.frames[1].fields["dx"] as? Double == 16 && motion.frames[1].fields["dy"] as? Double == -12)
        motion.frames[1].reply(["ok": true])
        motion.model.scroll(dy: 10); motion.model.testFlushMovement()
        check("pointer speed preserves existing 8x scroll units", motion.frames[2].type == "scroll" && motion.frames[2].fields["dy"] as? Double == 80)
        motion.frames[2].reply(["ok": true])
        motion.model.move(dx: 4, dy: 4)
        motion.model.setPointerSpeed(0.25); motion.model.testFlushMovement()
        check("changing speed discards old unsent samples", motion.frames.count == 3)
        motion.model.move(dx: 8, dy: -4); motion.model.testFlushMovement()
        check("slow multiplier preserves fractional precision", motion.frames[3].fields["dx"] as? Double == 2 && motion.frames[3].fields["dy"] as? Double == -1)
        motion.frames[3].reply(["ok": true])
        motion.model.setPointerSpeed(100)
        motion.model.move(dx: 400, dy: -400); motion.model.testFlushMovement()
        check("speed and wire movement stay bounded", motion.model.sensitivity == 3 && motion.frames[4].fields["dx"] as? Double == 500 && motion.frames[4].fields["dy"] as? Double == -500)
        motion.frames[4].reply(["ok": true])
        motion.model.setPointerSpeed(.nan)
        check("invalid multiplier resets to default", motion.model.sensitivity == 1)
        motion.model.setPointerSpeed(-1)
        check("negative multiplier cannot reverse pointer", motion.model.sensitivity == 0.25)
        motion.model.setPointerSpeed(2)
        motion.model.setDragging(true); motion.frames[5].reply(["ok": true])
        motion.model.move(dx: 7, dy: -9); motion.model.setDragging(false)
        check("drag tail keeps selected multiplier", motion.frames[6].type == "move" && motion.frames[6].fields["dx"] as? Double == 14 && motion.frames[6].fields["dy"] as? Double == -18)
        motion.frames[6].reply(["ok": true])
        check("tail is acknowledged before button up", motion.frames[7].type == "button" && motion.frames[7].fields["down"] as? Bool == false)
        motion.frames[7].reply(["ok": true])

        // Exercise real JSON serialization, pending-command timeout and reconnect without a socket.
        var library = DeviceLibrary<Pairing>()
        library.upsert(Pairing(host: "recording.local", port: 53317, token: String(repeating: "a", count: 43), fingerprint: String(repeating: "b", count: 64)))
        var wire: [[String: Any]] = []
        var retry: (() -> Void)?
        let transport = ControllerModel(testPairingLibrary: library, testPairingWrite: { _ in library },
                                        testPairingConnect: { _ in }, testScheduleReconnect: { _, fire in retry = fire },
                                        testWireSend: { wire.append(try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]) })
        transport.connect(); transport.testConnectionEstablished()
        let ready = ReceiverState(platform: .windows, status: .ready, inputAvailable: true, supportsSystemVolume: true)
        transport.testReceiveState(ready); transport.changeSystemVolume(.mute)
        check("wire contains only strict volume fields and UUID", Set(wire[0].keys) == ["id", "type", "command"] && UUID(uuidString: wire[0]["id"] as! String) != nil)
        transport.testCommandTimeout("volume")()
        check("timeout disconnects and clears volume busy", !transport.connected && !transport.volumeBusy && transport.volumeFeedback != nil && retry != nil)
        retry?(); transport.testConnectionEstablished(); transport.testReceiveState(ready)
        check("reconnect restores control without replaying mute", transport.canChangeSystemVolume && wire.count == 1)
        transport.changeSystemVolume(.up); transport.testAcknowledgeCommand("volume")
        check("new tap after reconnect has new UUID", wire.count == 2 && wire[0]["id"] as? String != wire[1]["id"] as? String && !transport.volumeBusy)
        transport.changeSystemVolume(.mute); transport.testAcknowledgeCommand("volume", ok: false, error: "volume_unknown: fixture")
        check("partial native write asks user to check actual volume", transport.volumeFeedback == String(localized: "音量操作未确认，请查看电脑音量后再操作。") && wire.count == 3)
        transport.becameInactive(); transport.changeSystemVolume(.down)
        check("background never sends volume", wire.count == 3 && !transport.canChangeSystemVolume)
        transport.disconnectDevice()
        print("PASS \(passed) desktop control checks (recording transport, no real audio/input)")
    }
}
