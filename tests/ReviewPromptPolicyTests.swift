import Foundation

@main struct ReviewPromptPolicyTests {
    static func main() {
        var count = 0
        func check(_ label: String, _ value: @autoclosure () -> Bool) {
            guard value() else { fatalError("FAIL: \(label)") }
            count += 1
        }
        let suite = "sofatap.review-prompt-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let policy = ReviewPromptPolicy(defaults: defaults, calendar: calendar)
        let day: TimeInterval = 86_400
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        policy.noteLaunch(now: t0)
        check("fresh install never asks", !policy.shouldRequest(now: t0, version: "1.0.3"))

        policy.recordSession(start: t0, end: t0.addingTimeInterval(30))
        policy.recordSession(start: t0, end: t0.addingTimeInterval(59))
        check("short sessions do not count", !policy.shouldRequest(now: t0.addingTimeInterval(10 * day), version: "1.0.3"))

        policy.recordSession(start: t0, end: t0.addingTimeInterval(120))
        policy.recordSession(start: t0.addingTimeInterval(200), end: t0.addingTimeInterval(400))
        policy.recordSession(start: t0.addingTimeInterval(500), end: t0.addingTimeInterval(700))
        check("three sessions on one day are not enough", !policy.shouldRequest(now: t0.addingTimeInterval(10 * day), version: "1.0.3"))

        policy.recordSession(start: t0.addingTimeInterval(day), end: t0.addingTimeInterval(day + 90))
        check("waits three days after first use", !policy.shouldRequest(now: t0.addingTimeInterval(2 * day), version: "1.0.3"))
        check("asks after real use on two days", policy.shouldRequest(now: t0.addingTimeInterval(3 * day), version: "1.0.3"))
        check("empty version never asks", !policy.shouldRequest(now: t0.addingTimeInterval(3 * day), version: ""))

        policy.markRequested(version: "1.0.3")
        check("asks at most once per version", !policy.shouldRequest(now: t0.addingTimeInterval(30 * day), version: "1.0.3"))
        check("a new version may ask again", policy.shouldRequest(now: t0.addingTimeInterval(30 * day), version: "1.0.4"))

        let late = ReviewPromptPolicy(defaults: defaults, calendar: calendar)
        late.noteLaunch(now: t0.addingTimeInterval(100 * day))
        check("first use is recorded only once", late.shouldRequest(now: t0.addingTimeInterval(30 * day), version: "1.0.4"))

        print("PASS \(count) review prompt policy checks; no StoreKit or device access")
    }
}
