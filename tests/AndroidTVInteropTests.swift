import Foundation

/// A real URLSession/PinnedSessionDelegate peer for the production Java receiver.
/// Fixture storage and the receiver Input driver are in memory. There is no UI or OS input.
private struct InteropFixture: Decodable { let qr: String }
private struct InteropStats: Decodable {
    struct Action: Decodable { let type: String; let dx: Double?; let dy: Double?; let key: String?; let app: String? }
    let paired: Bool
    let actions: [Action]
    let snapshots: Int
    let disconnects: Int
    let connected: Bool
    let serverRunning: Bool
    let serverStarts: Int
}
private final class InteropMemoryStore: AndroidTVPairingStorage {
    var value: AndroidTVPairing?
    var writes = 0
    func read() -> AndroidTVPairing? { value }
    func write(_ pairing: AndroidTVPairing) throws { value = pairing; writes += 1 }
    func delete() throws { value = nil }
}
@MainActor private final class SocketProbe {
    let socket = AndroidTVNetworkSocket()
    var failures = 0
    var texts = 0
    init() {
        socket.onFailure = { [weak self] _ in self?.failures += 1 }
        socket.onText = { [weak self] _ in self?.texts += 1 }
    }
}
@main @MainActor private struct AndroidTVInteropTests {
    static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    }
    static func pause(_ milliseconds: UInt64) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
    static func wait(_ label: String, until condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await pause(20)
        }
        require(false, "timeout: \(label)")
    }
    static func stats(_ dir: URL) -> InteropStats? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("stats.json")) else { return nil }
        return try? JSONDecoder().decode(InteropStats.self, from: data)
    }
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = try JSONDecoder().decode(InteropFixture.self, from: Data(contentsOf: dir.appendingPathComponent("fixture.json")))
        let pairing = try AndroidTVPairing.parse(fixture.qr)
        let wrongPin = SocketProbe()
        wrongPin.socket.open(AndroidTVPairing(host: pairing.host, port: pairing.port,
            token: pairing.token, fingerprint: String(repeating: pairing.fingerprint.first == "a" ? "b" : "a", count: 64)))
        await wait("wrong certificate rejected") { wrongPin.failures > 0 }
        require(wrongPin.texts == 0, "incorrect pin never reaches hello")
        require(stats(dir)?.paired == false && stats(dir)?.actions.isEmpty == true, "pin rejection does not consume QR or perform input")
        wrongPin.socket.close()
        print("PASS Swift certificate pin rejects before Java pairing authorization")

        let wrongToken = SocketProbe()
        wrongToken.socket.open(pairing.replacingToken(String(repeating: "x", count: 43)))
        await wait("wrong bearer rejected") { wrongToken.failures > 0 }
        wrongToken.socket.close()
        await wait("controller slot released") { stats(dir)?.connected == false }
        require(wrongToken.texts == 0 && stats(dir)?.paired == false, "wrong bearer does not consume QR")
        print("PASS Java rejects an unauthorized Swift WebSocket upgrade")

        let store = InteropMemoryStore()
        let controller = AndroidTVController(storage: store)
        controller.pair(fixture.qr)
        await wait("native controller hello") { controller.phase == .ready || controller.phase == .failed }
        if controller.phase == .failed { fputs("Native controller diagnostic: \(controller.notice)\n", stderr) }
        require(controller.canControl && store.writes == 1, "real Java hello enables native controller and persists once")
        require(store.value?.token != pairing.token && store.value?.fingerprint == pairing.fingerprint, "bootstrap replaced over pinned TLS")
        print("PASS real Swift controller/Java hello and one-time credential rotation")

        controller.move(dx: 12, dy: -3)
        controller.click()
        controller.scroll(dy: -9)
        controller.key(.back)
        controller.key(.home)
        await wait("five acknowledged native input actions") { (stats(dir)?.actions.count ?? 0) >= 5 || controller.phase == .failed }
        let sent = stats(dir)!.actions
        require(controller.canControl && sent.map(\.type) == ["move", "click", "scroll", "key", "key"], "native queue and Java ACKs preserve action order")
        require(sent[0].dx == 12 && sent[0].dy == -3 && sent[2].dy == 9 && sent[3].key == "back" && sent[4].key == "home", "wire movement, downward scroll and buttons match receiver actions")
        controller.pauseInput(); controller.click(); await pause(200)
        require(stats(dir)?.actions.count == 5, "paused native input is not sent")
        controller.resumeInput()
        print("PASS native move/click/scroll/Back/Home and serial Java acknowledgments")

        try Data().write(to: dir.appendingPathComponent("block-input"))
        await wait("heartbeat detects missing receiver permission") { controller.phase == .ready && !controller.canControl }
        require(controller.status?.inputStatus == .accessibilityRequired, "real ping reports inaccessible receiver")
        controller.click(); await pause(100)
        require(stats(dir)?.actions.count == 5, "revoked receiver permission blocks native input")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("block-input"))
        await wait("heartbeat observes receiver permission restored") { controller.canControl }
        await wait("fixture publishes heartbeat snapshots") { (stats(dir)?.snapshots ?? 0) >= 3 }
        require((stats(dir)?.snapshots ?? 0) >= 3, "real Java ping snapshots exercised")
        print("PASS application heartbeat refreshes permissions across real TLS/WebSocket")

        controller.disconnect()
        await wait("first controller disconnect") { stats(dir)?.connected == false }
        let consumedQR = SocketProbe(); consumedQR.socket.open(pairing)
        await wait("consumed QR cannot reconnect") { consumedQR.failures > 0 }
        consumedQR.socket.close()
        await wait("consumed QR rejection releases slot") { stats(dir)?.connected == false }
        require(consumedQR.texts == 0, "bootstrap is one-use")
        controller.reconnect()
        await wait("native persistent credential resumes") { controller.phase == .ready || controller.phase == .failed }
        require(controller.canControl && store.writes == 1 && stats(dir)?.actions.count == 5, "reconnect authenticates without rotation or replay")
        let second = SocketProbe(); second.socket.open(store.value!)
        await wait("second controller rejected") { second.failures > 0 }
        require(second.texts == 0 && controller.canControl, "single-controller rejection preserves active session")
        second.socket.close()
        controller.key(.back)
        await wait("resumed native input") { stats(dir)?.actions.count == 6 || controller.phase == .failed }
        require(stats(dir)?.actions.last?.key == "back" && controller.canControl, "current controller remains usable")

        let savedBeforeRestart = store.value
        let selectedBeforeRestart = controller.selectedDeviceID
        try Data().write(to: dir.appendingPathComponent("stop-after-action"))
        try Data().write(to: dir.appendingPathComponent("hold-next-action"))
        controller.click()
        controller.move(dx: 111, dy: 222)
        controller.key(.home)
        await wait("receiver stops before ambiguous click acknowledgement") { stats(dir)?.serverRunning == false }
        await wait("native controller observes real receiver shutdown") { controller.phase == .failed }
        require(stats(dir)?.actions.count == 7 && stats(dir)?.actions.last?.type == "click",
            "only the unacknowledged click reached the old receiver; queued motion and key did not")
        // Input made while disconnected must not become a future action either.
        controller.move(dx: -333, dy: -444); controller.scroll(dy: 81); controller.click()
        require(store.value == savedBeforeRestart && store.writes == 1,
            "shutdown preserves the selected saved credential without reenrollment")
        try Data().write(to: dir.appendingPathComponent("restart-server"))
        await wait("automatic recovery to restarted receiver") {
            stats(dir)?.serverStarts == 2 && controller.canControl
        }
        await pause(200)
        require(stats(dir)?.actions.count == 7 && store.value == savedBeforeRestart && store.writes == 1,
            "real automatic reconnect uses the saved pin and token without replaying ambiguous or queued input")
        require(controller.selectedDeviceID == selectedBeforeRestart && controller.savedDevices.count == 1,
            "automatic recovery preserves the selected device and never creates a duplicate")
        controller.key(.home)
        await wait("fresh action after automatic recovery") { stats(dir)?.actions.count == 8 }
        require(stats(dir)?.actions.last?.key == "home" && controller.canControl,
            "fresh manual input works after receiver replacement")
        print("PASS real receiver restart and automatic saved-credential recovery; no ambiguous, queued or offline input replay")
        require(controller.canLaunchApp(.youtube) && controller.canLaunchApp(.netflix),
                "actual Java hello advertises the fixed app shortcuts")
        require(controller.launchApp(.youtube), "YouTube shortcut accepted")
        await wait("YouTube launch acknowledged") { stats(dir)?.actions.count == 9 || controller.phase == .failed }
        require(controller.launchApp(.netflix), "Netflix shortcut accepted")
        await wait("both app launches acknowledged") { stats(dir)?.actions.count == 10 || controller.phase == .failed }
        require(controller.canControl && stats(dir)?.actions.suffix(2).map(\.type) == ["app_launch", "app_launch"] &&
                stats(dir)?.actions.suffix(2).compactMap(\.app) == ["youtube", "netflix"],
                "Swift fixed app identifiers cross real TLS and receive fresh Java capability ACKs")
        print("PASS advertised YouTube/Netflix launch commands across real Swift/Java transport; fixture launches no apps")
        controller.disconnect()
        await wait("all controllers closed") { stats(dir)?.connected == false }
        print("PASS persistent reconnect, consumed-QR rejection, single-controller admission and no replay")
        print("Swift/Java interop passed with actual native pinned transport; injected receiver input only, no TV, Keychain or desktop input.")
    }
}
