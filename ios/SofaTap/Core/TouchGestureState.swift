import Foundation

/// Pure touch semantics. UIKit supplies monotonic timestamps and schedules `nextDeadline`.
/// No mouse input is sent by this type, which also makes cancellation/timing testable.
struct TouchGestureState {
    enum Profile: Equatable { case desktop, tvPointer }
    /// Invisible halves of the pad, supplied from the native view's actual bounds.
    enum Region: Equatable { case left, right }
    struct Point: Equatable {
        var x: Double
        var y: Double
        func distance(to other: Self) -> Double { hypot(x - other.x, y - other.y) }
    }
    enum Action: Equatable {
        case move(Double, Double), leftClick, rightClick, dragging(Bool), scroll(Double)
        case shortcut(GestureAction)
    }
    private enum Mode { case idle, one, multi, suppressed }
    static let holdDuration = 0.300
    static let doubleTapInterval = 0.280
    static let stationaryMovementTolerance = 7.0
    private var movementTolerance: Double {
        profile == .desktop && mode == .one && configuration.action(for: .oneFingerMove) == .movePointer
            ? 3 : Self.stationaryMovementTolerance
    }
    private let doubleTapDistance = 32.0
    private let multiTapDuration = 0.250
    private var mode = Mode.idle
    private var origin = Point(x: 0, y: 0)
    private var previous = Point(x: 0, y: 0)
    private var contactStart = 0.0
    private var contactCount = 0
    private var peakContactCount = 0
    private var multiTapEligible = false
    private var tailOriginKnown = false
    private var holdDeadline: Double?
    private var moved = false
    private var secondTap = false
    private var tapRegion: Region?
    private var suppressLiftClick = false
    private var pendingTap: (point: Point, region: Region?, deadline: Double)?
    private(set) var isDragging = false
    private(set) var profile: Profile
    private(set) var configuration: GestureConfiguration

    init(profile: Profile = .desktop) {
        self.init(profile: profile, configuration: GestureConfiguration(
            preset: .sofatap, target: profile == .desktop ? .computer : .television))
    }

    init(profile: Profile = .desktop, configuration: GestureConfiguration) {
        self.profile = profile
        self.configuration = configuration.sanitized(for: profile == .desktop ? .computer : .television)
    }

    /// Dispatch the returned cancellation to the old target before replacing its callbacks.
    /// The owner stores computer and television preferences separately and supplies the new
    /// target's full configuration when reconnecting; this compatibility API restores defaults.
    mutating func changeProfile(to profile: Profile) -> [Action] {
        guard self.profile != profile else { return [] }
        let actions = cancel()
        self = Self(profile: profile)
        return actions
    }

    /// A setting change must never finish a gesture using the new mapping or leave a button held.
    mutating func changeConfiguration(to configuration: GestureConfiguration) -> [Action] {
        let next = configuration.sanitized(for: profile == .desktop ? .computer : .television)
        guard self.configuration != next else { return [] }
        let actions = cancel()
        self.configuration = next
        return actions
    }

    var nextDeadline: Double? {
        [holdDeadline, pendingTap?.deadline].compactMap { $0 }.min()
    }

    mutating func begin(at point: Point, count: Int, time: Double, region: Region = .left) -> [Action] {
        guard count > 0 else { return [] }
        if count != 1 || mode != .idle {
            return switchContactCount(count, point: point, time: time)
        }
        var actions = advance(to: time)
        secondTap = false
        if let pendingTap {
            if time < pendingTap.deadline && pendingTap.region == region &&
                pendingTap.point.distance(to: point) <= doubleTapDistance && defersSingle(in: region) {
                secondTap = true
            } else {
                actions += discrete(configuration.action(for: .singleTap))
            }
        }
        pendingTap = nil
        mode = .one
        contactCount = 1
        peakContactCount = 1
        contactStart = time
        origin = point
        previous = point
        moved = false
        tapRegion = region
        holdDeadline = time + configuration.holdDuration
        return actions
    }

