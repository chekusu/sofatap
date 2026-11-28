import Foundation

/// Decides when Sofatap may ask iOS to show the system rating prompt.
///
/// The prompt is only requested after the person has really used the remote:
/// several computer sessions that stayed connected with input available, on at
/// least two different days, and a few days after first use. It is requested
/// at most once per app version and never during a session; iOS itself still
/// decides whether the prompt appears (it shows it at most three times a year).
struct ReviewPromptPolicy {
    static let minimumSessionSeconds: TimeInterval = 60
    static let requiredSessions = 3
    static let requiredDays = 2
    static let minimumDaysSinceFirstUse = 3

    private enum Key {
        static let firstUse = "reviewPrompt.firstUse"
        static let sessions = "reviewPrompt.qualifyingSessions"
        static let days = "reviewPrompt.qualifyingDays"
        static let requestedVersion = "reviewPrompt.requestedVersion"
    }

    let defaults: UserDefaults
    let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    /// Records first use once, so the waiting period starts at first launch.
    func noteLaunch(now: Date) {
        if defaults.object(forKey: Key.firstUse) == nil {
            defaults.set(now.timeIntervalSince1970, forKey: Key.firstUse)
        }
    }

    /// Records a finished computer session. Short sessions do not count.
    func recordSession(start: Date, end: Date) {
        noteLaunch(now: start)
        guard end.timeIntervalSince(start) >= Self.minimumSessionSeconds else { return }
        defaults.set(defaults.integer(forKey: Key.sessions) + 1, forKey: Key.sessions)
        let day = dayKey(end)
        var days = defaults.stringArray(forKey: Key.days) ?? []
        if !days.contains(day) {
            days.append(day)
            // Only the count matters; keep the list small.
            defaults.set(Array(days.suffix(Self.requiredDays * 4)), forKey: Key.days)
        }
    }

    func shouldRequest(now: Date, version: String) -> Bool {
        guard !version.isEmpty, defaults.string(forKey: Key.requestedVersion) != version,
              defaults.integer(forKey: Key.sessions) >= Self.requiredSessions,
              (defaults.stringArray(forKey: Key.days) ?? []).count >= Self.requiredDays,
              let first = defaults.object(forKey: Key.firstUse) as? Double else { return false }
        let waited = now.timeIntervalSince(Date(timeIntervalSince1970: first))
        return waited >= Double(Self.minimumDaysSinceFirstUse) * 86_400
    }

    func markRequested(version: String) {
        defaults.set(version, forKey: Key.requestedVersion)
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
