import Foundation

/// Half-millisecond buckets, bounded independently of session length. Contains no
/// locations, deltas, device addresses, tokens or user text.
struct PointerTimingHistogram {
    private var buckets = [Int](repeating: 0, count: 801)
    private(set) var count = 0
    private(set) var maximum = 0.0
    private var total = 0.0
    mutating func record(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        buckets[Int(min(800, ceil(milliseconds * 2)))] += 1
        count += 1
        total += milliseconds
        maximum = max(maximum, milliseconds)
    }
    func percentile(_ fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let target = max(1, Int(ceil(Double(count) * min(1, max(0, fraction)))))
        var cumulative = 0
        for (index, amount) in buckets.enumerated() {
            cumulative += amount
            if cumulative >= target { return Double(index) / 2 }
        }
        return maximum
    }
    var summary: [String: Double] {
        ["count": Double(count), "meanMs": count == 0 ? 0 : total / Double(count),
         "p50Ms": percentile(0.5), "p95Ms": percentile(0.95), "p99Ms": percentile(0.99), "maxMs": maximum]
    }
}

#if DEBUG
import UIKit

/// Development-only numeric profiling. Snapshots are debounced and written off
/// the main thread. Release builds do not collect or write these diagnostics.
@MainActor final class PointerTiming {
    static let shared = PointerTiming()
    private var histograms: [String: PointerTimingHistogram] = [:]
    private var counters: [String: Int] = [:]
    private var previous: [String: Double] = [:]
    private var scheduled = false
    private var outputSequence = 0
    private let writer = DispatchQueue(label: "Sofatap pointer timing", qos: .utility)

    func resetPulse(_ name: String) { previous.removeValue(forKey: name) }
    func pulse(_ name: String, at time: Double = ProcessInfo.processInfo.systemUptime) {
        if let old = previous[name], time > old, time - old < 1 { sample(name, seconds: time - old) }
        previous[name] = time
    }
    func sample(_ name: String, seconds: Double) {
        histograms[name, default: PointerTimingHistogram()].record(milliseconds: seconds * 1000)
        schedule()
    }
    func count(_ name: String) { counters[name, default: 0] += 1; schedule() }
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.scheduled = false
            self.outputSequence += 1
            let snapshot: [String: Any] = ["schema": 1, "sequence": self.outputSequence,
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "metrics": self.histograms.mapValues(\.summary), "counters": self.counters]
            guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted]),
                  let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = directory.appendingPathComponent("pointer-timing.json")
            self.writer.async { try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]) }
        }
    }
}
#endif
