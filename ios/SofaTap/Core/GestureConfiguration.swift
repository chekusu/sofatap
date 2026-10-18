import Foundation

/// A recognized gesture, independent of the action assigned to it.
enum GestureID: String, Codable, CaseIterable {
    case singleTap, leftDoubleTap, rightDoubleTap, twoFingerTap, threeFingerTap
    case longPress, doubleTapHold, oneFingerMove, twoFingerMove
}

enum GestureAction: String, Codable, CaseIterable {
    case none, leftClick, rightClick, doubleLeftClick, doubleRightClick, drag
    case movePointer, scroll, confirm, back, home, toggleKeyboard, toggleDictation
}

enum GestureTarget: String, Codable, CaseIterable {
    case computer, television
}

enum GesturePreset: String, Codable, CaseIterable {
    case sofatap, trackpad, pressMenu
}

/// Local preferences only. Receiver capabilities must still gate each action.
struct GestureConfiguration: Codable, Equatable {
    static let defaultHoldDuration = 0.3
    static let defaultDoubleTapInterval = 0.28
    static let defaultPointerSpeed = 1.0
    static let holdDurationRange = 0.2...1.2
    static let doubleTapIntervalRange = 0.15...0.5
    static let pointerSpeedRange = 0.25...3.0

    var bindings: [GestureID: GestureAction]
    var holdDuration: Double = defaultHoldDuration
    var doubleTapInterval: Double = defaultDoubleTapInterval
    /// Multiplies desktop remote movement only; never changes the computer's OS preferences.
    var pointerSpeed: Double = defaultPointerSpeed
    var naturalScrolling = true
    private(set) var target: GestureTarget

    init(preset: GesturePreset = .sofatap, target: GestureTarget = .computer) {
        self.target = target
        bindings = Dictionary(uniqueKeysWithValues: GestureID.allCases.map { ($0, .none) })
        bindings[.singleTap] = .leftClick
        bindings[.oneFingerMove] = .movePointer
        bindings[.twoFingerMove] = .scroll
        switch (target, preset) {
        case (.computer, .sofatap):
            bindings[.leftDoubleTap] = .doubleLeftClick
            bindings[.rightDoubleTap] = .doubleRightClick
            bindings[.longPress] = .drag
            // Legacy Sofatap also starts dragging when the second tap is held.
            bindings[.doubleTapHold] = .drag
        case (.computer, .trackpad):
            bindings[.leftDoubleTap] = .doubleLeftClick
            bindings[.rightDoubleTap] = .doubleLeftClick
            bindings[.twoFingerTap] = .rightClick
            bindings[.longPress] = .drag
            bindings[.doubleTapHold] = .drag
        case (.computer, .pressMenu):
            bindings[.leftDoubleTap] = .doubleLeftClick
            bindings[.rightDoubleTap] = .doubleLeftClick
            bindings[.longPress] = .rightClick
            bindings[.doubleTapHold] = .drag
            bindings[.twoFingerTap] = .confirm
            bindings[.threeFingerTap] = .toggleKeyboard
        case (.television, .sofatap):
            break
        case (.television, .trackpad):
            bindings[.twoFingerTap] = .confirm
            bindings[.longPress] = .back
        case (.television, .pressMenu):
            bindings[.longPress] = .back
            bindings[.twoFingerTap] = .confirm
            bindings[.threeFingerTap] = .home
        }
    }

    func action(for gesture: GestureID) -> GestureAction {
        let action = bindings[gesture] ?? .none
        return Self.allowedActions(for: gesture, target: target).contains(action) ? action : .none
    }

    mutating func setAction(_ action: GestureAction, for gesture: GestureID) {
        bindings[gesture] = Self.allowedActions(for: gesture, target: target).contains(action) ? action : .none
    }

    func sanitized(for target: GestureTarget) -> Self {
        var copy = self
        copy.target = target
        copy.bindings = Dictionary(uniqueKeysWithValues: GestureID.allCases.map { gesture in
            let action = bindings[gesture] ?? .none
            return (gesture, Self.allowedActions(for: gesture, target: target).contains(action) ? action : .none)
        })
        copy.holdDuration = Self.clamp(holdDuration, to: Self.holdDurationRange, fallback: Self.defaultHoldDuration)
        copy.doubleTapInterval = Self.clamp(doubleTapInterval, to: Self.doubleTapIntervalRange, fallback: Self.defaultDoubleTapInterval)
        copy.pointerSpeed = target == .computer
            ? Self.clamp(pointerSpeed, to: Self.pointerSpeedRange, fallback: Self.defaultPointerSpeed)
            : Self.defaultPointerSpeed
        return copy
    }

