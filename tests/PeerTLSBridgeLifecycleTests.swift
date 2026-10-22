import Foundation
import Network

// Failure cases: an already-cancelled connection attempt opens a listener;
// cancellation while starting leaks a listener; stop allows a second start;
// stopping an established bridge leaves its listening port reachable.
@main struct PeerTLSBridgeLifecycleTests {
    static func main() async throws {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
        let cancelled = PeerTLSBridge(endpoint: endpoint)
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await cancelled.start()
                cancelled.stop()
                return false
            } catch { return true }
        }
        guard await attempt.value else {
            print("FAIL cancelled start opened a listener"); exit(1)
        }
        let stopped = PeerTLSBridge(endpoint: endpoint)
        stopped.stop()
        do { _ = try await stopped.start(); fatalError("stopped bridge restarted") }
        catch { print("PASS stopped bridge rejects start") }
        let bridge = PeerTLSBridge(endpoint: endpoint)
        let port = try await bridge.start()
        bridge.stop()
        // Calling start again is also a queue barrier after stop.
        do { _ = try await bridge.start(); fatalError("bridge started twice") }
        catch {}
        let reachable = await ListenerProbe(port: port).run()
        guard !reachable else { fatalError("stopped listener still reachable") }
        print("PASS cancelled start, stop-before-start, repeated start and listener cleanup")
    }
}

// All mutable state is confined to queue, including timeout and NW callbacks.
private final class ListenerProbe: @unchecked Sendable {
    let queue = DispatchQueue(label: "bridge lifecycle test")
    let connection: NWConnection
    var completion: CheckedContinuation<Bool, Never>?
    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
    }
    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.completion = continuation
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: self.finish(true)
                    case .failed: self.finish(false)
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 2) { self.finish(false) }
            }
        }
    }
    func finish(_ result: Bool) {
        guard let callback = completion else { return }
        completion = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        callback.resume(returning: result)
    }
}
