import Foundation
import Darwin

@MainActor private final class ReconnectFixture {
    var library: DeviceLibrary<Pairing>
    var failRead = false
    var reads = 0
    var connections: [Pairing] = []
    var scheduled: [(delay: TimeInterval, fire: () -> Void)] = []
    var frames: [String] = []
    let recordingWire: Bool
    init(_ library: DeviceLibrary<Pairing>, recordingWire: Bool = false) {
        self.library = library; self.recordingWire = recordingWire
    }
    lazy var model = ControllerModel(testPairingLibrary: library, testPairingWrite: { [unowned self] pairing in
        library.upsert(pairing); return library
    }, testPairingConnect: { [unowned self] in connections.append($0) }, testPairingRead: { [unowned self] in
        reads += 1
        if failRead { throw DeviceLibraryError.unavailable }
        return library
    }, testScheduleReconnect: { [unowned self] delay, fire in
        scheduled.append((delay, fire))
    }, testInputSend: recordingWire ? nil : { [unowned self] type, _, reply in
        frames.append(type)
        reply(["uncertain": true])
    }, testWireSend: { [unowned self] text in
        let frame = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        frames.append(frame["type"] as! String)
    })
}

@main
struct PairingAttemptTests {
    @MainActor static func main() throws {
        var passed = 0
        func check(_ name: String, _ condition: @autoclosure () throws -> Bool) rethrows {
            guard try condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        let token = String(repeating: "a", count: 43)
        let pinA = String(repeating: "a", count: 64)
        let pinB = String(repeating: "b", count: 64)
        let pcA = "sofatap://pair?host=pc-a.local&port=53317&token=\(token)&fingerprint=\(pinA)"
        let pcB = "sofatap://pair?host=pc-b.local&port=53317&token=\(token)&fingerprint=\(pinB)&name=New%20PC"
        let stagedPairing = try Pairing.parse(pcA)
        let stagedLibrary = DeviceLibrary(devices: [SavedDevice(credential: stagedPairing)], selectedID: SavedDevice(credential: stagedPairing).id)
        var prepared: [(UInt16?) -> Void] = []
        var opened: [Pairing] = []
        var peerRetries: [() -> Void] = []
        let staged = ControllerModel(testPairingLibrary: stagedLibrary,
            testPairingWrite: { _ in stagedLibrary }, testPairingConnect: { opened.append($0) },
            testScheduleReconnect: { _, retry in peerRetries.append(retry) },
            testPrepareConnection: { prepared.append($0) })
        staged.connect()
        check("transport waits for route preparation", staged.connecting && opened.isEmpty && prepared.count == 1)
        staged.disconnectDevice()
        prepared[0](nil)
        check("late preparation cannot reopen a disconnected device", opened.isEmpty && !staged.connecting)
        staged.connect()
        prepared[0](nil)
        check("old preparation cannot replace a newer connection attempt", opened.isEmpty)
        prepared[1](12345)
        check("current preparation starts authenticated connection", opened == [stagedPairing])
        staged.testTransportFailure(retryable: true)
        check("failed peer handshake schedules one retry", peerRetries.count == 1)
        peerRetries[0]()
        check("peer handshake failure retries LAN without another discovery", prepared.count == 2 && opened.count == 2)
        staged.disconnectDevice()
        staged.connect()
        prepared[2](12346)
        staged.testConnectionEstablished()
        check("established peer reports peer route", staged.connected && staged.usesPeerTransport)
        staged.testTransportFailure(retryable: true)
        check("established peer failure schedules recovery", peerRetries.count == 2 && !staged.connected)
        peerRetries[1]()
        check("established peer failure recovers over LAN without rediscovery", prepared.count == 3 && opened.count == 4)
        staged.testConnectionEstablished()
        check("recovered LAN clears peer route label", staged.connected && !staged.usesPeerTransport)
        staged.disconnectDevice()
        // Mode changes must persist, invalidate old route callbacks and reconnect
        // only an active connection; a manually disconnected device stays paused.
        let modeSuite = "Sofatap-mode-test-" + UUID().uuidString
        let modeDefaults = UserDefaults(suiteName: modeSuite)!
        defer { modeDefaults.removePersistentDomain(forName: modeSuite) }
        var modePrepared: [(UInt16?) -> Void] = []
        var modeOpened = 0
        func modeModel() -> ControllerModel {
            ControllerModel(testPairingLibrary: stagedLibrary, testPairingWrite: { _ in stagedLibrary },
                testPairingConnect: { _ in modeOpened += 1 },
                testPrepareConnection: { modePrepared.append($0) }, testConnectionDefaults: modeDefaults)
        }
        let mode = modeModel()
        check("connection preference defaults to automatic", mode.connectionMode == .automatic)
        mode.connect()
        mode.setConnectionMode(.wifi)
        check("switching to Wi-Fi skips discovery and starts fresh transport", modeOpened == 1 && modePrepared.count == 1)
        modePrepared[0](12349)
        check("old peer completion cannot override manual Wi-Fi", modeOpened == 1)
        mode.testConnectionEstablished()
        check("Wi-Fi route does not report peer", !mode.usesPeerTransport)
        mode.setConnectionMode(.wifi)
        check("same mode does not reconnect", modeOpened == 1 && mode.connected)
        check("mode survives model recreation", modeModel().connectionMode == .wifi)
        mode.setConnectionMode(.automatic)
        check("automatic selection retries peer discovery", modePrepared.count == 2 && !mode.connected)
        modePrepared[1](12350)
        mode.testConnectionEstablished()
        check("automatic can return to peer", mode.usesPeerTransport)
        mode.disconnectDevice()
        mode.setConnectionMode(.wifi)
        check("preference change preserves manual disconnect", !mode.connecting && !mode.connected && modeOpened == 2)
        mode.connect()
        check("manual connect uses persisted Wi-Fi preference", modeOpened == 3 && modePrepared.count == 2)
        mode.disconnectDevice()
        var availabilityReplies: [(Bool) -> Void] = []
        let availability = ControllerModel(testPairingLibrary: stagedLibrary,
            testPairingWrite: { _ in stagedLibrary }, testPairingConnect: { _ in },
            testPeerAvailabilityMonitor: { availabilityReplies.append($0) })
        check("route selector hidden before discovery", !availability.peerConnectionAvailable)
        availability.startPeerAvailabilityMonitoring()
        availabilityReplies[0](true)
        check("matching peer discovery exposes selector", availability.peerConnectionAvailable)
        availability.setConnectionMode(.wifi)
        check("Wi-Fi selection retains available peer choice", availability.peerConnectionAvailable)
        availabilityReplies[0](false)
        check("peer disappearance hides selector", !availability.peerConnectionAvailable)
        availability.stopPeerAvailabilityMonitoring()
        availabilityReplies[0](true)
        check("stale availability callback cannot expose selector", !availability.peerConnectionAvailable)
        availability.startPeerAvailabilityMonitoring()
        check("fresh monitor starts hidden", !availability.peerConnectionAvailable && availabilityReplies.count == 2)
        availabilityReplies[1](true)
        availability.stopPeerAvailabilityMonitoring()
        check("closing settings clears availability", !availability.peerConnectionAvailable)
        availability.startPeerAvailabilityMonitoring()
        availabilityReplies[2](true)
        availability.startPeerAvailabilityMonitoring()
        check("repeated settings lifecycle event reuses active monitor", availabilityReplies.count == 3 && availability.peerConnectionAvailable)
        availability.becameInactive()
        check("model inactivity clears monitoring without view callback", !availability.peerConnectionAvailable)
        availabilityReplies[2](true)
        availability.startPeerAvailabilityMonitoring()
        check("inactive model neither accepts old results nor starts browsing", !availability.peerConnectionAvailable && availabilityReplies.count == 3)
        availability.becameActive()
        check("foreground resumes a monitor requested before model activation", availabilityReplies.count == 4)
        availability.startPeerAvailabilityMonitoring()
        availabilityReplies[3](true)
        availability.setDesktopControlEnabled(false)
        check("switching to TV clears peer monitor at model boundary", !availability.peerConnectionAvailable)
        availabilityReplies[3](true)
        check("TV cannot receive stale desktop availability", !availability.peerConnectionAvailable)
        let tv = "sofatap://tv?host=192.168.1.8&port=53318&token=\(token)&fingerprint=\(pinA)"
        let reorderedTV = "SOFATAP://tv?fingerprint=\(pinA.uppercased())&name=New%20label&token=\(token)&port=053318&host=192.168.1.8"
        var attempt = PairingAttemptState()
        try check("valid desktop candidate starts", attempt.begin(pcB))
        check("desktop retry retains the candidate's exact original link", attempt.computerRetryLink == pcB)
        try check("changed metadata/order/case do not restart desktop credentials", !attempt.begin("SOFATAP://pair?token=\(token)&host=PC-B.LOCAL&fingerprint=\(pinB.uppercased())&port=053317&name=Other"))
        check("duplicate desktop delivery does not replace retry source", attempt.computerRetryLink == pcB)
        do { _ = try attempt.begin("https://unrelated.example"); check("invalid QR rejected", false) }
        catch { check("invalid QR preserves the pending candidate", attempt.computerRetryLink == pcB) }
        attempt.markAuthenticated()
        check("successful candidate no longer owns a cancellation or retry", attempt.pendingCandidate == nil && attempt.computerRetryLink == nil)
        try check("successful duplicate does not reset naming", !attempt.begin(pcB) && attempt.authenticated)

        var android = PairingAttemptState()
        var bootstrapConnections: [PairingCode] = []
        check("scanner validation does not consume a fresh bootstrap", android.canBegin(tv) && android.canBegin(reorderedTV) && android.candidate == nil)
        func deliverTV(_ raw: String) throws {
            if try android.begin(raw), let candidate = android.candidate { bootstrapConnections.append(candidate) }
        }
        try deliverTV(tv); try deliverTV(reorderedTV)
        check("camera then canonical pasted/link duplicate opens one pending bootstrap", bootstrapConnections.count == 1)
        android.markAuthenticated(); try deliverTV(reorderedTV)
        check("duplicate while naming preserves authenticated connection", bootstrapConnections.count == 1 && android.authenticated)
        android.resetScanner()
        check("scanner rejects a spent code before stopping capture", !android.canBegin(reorderedTV))
        do { try deliverTV(tv); check("reset must not replay a consumed bootstrap", false) }
        catch { check("reset retains bootstrap attempt history", android.candidate == nil && bootstrapConnections.count == 1) }
        do { try deliverTV(tv.replacingOccurrences(of: "192.168.1.8", with: "192.168.1.9")); check("alias must not replay same token", false) }
        catch { check("same pin and token at another address are not replayed", bootstrapConnections.count == 1) }
        let freshTV = tv.replacingOccurrences(of: "token=\(token)", with: "token=\(String(repeating: "z", count: 43))")
        check("scanner stays able to accept a fresh code after rejecting a spent one", android.canBegin(freshTV))
        try deliverTV(freshTV)
        check("new QR token can start another attempt", bootstrapConnections.count == 2 && !android.authenticated)
        _ = try android.begin(pcA)
        do { try deliverTV(tv); check("switching adapters must not replay an earlier token", false) }
        catch { check("rejected old bootstrap leaves current desktop candidate intact", android.computerRetryLink == pcA) }
        var interrupted = PairingAttemptState(); _ = try interrupted.begin(tv); interrupted.resetScanner()
        do { _ = try interrupted.begin(reorderedTV); check("failed bootstrap must not be retried", false) }
        catch { check("even an unconfirmed bootstrap needs a fresh QR", interrupted.candidate == nil) }

        let old = try Pairing.parse(pcA), new = try Pairing.parse(pcB)
        var library = DeviceLibrary<Pairing>(); library.upsert(old)
        var writes: [Pairing] = [], connections: [Pairing] = []
        var failSave = true
        let model = ControllerModel(testPairingLibrary: library, testPairingWrite: { value in
            writes.append(value)
            if failSave { throw PairingError.storeFailed }
            library.upsert(value); return library
        }, testPairingConnect: { connections.append($0) })
        model.connect()
        check("fixture has an existing connection attempt to A", connections == [old] && model.connecting)
        model.acceptPairing("invalid")
        check("unrelated invalid input cannot cancel an existing target", model.connecting && connections == [old] && writes.isEmpty)
        var desktopFlow = PairingAttemptState(); _ = try desktopFlow.begin(pcB)
        model.acceptPairing(desktopFlow.computerRetryLink!)
        check("failed B save disconnects A and records only candidate B", !model.connected && !model.connecting && model.pairing == old && writes == [new])
        model.becameInactive(); model.becameActive()
        check("failed B save cannot auto-reconnect stored A on foreground", connections == [old] && !model.connecting)
        if case .computer = desktopFlow.pendingCandidate { model.disconnectDevice() }
        model.becameInactive(); model.becameActive()
        check("cancel after save failure keeps old A paused", connections == [old])
        failSave = false
        model.acceptPairing(desktopFlow.computerRetryLink!)
        check("explicit Retry persists original B rather than connecting A", writes == [new, new] && model.pairing == new && connections == [old, new])
        check("retry selects the newly saved device before connecting", model.selectedDeviceID == SavedDevice(credential: new).id)
        model.disconnect(message: "test timeout")
        if case .computer = desktopFlow.pendingCandidate { model.disconnectDevice() }
        model.becameInactive(); model.becameActive()
        check("cancel after timeout prevents foreground reconnection", connections == [old, new] && !model.connecting)
        model.acceptPairing(desktopFlow.computerRetryLink!)
        model.becameInactive()
        if case .computer = desktopFlow.pendingCandidate { model.disconnectDevice() }
        model.becameActive()
        check("cancel after background disconnection remains paused", connections == [old, new, new] && !model.connecting)
        desktopFlow.resetScanner()
        check("rescan relinquishes old retry and pending candidate", desktopFlow.computerRetryLink == nil && desktopFlow.pendingCandidate == nil)
        _ = try desktopFlow.begin(pcA)
        model.acceptPairing(desktopFlow.computerRetryLink!)
        check("a fresh explicit candidate can reconnect after cancellation", model.pairing == old && connections == [old, new, new, old])
        model.disconnectDevice()

        var selectedLibrary = DeviceLibrary<Pairing>()
        selectedLibrary.upsert(old); selectedLibrary.upsert(new)
        let cold = ReconnectFixture(selectedLibrary)
        cold.model.becameActive(); cold.model.becameActive()
        check("cold launch restores and connects only the persisted selection once", cold.reads == 1 && cold.connections == [new] && cold.model.selectedDeviceID == selectedLibrary.selectedID)
        cold.model.testConnectionEstablished()
        check("recording hello establishes the recovered connection", cold.model.connected && cold.model.inputAvailable)
        cold.model.becameInactive(); cold.model.becameActive()
        check("returning to foreground reuses saved credentials without pairing again", cold.connections == [new, new] && cold.library.devices.count == 2)

        let locked = ReconnectFixture(selectedLibrary); locked.failRead = true
        locked.model.becameActive()
        check("unreadable Keychain exposes an error and never connects a cached or fallback device", locked.model.pairing == nil && locked.model.pairingError != nil && locked.connections.isEmpty)
        locked.failRead = false
        locked.model.becameActive()
        check("unlock then foreground restores the selected pairing and clears the storage error", locked.model.pairing == new && locked.model.pairingError == nil && locked.connections == [new])
        var noSelectionLibrary = selectedLibrary; noSelectionLibrary.selectedID = nil
        let unselected = ReconnectFixture(noSelectionLibrary); unselected.model.becameActive()
        check("restoring saved devices without a selection never silently chooses a target", unselected.connections.isEmpty && unselected.model.savedDevices.count == 2)

        let retries = ReconnectFixture(selectedLibrary); retries.model.becameActive()
        for expectedDelay: TimeInterval in [1, 2, 4, 8, 16, 30, 30] {
            retries.model.testTransportFailure()
            check("transient failures use capped exponential reconnect delay \(expectedDelay)", retries.scheduled.last?.delay == expectedDelay && !retries.model.connecting)
            let attempts = retries.connections.count
            retries.model.becameActive()
            check("duplicate foreground notifications cannot bypass pending backoff", retries.connections.count == attempts)
            retries.scheduled.last!.fire()
            check("scheduled retry restores only the same selected endpoint", retries.connections.count == attempts + 1 && retries.connections.last == new)
        }
        retries.model.testConnectionEstablished(); retries.model.testTransportFailure()
        check("successful authentication resets subsequent reconnect backoff", retries.scheduled.last?.delay == 1)
        retries.scheduled.last!.fire()
        let oldGeneration = retries.model.testConnectionGeneration
        retries.model.testTransportFailure()
        let obsoleteRetry = retries.scheduled.last!.fire
        retries.model.acceptPairing(pcA)
        let attemptsAfterSwitch = retries.connections.count
        obsoleteRetry(); retries.model.testTransportFailure(generation: oldGeneration)
        check("canceled timer and old transport failure cannot reconnect or disconnect the new target", retries.connections.count == attemptsAfterSwitch && retries.model.pairing == old && retries.model.connecting)

        let canceled = ReconnectFixture(selectedLibrary); canceled.model.becameActive(); canceled.model.testTransportFailure()
        let canceledRetry = canceled.scheduled.last!.fire
        canceled.model.disconnectDevice(); canceledRetry(); canceled.model.becameInactive(); canceled.model.becameActive()
        check("explicit disconnect or canceled pairing stays disconnected across timers and foreground", canceled.connections.count == 1 && !canceled.model.connecting)
        canceled.model.connect(); canceled.model.testTransportFailure()
        let backgroundRetry = canceled.scheduled.last!.fire
        canceled.model.becameInactive(); backgroundRetry()
        check("background cancels retries without opening transport", canceled.connections.count == 2 && !canceled.model.connecting)
        canceled.model.becameActive(); canceled.model.testTransportFailure()
        let desktopRetry = canceled.scheduled.last!.fire
        canceled.model.setDesktopControlEnabled(false); desktopRetry(); canceled.model.becameActive()
        check("selecting TV prevents stale desktop retries and foreground fallback", canceled.connections.count == 3 && !canceled.model.connecting)

        let rejected = ReconnectFixture(selectedLibrary); rejected.model.becameActive()
        rejected.model.testTransportFailure(retryable: false)
        rejected.model.becameInactive(); rejected.model.becameActive()
        check("authentication or protocol rejection cannot cause a reconnect loop even across foreground", rejected.scheduled.isEmpty && rejected.connections.count == 1)
        rejected.model.acceptPairing(pcB)
        check("explicitly repairing a rejected pairing allows a fresh attempt", rejected.connections == [new, new])
        check("connection refused is recoverable", ControllerModel.testMayRetry(.cannotConnectToHost))
        check("network disconnect is recoverable", ControllerModel.testMayRetry(.networkConnectionLost))
        check("TLS pin failure is never retried", !ControllerModel.testMayRetry(.cancelled, diagnostic: "TLS_PIN"))
        check("certificate validation failure is never retried", !ControllerModel.testMayRetry(.serverCertificateUntrusted))
        check("HTTP unauthorized cannot loop", !ControllerModel.testMayRetry(.badServerResponse, status: 401))
        check("HTTP forbidden cannot loop", !ControllerModel.testMayRetry(.badServerResponse, status: 403))
        check("old phone socket occupying the receiver slot is retried", ControllerModel.testMayRetry(.badServerResponse, status: 409))
        check("receiver temporarily unavailable can recover", ControllerModel.testMayRetry(.badServerResponse, status: 503))
        check("authenticated receiver shutdown can reconnect", ControllerModel.testMayRetry(.unknown, closeCode: .goingAway, authenticated: true))
        check("authenticated normal closure can reconnect", ControllerModel.testMayRetry(.unknown, closeCode: .normalClosure, authenticated: true))
        check("unidentified clean closure cannot establish retry trust", !ControllerModel.testMayRetry(.unknown, closeCode: .normalClosure))
        check("clean closure never overrides TLS rejection", !ControllerModel.testMayRetry(.unknown, diagnostic: "TLS_PIN", closeCode: .goingAway, authenticated: true))
        check("clean closure never overrides a URLSession certificate error", !ControllerModel.testMayRetry(.serverCertificateUntrusted, closeCode: .normalClosure, authenticated: true))
        check("clean closure never overrides forbidden response", !ControllerModel.testMayRetry(.unknown, status: 403, closeCode: .goingAway, authenticated: true))
        check("abrupt receiver restart with socket reset can reconnect", ControllerModel.testMayRetryPOSIX(ECONNRESET))
        check("closed receiver socket can reconnect", ControllerModel.testMayRetryPOSIX(ENOTCONN))
        check("unrecognized permission error is not a network retry", !ControllerModel.testMayRetryPOSIX(EACCES))

        let inputs = ReconnectFixture(selectedLibrary); inputs.model.becameActive(); inputs.model.testConnectionEstablished()
        inputs.model.draft = "Only send this once"
        inputs.model.sendText()
        check("fixture records one uncertain text delivery", inputs.frames == ["text"] && inputs.model.textDelivery == .uncertain)
        inputs.model.move(dx: 12, dy: 8); inputs.model.scroll(dy: 3)
        inputs.model.testTransportFailure(); inputs.scheduled.last!.fire(); inputs.model.testConnectionEstablished()
        inputs.model.testFlushMovement(); inputs.model.sendText()
        check("reconnect never replays queued gestures or unconfirmed text", inputs.frames == ["text"] && inputs.model.textDelivery == .uncertain && inputs.model.draft == "Only send this once")

        let textTimeout = ReconnectFixture(selectedLibrary, recordingWire: true)
        textTimeout.model.becameActive(); textTimeout.model.testConnectionEstablished()
        textTimeout.model.draft = "Unconfirmed pending text"; textTimeout.model.sendText()
        let expiredText = textTimeout.model.testCommandTimeout("text")
        check("wire fixture exercises the real pending command path", textTimeout.frames == ["text"] && textTimeout.model.textDelivery == .sending)
        expiredText()
        check("actual command timeout completes text as uncertain and schedules recovery", textTimeout.model.textDelivery == .uncertain && !textTimeout.model.connected && textTimeout.scheduled.count == 1)
        textTimeout.scheduled.last!.fire(); textTimeout.model.testConnectionEstablished(); expiredText(); textTimeout.model.sendText()
        check("expired command callback cannot affect reconnected transport or replay text", textTimeout.model.connected && textTimeout.frames == ["text"] && textTimeout.model.textDelivery == .uncertain)

        let dragTimeout = ReconnectFixture(selectedLibrary, recordingWire: true)
        dragTimeout.model.becameActive(); dragTimeout.model.testConnectionEstablished(); dragTimeout.model.setDragging(true)
        dragTimeout.model.testCommandTimeout("button")()
        check("drag-down timeout cannot cancel the reconnect through its safety completion", !dragTimeout.model.dragging && !dragTimeout.model.connected && dragTimeout.scheduled.count == 1)
        dragTimeout.scheduled.last!.fire(); dragTimeout.model.testConnectionEstablished()
        check("drag timeout recovery never replays the held button", dragTimeout.model.canControl && dragTimeout.frames == ["button"])
        dragTimeout.model.setDragging(true); dragTimeout.model.testAcknowledgeCommand("button")
        dragTimeout.model.move(dx: 3, dy: 2); dragTimeout.model.testFlushMovement(); dragTimeout.model.setDragging(false)
        dragTimeout.model.testCommandTimeout("move")()
        check("final drag-move timeout clears release state and still schedules reconnect", !dragTimeout.model.dragging && !dragTimeout.model.canControl && dragTimeout.scheduled.count == 2)
        dragTimeout.scheduled.last!.fire(); dragTimeout.model.testConnectionEstablished()
        dragTimeout.model.setDragging(true); dragTimeout.model.testAcknowledgeCommand("button"); dragTimeout.model.setDragging(false)
        dragTimeout.model.testCommandTimeout("button")()
        check("drag-release button timeout cannot suppress reconnection", !dragTimeout.model.connected && dragTimeout.scheduled.count == 3)
        dragTimeout.scheduled.last!.fire(); dragTimeout.model.testConnectionEstablished()
        check("recovery clears final drag-release gate", dragTimeout.model.canControl && !dragTimeout.model.dragging)
        print("Pairing attempt tests: \(passed) passed")
    }
}