    static func allowedActions(for gesture: GestureID, target: GestureTarget) -> [GestureAction] {
        switch gesture {
        case .oneFingerMove, .twoFingerMove:
            return [.none, .movePointer, .scroll]
        default:
            if target == .television {
                return [.none, .leftClick, .confirm, .back, .home]
            }
            var actions: [GestureAction] = [.none, .leftClick, .rightClick, .doubleLeftClick, .doubleRightClick]
            if gesture == .longPress || gesture == .doubleTapHold { actions.append(.drag) }
            actions += [.confirm, .back, .toggleKeyboard, .toggleDictation]
            return actions
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case bindings, holdDuration, doubleTapInterval, pointerSpeed, naturalScrolling, target
    }

    private struct BindingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let target = (try? container.decode(GestureTarget.self, forKey: .target)) ?? .computer
        self.init(target: target)
        holdDuration = (try? container.decode(Double.self, forKey: .holdDuration)) ?? Self.defaultHoldDuration
        doubleTapInterval = (try? container.decode(Double.self, forKey: .doubleTapInterval)) ?? Self.defaultDoubleTapInterval
        pointerSpeed = (try? container.decode(Double.self, forKey: .pointerSpeed)) ?? Self.defaultPointerSpeed
        naturalScrolling = (try? container.decode(Bool.self, forKey: .naturalScrolling)) ?? true
        if let values = try? container.nestedContainer(keyedBy: BindingKey.self, forKey: .bindings) {
            for key in values.allKeys {
                guard let gesture = GestureID(rawValue: key.stringValue) else { continue }
                let rawAction = try? values.decode(String.self, forKey: key)
                // New or malformed actions are disabled rather than replaced by a click.
                bindings[gesture] = rawAction.flatMap(GestureAction.init(rawValue:)) ?? GestureAction.none
            }
        } else if container.contains(.bindings) {
            // A damaged bindings object must never unexpectedly trigger input.
            bindings = Dictionary(uniqueKeysWithValues: GestureID.allCases.map { ($0, .none) })
        }
        self = sanitized(for: target)
    }

    func encode(to encoder: Encoder) throws {
        let safe = sanitized(for: target)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(safe.target, forKey: .target)
        try container.encode(safe.holdDuration, forKey: .holdDuration)
        try container.encode(safe.doubleTapInterval, forKey: .doubleTapInterval)
        try container.encode(safe.pointerSpeed, forKey: .pointerSpeed)
        try container.encode(safe.naturalScrolling, forKey: .naturalScrolling)
        let rawBindings = Dictionary(uniqueKeysWithValues: safe.bindings.map { ($0.key.rawValue, $0.value.rawValue) })
        try container.encode(rawBindings, forKey: .bindings)
    }
}

/// Separate computer and TV profiles prevent a TV preset from changing desktop gestures.
struct GesturePreferences: Codable, Equatable {
    static let schemaVersion = 1
    static let storageKey = "sofatap.gesturePreferences.v1"

    var computer: GestureConfiguration
    var television: GestureConfiguration

    init(computer: GestureConfiguration = .init(target: .computer),
         television: GestureConfiguration = .init(target: .television)) {
        self.computer = computer.sanitized(for: .computer)
        self.television = television.sanitized(for: .television)
    }

    subscript(target: GestureTarget) -> GestureConfiguration {
        get { (target == .computer ? computer : television).sanitized(for: target) }
        set {
            if target == .computer { computer = newValue.sanitized(for: .computer) }
            else { television = newValue.sanitized(for: .television) }
        }
    }

    mutating func reset(preset: GesturePreset = .sofatap, for target: GestureTarget) {
        self[target] = GestureConfiguration(preset: preset, target: target)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    @discardableResult
    func save(to defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, computer, television }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? container.decode(Int.self, forKey: .schemaVersion)) == Self.schemaVersion else {
            self.init()
            return
        }
        self.init(computer: (try? container.decode(GestureConfiguration.self, forKey: .computer)) ?? .init(target: .computer),
                  television: (try? container.decode(GestureConfiguration.self, forKey: .television)) ?? .init(target: .television))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(computer.sanitized(for: .computer), forKey: .computer)
        try container.encode(television.sanitized(for: .television), forKey: .television)
    }
}