    mutating func move(to point: Point, count: Int, time: Double, region: Region = .left) -> [Action] {
        // Apply movement first: a delayed main-run-loop timer must not begin a drag
        // after the finger has already crossed the stationary tolerance.
        guard count > 0 else { return [] }
        if mode == .suppressed {
            if !tailOriginKnown || origin.distance(to: point) > Self.stationaryMovementTolerance { multiTapEligible = false }
            return []
        }
        guard mode != .idle else { return [] }
        if count != contactCount { return switchContactCount(count, point: point, time: time) }
        let dx = point.x - previous.x, dy = point.y - previous.y
        previous = point
        if origin.distance(to: point) > movementTolerance {
            moved = true
            multiTapEligible = false
            holdDeadline = nil
        }
        if mode == .multi {
            guard moved, contactCount == 2 else { return [] }
            return motion(configuration.action(for: .twoFingerMove), dx: dx, dy: dy)
        }
        if tapRegion != region { tapRegion = nil }
        var actions = advance(to: time)
        // Ignore stationary jitter until movement is intentional or drag has started.
        if isDragging {
            if dx != 0 || dy != 0 { actions.append(.move(dx, dy)) }
        } else if moved {
            actions += motion(configuration.action(for: .oneFingerMove), dx: dx, dy: dy)
        }
        return actions
    }

    mutating func end(at point: Point, remainingCount: Int, time: Double, region: Region = .left,
                      remainingPoint: Point? = nil) -> [Action] {
        if remainingCount > 0 {
            // Remember a stationary multi-tap until the last finger lifts, but never
            // reinterpret a partially lifted gesture as pointer motion or a hold.
            let actions: [Action] = isDragging ? [.dragging(false)] : []
            if mode == .multi {
                if origin.distance(to: point) > Self.stationaryMovementTolerance { multiTapEligible = false }
            } else if mode == .suppressed {
                if tailOriginKnown && origin.distance(to: point) > Self.stationaryMovementTolerance { multiTapEligible = false }
            } else {
                multiTapEligible = false
            }
            isDragging = false
            holdDeadline = nil
            pendingTap = nil
            mode = .suppressed
            contactCount = remainingCount
            origin = remainingPoint ?? point
            previous = origin
            tailOriginKnown = remainingPoint != nil
            return actions
        }
        var actions: [Action] = []
        if mode == .one {
            if tapRegion != region { tapRegion = nil }
            if origin.distance(to: point) > movementTolerance { moved = true; holdDeadline = nil }
            actions += advance(to: time)
            if isDragging {
                actions.append(.dragging(false))
            } else if !moved && !suppressLiftClick {
                if secondTap, let tapRegion {
                    let action = configuration.action(for: doubleGesture(in: tapRegion))
                    if action == .none {
                        // Double-tap-and-hold may reserve the second contact even when
                        // ordinary doubles are disabled. A quick pair remains two singles.
                        actions += discrete(configuration.action(for: .singleTap))
                        actions += discrete(configuration.action(for: .singleTap))
                    } else {
                        actions += discrete(action)
                    }
                } else {
                    // Crossing the invisible divider cancels only the double candidate.
                    if secondTap { actions += discrete(configuration.action(for: .singleTap)) }
                    if defersSingle(in: tapRegion) {
                        pendingTap = (point, tapRegion, time + configuration.doubleTapInterval)
                    } else {
                        actions += discrete(configuration.action(for: .singleTap))
                    }
                }
            }
        } else if mode == .multi || mode == .suppressed {
            if multiTapEligible && !moved && time - contactStart <= multiTapDuration &&
                (mode == .suppressed && !tailOriginKnown || origin.distance(to: point) <= Self.stationaryMovementTolerance) {
                let gesture: GestureID? = peakContactCount == 2 ? .twoFingerTap :
                    (peakContactCount == 3 ? .threeFingerTap : nil)
                if let gesture { actions += discrete(configuration.action(for: gesture)) }
            }
        }
        resetContact()
        return actions
    }

    mutating func advance(to time: Double) -> [Action] {
        var actions: [Action] = []
        if let pendingTap, time >= pendingTap.deadline {
            self.pendingTap = nil
            actions += discrete(configuration.action(for: .singleTap))
        }
        if let holdDeadline, time >= holdDeadline, mode == .one, !moved, !suppressLiftClick {
            self.holdDeadline = nil
            pendingTap = nil
            let action = configuration.action(for: secondTap ? .doubleTapHold : .longPress)
            secondTap = false
            suppressLiftClick = true
            if action == .drag {
                isDragging = true
                actions.append(.dragging(true))
            } else {
                actions += discrete(action)
            }
        }
        return actions
    }

