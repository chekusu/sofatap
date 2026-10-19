import Foundation
import Network

/// Advertises an opaque peer TCP relay to this receiver's fixed loopback port.
/// TLS, certificate pinning, bearer authentication and input authorization remain
/// in the receiver protocol. The native controller owns and stops this relay.
final class MacPeerRelay: @unchecked Sendable {
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "SofatapPeerTransportEnabled") == nil ||
            defaults.bool(forKey: "SofatapPeerTransportEnabled")
    }

    private let queue = DispatchQueue(label: "Sofatap Mac peer relay")
    private let endpoint: NWEndpoint
    private let serviceName: String
    private var listener: NWListener?
    private var tunnels: [UUID: Tunnel] = [:]
    private var completion: ((Result<UInt16, Error>) -> Void)?
    private var started = false
    private var stopped = false

    init(backendPort: UInt16, serviceName: String) {
        precondition(backendPort > 0)
        self.endpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: backendPort)!)
        self.serviceName = serviceName
    }

    func start() async throws -> UInt16 {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let port = try await startListener()
            try Task.checkCancellation()
            return port
        } onCancel: {
            self.stop()
        }
    }

    private func startListener() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.started, !self.stopped else {
                    continuation.resume(throwing: URLError(.cancelled)); return
                }
                self.started = true
                self.completion = { continuation.resume(with: $0) }
                do {
                    let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
                    let parameters = NWParameters(tls: nil, tcp: tcp)
                    parameters.includePeerToPeer = true
                    let listener = try NWListener(using: parameters)
                    listener.service = .init(name: self.serviceName, type: "_sofatap-peer._tcp")
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self, !self.stopped else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener?.port else { self.finish(URLError(.cannotConnectToHost)); return }
                            let callback = self.completion; self.completion = nil
                            callback?(.success(port.rawValue))
                        case .failed(let error): self.finish(error)
                        case .cancelled: self.finish(URLError(.cancelled))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] incoming in
                        guard let self, !self.stopped, self.tunnels.count < 4 else { incoming.cancel(); return }
                        let id = UUID()
                        let tunnel = Tunnel(incoming: incoming, endpoint: self.endpoint,
                                            queue: self.queue) { [weak self] in self?.tunnels.removeValue(forKey: id) }
                        self.tunnels[id] = tunnel
                        tunnel.start()
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.completion != nil else { return }
                        self.finish(URLError(.timedOut))
                    }
                } catch { self.finish(error) }
            }
        }
    }

    func stop() { queue.async { [self] in self.finish(URLError(.cancelled)) } }

    /// Called by the owner, outside the relay queue. Failed/cancelled listeners
    /// must not be reused just because the receiver certificate is unchanged.
    var isActive: Bool { queue.sync { started && !stopped } }

    private func finish(_ error: Error) {
        guard !stopped else { return }; stopped = true
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let owned = Array(tunnels.values); tunnels.removeAll()
        owned.forEach { $0.stop() }
        let callback = completion; completion = nil; callback?(.failure(error))
    }

    /// Every operation executes on the owner's serial queue. Each direction
    /// reads at most 16 KiB, and waits for send completion before reading again.
    private final class Tunnel: @unchecked Sendable {
        let incoming: NWConnection
        let endpoint: NWEndpoint
        let queue: DispatchQueue
        let onStop: () -> Void
        var outgoing: NWConnection?
        var timeout: DispatchWorkItem?
        var stopped = false
        var relaying = false

        init(incoming: NWConnection, endpoint: NWEndpoint,
             queue: DispatchQueue, onStop: @escaping () -> Void) {
            self.incoming = incoming; self.endpoint = endpoint; self.queue = queue
            self.onStop = onStop
        }
        func start() {
            incoming.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready: self.connect()
                case .failed, .cancelled: self.stop()
                default: break
                }
            }
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            timeout = work; queue.asyncAfter(deadline: .now() + 5, execute: work)
            incoming.start(queue: queue)
        }
        func connect() {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            let connection = NWConnection(to: endpoint, using: parameters)
            outgoing = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    guard !self.relaying else { return }; self.relaying = true
                    self.timeout?.cancel(); self.timeout = nil
                    self.pipe(from: connection, to: self.incoming)
                    self.pipe(from: self.incoming, to: connection)
                case .failed, .cancelled: self.stop()
                default: break
                }
            }
            connection.start(queue: queue)
        }
        func pipe(from source: NWConnection, to destination: NWConnection) {
            guard !stopped else { return }
            source.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
                guard let self, !self.stopped else { return }
                guard error == nil else { self.stop(); return }
                guard let data, !data.isEmpty else {
                    if complete { self.stop() } else { self.pipe(from: source, to: destination) }
                    return
                }
                destination.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.stopped else { return }
                    if error != nil || complete { self.stop() }
                    else { self.pipe(from: source, to: destination) }
                })
            }
        }
        func stop() {
            guard !stopped else { return }; stopped = true
            timeout?.cancel(); timeout = nil
            incoming.stateUpdateHandler = nil; outgoing?.stateUpdateHandler = nil
            incoming.cancel(); outgoing?.cancel(); outgoing = nil
            onStop()
        }
    }
}
