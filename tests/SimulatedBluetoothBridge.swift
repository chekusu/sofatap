import Foundation
import Network

/// Test-only ATT substitute, not a radio emulator. Exercises the production socket
/// pump and bounded BLE byte buffer with real TLS/WSS and tiny packet boundaries.
final class SimulatedBluetoothBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Sofatap BLE test link")
    private let backendPort: UInt16
    private let mtu: Int
    private var listener: NWListener?
    private var pipes: [BluetoothSocketPipe] = []
    private var completion: ((Result<UInt16, Error>) -> Void)?
    private var stopped = false
    init(backendPort: UInt16, mtu: Int) { self.backendPort = backendPort; self.mtu = mtu }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                completion = { continuation.resume(with: $0) }
                do {
                    let params = NWParameters.tcp
                    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    params.acceptLocalOnly = true
                    let listener = try NWListener(using: params); self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self, !self.stopped else { return }
                        if case .ready = state, let port = listener.port {
                            let callback = self.completion; self.completion = nil; callback?(.success(port.rawValue))
                        } else if case .failed(let error) = state { self.finish(error) }
                    }
                    listener.newConnectionHandler = { [weak self] incoming in
                        guard let self, !self.stopped, self.pipes.isEmpty else { incoming.cancel(); return }
                        let outgoing = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.backendPort)!, using: .tcp)
                        let left = BluetoothSocketPipe(incoming, queue: self.queue)
                        let right = BluetoothSocketPipe(outgoing, queue: self.queue)
                        self.pipes = [left, right]
                        self.wire(left, to: right); self.wire(right, to: left)
                        left.start(); right.start()
                    }
                    listener.start(queue: queue)
                } catch { finish(error) }
            }
        }
    }
    private func wire(_ source: BluetoothSocketPipe, to target: BluetoothSocketPipe) {
        source.onClose = { [weak self] in self?.finish(URLError(.networkConnectionLost)) }
        source.onData = { [weak self, weak target] data, resume in
            guard let self, let target, !self.stopped else { return }
            var bytes = BluetoothByteBuffer()
            do { try bytes.append(data); self.deliver(bytes, to: target, completion: resume) }
            catch { self.finish(error) }
        }
    }
    private func deliver(_ bytes: BluetoothByteBuffer, to target: BluetoothSocketPipe, completion: @escaping () -> Void) {
        guard !stopped else { return }
        guard let packet = bytes.next(maximum: mtu) else { completion(); return }
        // Deliberately delay between packets to exercise asynchronous backpressure.
        queue.asyncAfter(deadline: .now() + 0.001) { [weak self, weak target] in
            guard let self, let target, !self.stopped else { return }
            target.write(packet) { [weak self, weak target] success in
                guard let self, let target, !self.stopped else { return }
                guard success else { self.finish(URLError(.networkConnectionLost)); return }
                var next = bytes
                do { try next.consume(packet.count); self.deliver(next, to: target, completion: completion) }
                catch { self.finish(error) }
            }
        }
    }
    func stop() { queue.async { [self] in finish(URLError(.cancelled)) } }
    private func finish(_ error: Error) {
        guard !stopped else { return }; stopped = true
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        pipes.forEach { $0.stop() }; pipes.removeAll()
        let callback = completion; completion = nil; callback?(.failure(error))
    }
}
