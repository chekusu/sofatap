import Foundation
import Network

/// Finds a scoped peer service. Discovery is only routing: the connection must
/// still authenticate the original pairing certificate and bearer token.
/// Keep this owner alive until the transport closes; a scoped Bonjour endpoint
/// can stop resolving if its browser is cancelled immediately after discovery.
@MainActor final class PeerTransportDiscovery {
    /// Absence of a service/scoped peer interface is determined by browsing;
    /// platform metadata only skips receivers that cannot advertise this route.
    static func shouldAttempt(platform: String?, defaults: UserDefaults = .standard) -> Bool {
        guard platform == nil || platform == "macos" else { return false }
        return defaults.object(forKey: "SofatapPeerTransportEnabled") == nil ||
            defaults.bool(forKey: "SofatapPeerTransportEnabled")
    }

    static let serviceType = "_sofatap-peer._tcp"
    private let serviceName: String
    private let interfacePrefix: String
    private var browser: NWBrowser?
    private var completion: CheckedContinuation<NWEndpoint, Error>?
    private var deadline: Task<Void, Never>?
    private var availabilityCallback: ((Bool) -> Void)?
    private var started = false
    private var stopped = false
    var isBrowsing: Bool { browser != nil }

    init(serviceName: String, interfacePrefix: String = "awdl") {
        self.serviceName = serviceName
        self.interfacePrefix = interfacePrefix
    }

    static func serviceName(fingerprint: String) -> String {
        // Bonjour labels are limited to 63 bytes. This public routing hint is
        // not an authenticator; the full certificate pin is checked by TLS.
        "Sofatap-" + fingerprint.lowercased().prefix(40)
    }

    /// Observe current scoped advertisements without opening a control session.
    /// This remains independent of the chosen route so Wi-Fi users can switch back.
    func monitorAvailability(_ callback: @escaping (Bool) -> Void) {
        guard !started, !stopped else { callback(false); return }
        started = true
        availabilityCallback = callback
        callback(false)
        startBrowser()
    }

    func find(timeout: Duration = .seconds(3)) async throws -> NWEndpoint {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let endpoint: NWEndpoint = try await withCheckedThrowingContinuation { continuation in
                guard !started, !stopped else {
                    continuation.resume(throwing: URLError(.cancelled)); return
                }
                started = true
                completion = continuation
                startBrowser()
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.stop(error: URLError(.timedOut))
                }
            }
            try Task.checkCancellation()
            return endpoint
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    // Both route selection and UI availability use exactly the same identity
    // and interface rules. Keep the browser alive after resolving a route.
    private func scopedEndpoint(_ result: NWBrowser.Result) -> NWEndpoint? {
        guard case .service(let name, let type, let domain, _) = result.endpoint,
              name == serviceName,
              let interface = result.interfaces.first(where: { $0.name.hasPrefix(interfacePrefix) }) else { return nil }
        return .service(name: name, type: type, domain: domain, interface: interface)
    }

    private func startBrowser() {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                switch state {
                case .failed(let error): self.stop(error: error)
                case .waiting: self.availabilityCallback?(false)
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                let endpoint = results.lazy.compactMap { self.scopedEndpoint($0) }.first
                self.availabilityCallback?(endpoint != nil)
                guard let endpoint, let callback = self.completion else { return }
                self.completion = nil
                self.deadline?.cancel(); self.deadline = nil
                callback.resume(returning: endpoint)
            }
        }
        browser.start(queue: .main)
    }

    func stop() { stop(error: URLError(.cancelled)) }

    private func stop(error: Error) {
        guard !stopped else { return }; stopped = true
        availabilityCallback?(false); availabilityCallback = nil
        deadline?.cancel(); deadline = nil
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel(); browser = nil
        let callback = completion; completion = nil
        callback?.resume(throwing: error)
    }
}
