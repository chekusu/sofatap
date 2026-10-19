import Foundation

// Failure modes: sampling frequency changes gain, reversal coasts, rest drifts,
// long pauses/invalid timestamps spike, a new contact inherits old gain, TV
// thresholds change, and reducing the pointer threshold creates lift clicks.
@main
struct PointerMotionTests {
    static func main() {
        var passed = 0
        func check(_ label: String, _ ok: Bool) {
            guard ok else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            passed += 1
        }
        // Timing diagnostics must be bounded, ignore invalid samples, and report
        // useful quantiles without retaining input coordinates or raw event histories.
        var histogram = PointerTimingHistogram()
        for _ in 0..<95 { histogram.record(milliseconds: 8.3) }
        for _ in 0..<5 { histogram.record(milliseconds: 40) }
        histogram.record(milliseconds: .nan)
        histogram.record(milliseconds: -1)
        check("timing histogram excludes invalid samples", histogram.count == 100)
        check("timing histogram quantiles retain cadence and stalls", histogram.percentile(0.5) == 8.5 && histogram.percentile(0.99) == 40)
        histogram.record(milliseconds: 2000)
        check("timing histogram retains exact max beyond bounded buckets", histogram.maximum == 2000)
        func stroke(hz: Double, speed: Double) -> Double {
            var motion = DesktopPointerMotion()
            motion.reset(at: 0)
            return (1...Int(hz)).reduce(0.0) { total, i in
                total + motion.feed(dx: speed / hz, dy: 0, time: Double(i) / hz).x
            }
        }
        let slow = stroke(hz: 60, speed: 30), fast = stroke(hz: 60, speed: 600)
        check("slow motion retains precise one-to-one gain", abs(slow - 30) < 0.001)
        check("fast motion gains reach", fast > 1000 && fast <= 1320)
        check("60 and 120 Hz produce similar travel", abs(stroke(hz: 120, speed: 600) - fast) / fast < 0.02)
        var motion = DesktopPointerMotion()
        motion.reset(at: 0)
        _ = motion.feed(dx: 10, dy: 0, time: 0.016)
        check("reversal changes direction immediately", motion.feed(dx: -2, dy: 0, time: 0.032).x < 0)
        check("stationary finger has no synthetic tail", motion.feed(dx: 0, dy: 0, time: 0.048).x == 0)
        check("duplicate timestamp cannot move", motion.feed(dx: 2, dy: 0, time: 0.048).x == 0)
        check("long pause restarts at precision gain", motion.feed(dx: 2, dy: 0, time: 1).x == 2)
        motion.reset(at: 2)
        check("new contact does not inherit gain", motion.feed(dx: 0.5, dy: 0, time: 2.02).x == 0.5)
        check("nonfinite movement is rejected", motion.feed(dx: .nan, dy: 0, time: 2.04).x == 0)
        var touch = TouchGestureState()
        _ = touch.begin(at: .init(x: 0, y: 0), count: 1, time: 0)
        check("small desktop move starts before old seven-point threshold", touch.move(to: .init(x: 4, y: 0), count: 1, time: 0.1) == [.move(4, 0)])
        check("short movement never becomes a lift click", touch.end(at: .init(x: 4, y: 0), remainingCount: 0, time: 0.2).isEmpty && touch.advance(to: 1).isEmpty)
        var tv = TouchGestureState(profile: .tvPointer)
        _ = tv.begin(at: .init(x: 0, y: 0), count: 1, time: 0)
        check("TV threshold stays unchanged", tv.move(to: .init(x: 4, y: 0), count: 1, time: 0.1).isEmpty)
        print("Pointer motion: \(passed) checks passed (no OS input)")
    }
}
