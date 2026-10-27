import Foundation
import Network
@main struct PeerTLSBridgeRunner {
    static func main() async throws {
        let suite = "Sofatap-relay-policy-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        guard MacPeerRelay.isEnabled(defaults: defaults) else { fatalError("relay should be available by default") }
        defaults.set(false, forKey: "SofatapPeerTransportEnabled")
        guard !MacPeerRelay.isEnabled(defaults: defaults) else { fatalError("relay override ignored") }
        let cfg = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:String]
        let parts = URLComponents(string:cfg["uri"]!)!
        let fields = Dictionary(uniqueKeysWithValues:parts.queryItems!.map { ($0.name,$0.value!) })
        let mode = CommandLine.arguments[2]
        let pairing = Pairing(host:mode == "bad-hostname" ? "192.0.2.254" : fields["host"]!,port:Int(fields["port"]!)!,fingerprint:mode == "bad-pin" ? String(repeating:"0",count:64) : fields["fingerprint"]!)
        let relay = MacPeerRelay(backendPort: UInt16(pairing.port), serviceName: "Sofatap-test-" + UUID().uuidString.prefix(8))
        guard !relay.isActive else { fatalError("unstarted relay reported active") }
        let relayPort = try await relay.start()
        guard relay.isActive else { fatalError("ready relay reported inactive") }
        defer { relay.stop() }
        if mode == "stopped-relay" {
            relay.stop()
            guard !relay.isActive else { fatalError("stopped relay still reported active") }
            try await Task.sleep(for: .milliseconds(100))
        }
#if SOFATAP_BLE_SIMULATION
        let proxy = SimulatedBluetoothBridge(backendPort: relayPort,
            mtu: Int(ProcessInfo.processInfo.environment["SOFATAP_TEST_BLE_MTU"] ?? "20") ?? 20)
#else
        let proxy = PeerTLSBridge(endpoint:.hostPort(host:"127.0.0.1",port:.init(rawValue:relayPort)!))
#endif
        let port = try await proxy.start()
        defer { proxy.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        let delegate = PinnedSessionDelegate(pairing:pairing, loopbackPort:port)
        let session = URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url:URL(string:"wss://127.0.0.1:\(port)/control")!)
        request.setValue("Bearer " + (mode == "bad-token" ? String(repeating:"x",count:43) : fields["token"]!),forHTTPHeaderField:"Authorization")
        if mode == "stopped-bridge" { proxy.stop(); try await Task.sleep(for:.milliseconds(100)) }
        let socket = session.webSocketTask(with:request)
        let deadline = Task { try? await Task.sleep(for:.seconds(5)); if !Task.isCancelled { socket.cancel(with:.goingAway,reason:nil) } }
        defer { deadline.cancel();socket.cancel(with:.normalClosure,reason:nil) }
        socket.resume()
        do {
            guard case .string(let text) = try await socket.receive(),
                  let hello = try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],
                  hello["dryRun"] as? Bool == true, hello["inputAvailable"] as? Bool == false else { throw URLError(.badServerResponse) }
            guard mode == "valid" else { fatalError("negative fixture unexpectedly connected") }
            let id = UUID().uuidString
            let packet: [String:Any] = ["id":id,"type":"move","dx":1,"dy":0]
            try await socket.send(.string(String(decoding:try JSONSerialization.data(withJSONObject:packet),as:UTF8.self)))
            guard case .string(let reply) = try await socket.receive(),
                  let ack = try JSONSerialization.jsonObject(with:Data(reply.utf8)) as? [String:Any],
                  ack["id"] as? String == id, ack["ok"] as? Bool == true else { throw URLError(.badServerResponse) }
            print("PASS pinned TLS and authenticated WebSocket through fixed relay")
        } catch {
            if mode == "bad-pin", delegate.rejectionReason != "TLS_PIN" { print("FAIL expected TLS_PIN"); exit(1) }
            if mode == "bad-hostname", !(delegate.rejectionReason?.hasPrefix("TLS_VERIFY_") ?? false) { print("FAIL expected hostname verification rejection"); exit(1) }
            if mode == "bad-token", (socket.response as? HTTPURLResponse)?.statusCode != 401 { print("FAIL expected HTTP 401"); exit(1) }
            if mode == "valid" { print("FAIL valid transport: \((error as NSError).code)"); exit(1) }
            print("PASS rejected \(mode)")
        }
    }
}