    /// Centroids cannot reveal two fingers moving in opposite directions. The native
    /// adapter calls this when any individual contact exceeds the stationary tolerance.
    /// Keep an active drag held; only its eventual release owns the button-up event.
    mutating func invalidateStationaryGestures() {
        moved = true
        multiTapEligible = false
        holdDeadline = nil
    }

    /// Interruption, disabled input and removal all drop deferred clicks and release.
    mutating func cancel() -> [Action] {
        let actions: [Action] = isDragging ? [.dragging(false)] : []
        pendingTap = nil
        resetContact()
        return actions
    }

    private func doubleGesture(in region: Region) -> GestureID {
        region == .left ? .leftDoubleTap : .rightDoubleTap
    }

    private func defersSingle(in region: Region?) -> Bool {
        if configuration.action(for: .doubleTapHold) != .none { return true }
        if let region { return configuration.action(for: doubleGesture(in: region)) != .none }
        return configuration.action(for: .leftDoubleTap) != .none || configuration.action(for: .rightDoubleTap) != .none
    }

    private func discrete(_ action: GestureAction) -> [Action] {
        switch action {
        case .leftClick: return [.leftClick]
        case .rightClick: return [.rightClick]
        case .doubleLeftClick: return [.leftClick, .leftClick]
        case .doubleRightClick: return [.rightClick, .rightClick]
        case .confirm, .back, .home, .toggleKeyboard, .toggleDictation: return [.shortcut(action)]
        case .none, .drag, .movePointer, .scroll: return []
        }
    }

    private func motion(_ action: GestureAction, dx: Double, dy: Double) -> [Action] {
        switch action {
        case .movePointer: return dx == 0 && dy == 0 ? [] : [.move(dx, dy)]
        case .scroll:
            // Natural scrolling drags content with the fingers; the edge scrollbar
            // is a separate gesture and keeps its scrollbar-like direction.
            return dy == 0 ? [] : [.scroll(configuration.naturalScrolling ? dy : -dy)]
        default: return []
        }
    }

    private mutating func switchContactCount(_ count: Int, point: Point, time: Double) -> [Action] {
        guard mode != .suppressed else { multiTapEligible = false; return [] }
        let actions: [Action] = isDragging ? [.dragging(false)] : []
        let canTap = !moved && !isDragging && !suppressLiftClick
        let wasIdle = mode == .idle
        let increased = count > contactCount
        isDragging = false
        holdDeadline = nil
        pendingTap = nil
        secondTap = false
        tapRegion = nil
        if wasIdle { contactStart = time; moved = false; peakContactCount = 0 }
        if (count == 2 || count == 3) && increased {
            mode = .multi
            multiTapEligible = canTap && time - contactStart <= multiTapDuration
            peakContactCount = max(peakContactCount, count)
        } else {
            mode = .suppressed
            multiTapEligible = false
        }
        contactCount = count
        origin = point
        previous = point
        return actions
    }

    private mutating func resetContact() {
        mode = .idle
        contactCount = 0
        peakContactCount = 0
        multiTapEligible = false
        tailOriginKnown = false
        holdDeadline = nil
        isDragging = false
        moved = false
        secondTap = false
        tapRegion = nil
        suppressLiftClick = false
    }
}

/// Desktop-only gain in UIKit points per second. Smooth the speed estimate, never
/// the direction/displacement: stopping creates no tail and reversals are immediate.
/// Kept with touch semantics so native and offscreen adapters share the same code.
struct DesktopPointerMotion {
    private var previousTime: Double?
    private var speed = 0.0

    mutating func reset(at time: Double? = nil) {
        previousTime = time
        speed = 0
    }

    mutating func feed(dx: Double, dy: Double, time: Double) -> (x: Double, y: Double) {
        guard dx.isFinite, dy.isFinite, time.isFinite else { reset(); return (0, 0) }
        guard let previousTime else { reset(at: time); return (dx, dy) }
        let dt = time - previousTime
        guard dt > 0 else { return (0, 0) }
        self.previousTime = time
        guard dt <= 0.12 else { speed = 0; return (dx, dy) }
        let distance = hypot(dx, dy)
        guard distance > 0 else { speed = 0; return (0, 0) }
        speed += (1 - exp(-dt / 0.025)) * (distance / dt - speed)
        // A continuous smoothstep from precise placement to fast cross-screen travel.
        let t = min(1, max(0, (speed - 60) / 540))
        let gain = 1 + 1.2 * t * t * (3 - 2 * t)
        return (dx * gain, dy * gain)
    }
}
