import Foundation
import Network

// Failures to prevent: connecting to another receiver; treating LAN discovery as
// AWDL; cancelled/expired discovery resuming later; cancelling an active browser
// immediately after finding a service (which previously broke scoped routing).
@main struct PeerDiscoveryTests {
    @MainActor static func main() async throws {
        let suite = "Sofatap-peer-policy-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        guard PeerTransportDiscovery.shouldAttempt(platform: "macos", defaults: defaults),
              PeerTransportDiscovery.shouldAttempt(platform: nil, defaults: defaults),
              !PeerTransportDiscovery.shouldAttempt(platform: "windows", defaults: defaults),
              !PeerTransportDiscovery.shouldAttempt(platform: "linux", defaults: defaults) else {
            fatalError("automatic peer policy incorrect")
        }
        defaults.set(false, forKey: "SofatapPeerTransportEnabled")
        guard !PeerTransportDiscovery.shouldAttempt(platform: "macos", defaults: defaults) else {
            fatalError("LAN-only diagnostic override ignored")
        }
        let name = "Sofatap-test-" + UUID().uuidString.prefix(8)
        let listener = try NWListener(using: .tcp)
        listener.service = .init(name: String(name), type: PeerTransportDiscovery.serviceType)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        defer { listener.cancel() }
        let monitor = PeerTransportDiscovery(serviceName: String(name), interfacePrefix: "")
        var availability: [Bool] = []
        monitor.monitorAvailability { availability.append($0) }
        for _ in 0..<100 {
            if availability.contains(true) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard availability.contains(true) else { fatalError("available service did not expose choice") }
        monitor.stop()
        guard availability.last == false else { fatalError("stopping monitor retained availability") }
        let discovery = PeerTransportDiscovery(serviceName: String(name), interfacePrefix: "")
        defer { discovery.stop() }
        let endpoint = try await discovery.find(timeout: .seconds(5))
        guard case .service(let found, _, _, let interface) = endpoint,
              found == name, interface != nil else { fatalError("wrong or unscoped service") }
        // Successful resolution retains the browser until the owner stops it.
        guard discovery.isBrowsing else { fatalError("browser stopped prematurely") }
        discovery.stop()
        guard !discovery.isBrowsing else { fatalError("browser leaked") }
        let missing = PeerTransportDiscovery(serviceName: "missing-" + UUID().uuidString)
        do { _ = try await missing.find(timeout: .milliseconds(100)); fatalError("wrong receiver accepted") }
        catch { guard !missing.isBrowsing else { fatalError("timeout leaked browser") } }
        let wrongInterface = PeerTransportDiscovery(serviceName: String(name), interfacePrefix: "not-an-interface-")
        do { _ = try await wrongInterface.find(timeout: .milliseconds(200)); fatalError("interface restriction bypassed") }
        catch { guard (error as? URLError)?.code == .timedOut else { throw error } }
        let pending = PeerTransportDiscovery(serviceName: "missing-" + UUID().uuidString)
        let pendingTask = Task { try await pending.find(timeout: .seconds(5)) }
        while !pending.isBrowsing { await Task.yield() }
        pendingTask.cancel()
        do { _ = try await pendingTask.value; fatalError("pending cancellation succeeded") }
        catch { guard (error as? URLError)?.code == .cancelled else { throw error } }
        guard !pending.isBrowsing else { fatalError("pending cancellation leaked browser") }
        let cancelled = PeerTransportDiscovery(serviceName: String(name))
        let task = Task { try await cancelled.find(timeout: .seconds(5)) }
        task.cancel()
        do { _ = try await task.value; fatalError("cancelled discovery succeeded") }
        catch {}
        // Cancellation handler cleanup is scheduled onto the main actor.
        await Task.yield()
        guard !cancelled.isBrowsing else { fatalError("cancelled browser leaked") }
        let stopped = PeerTransportDiscovery(serviceName: String(name))
        stopped.stop()
        do { _ = try await stopped.find(timeout: .seconds(1)); fatalError("stopped browser restarted") }
        catch {}
        let disappearing = PeerTransportDiscovery(serviceName: String(name), interfacePrefix: "")
        var isAvailable = false
        disappearing.monitorAvailability { isAvailable = $0 }
        for _ in 0..<60 {
            if isAvailable { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard isAvailable else { fatalError("disappearance fixture not discovered") }
        listener.cancel()
        for _ in 0..<60 {
            if !isAvailable { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !isAvailable else { fatalError("removed service kept selector visible") }
        disappearing.stop()
        print("PASS real Bonjour identity match, scoped endpoint, retained browser, timeout, cancellation and stop")
    }
}
