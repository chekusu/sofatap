import Foundation

// Actual native controller and relay; no helper, window, or desktop input.
@main struct ReceiverPeerLifecycleTests {
    @MainActor static func main() async throws {
        let controller = ReceiverController()
        defer { controller.testHelperStopped() }
        let pin = String(repeating: "a", count: 64)
        func state(pairings: Bool, port: Int = 53319, fingerprint: String? = nil) throws -> ReceiverState {
            let uri = "sofatap://pair?host=192.0.2.1&port=53319&token=\(String(repeating: "D", count: 43))&fingerprint=\(pin)"
            let entries: [[String: Any]] = pairings ? [["host": "192.0.2.1", "uri": uri,
                "qrPng": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/F1kAAAAASUVORK5CYII="]] : []
            return try ReceiverState.decode(JSONSerialization.data(withJSONObject: [
                "type": "state", "name": "Test", "platform": "macos", "inputStatus": "ready",
                "dryRun": true, "connected": true, "pairings": entries,
                "peer": ["port": port, "fingerprint": fingerprint ?? pin]]))
        }
        func ready() async throws {
            for _ in 0..<200 {
                if controller.testPeerReady { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            fatalError("relay did not become ready")
        }
        controller.testPeerState(try state(pairings: true))
        try await ready()
        let original = controller.testPeerIdentity
        controller.testPeerState(try state(pairings: false))
        guard controller.testPeerIdentity == original, controller.testPeerReady else {
            fatalError("empty LAN pairings stopped healthy peer relay")
        }
        controller.testPeerState(try state(pairings: false, port: 53320))
        try await ready()
        guard controller.testPeerKey == "53320:" + pin else { fatalError("port change reused stale relay") }
        controller.testPeerState(try state(pairings: false, port: 53320, fingerprint: String(repeating: "b", count: 64)))
        try await ready()
        guard controller.testPeerKey == "53320:" + String(repeating: "b", count: 64) else { fatalError("certificate change reused stale relay") }
        controller.testHelperStopped()
        guard controller.testPeerIdentity == nil else { fatalError("helper shutdown left relay running") }
        controller.testPeerState(try state(pairings: false))
        try await ready()
        guard controller.testPeerIdentity != nil else { fatalError("addressless helper cannot start peer relay") }
        for invalid in [0, 65536] {
            do { _ = try state(pairings: false, port: invalid); fatalError("invalid peer port accepted") }
            catch {}
        }
        do { _ = try state(pairings: false, fingerprint: "bad"); fatalError("invalid peer fingerprint accepted") }
        catch {}
        print("PASS native peer lifecycle: empty LAN, port/certificate rotation, shutdown, addressless start, validation")
    }
}
