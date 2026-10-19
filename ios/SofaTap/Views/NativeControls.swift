import SwiftUI
import UIKit

struct NativeDraftEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var composing: Bool
    @Binding var isFocused: Bool
    var disabled: Bool
    var selection: Binding<NSRange>? = nil
    var onEdit: ((String, NSRange, Bool) -> Void)? = nil
    var preservesFocusWhileLoading = false
    var liveEditing = false
    var control: Control? = nil
    var onEmptyBackspace: (() -> Void)? = nil
    var accessibilityLabelOverride: String? = nil
    var editorAccessibilityLabel: String { accessibilityLabelOverride ?? (liveEditing ? String(localized: "与电脑实时同步的文字和选区") : String(localized: "要发送到电脑的文字草稿")) }

    /// UITextView does not report a text change when Backspace is pressed on an
    /// empty draft. Keep that key distinct from deleting local/marked text.
    final class TextView: UITextView {
        var onEmptyBackspace: (() -> Void)?
        override func deleteBackward() {
            let empty = isEditable && text.isEmpty && selectedRange.length == 0 && markedTextRange == nil
            super.deleteBackward()
            if empty { onEmptyBackspace?() }
        }
    }

    /// Send must read the latest native edit even if UIKit has not delivered its
    /// delegate callback yet. Unconfirmed IME text is never committed implicitly.
    final class Control {
        fileprivate weak var coordinator: Coordinator?
        @discardableResult
        func flushForSend() -> Bool { coordinator?.flushForSend() ?? false }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = TextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = UIColor(white: 0.94, alpha: 1)
        view.tintColor = UIColor(red: 0.722, green: 0.953, blue: 0.816, alpha: 1)
        view.font = .systemFont(ofSize: 19, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 9, bottom: 12, right: 9)
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .default
        view.smartQuotesType = .default
        view.accessibilityLabel = editorAccessibilityLabel
        view.accessibilityIdentifier = "textDraft"
        context.coordinator.textView = view
        context.coordinator.attachControl(control)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.attachControl(control)
        view.accessibilityLabel = editorAccessibilityLabel
        coordinator.synchronizeText(view)
        view.isEditable = !disabled
        // Focus changes after this representable update avoid mutating SwiftUI state
        // from UITextViewDelegate synchronously during a rendering pass.
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator, coordinator.textView === view else { return }
            if coordinator.parent.isFocused && !coordinator.parent.disabled {
                if !view.isFirstResponder && view.window != nil { view.becomeFirstResponder() }
            } else if view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        view.resignFirstResponder()
        view.delegate = nil
        coordinator.attachControl(nil)
        coordinator.textView = nil
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeDraftEditor
        weak var textView: UITextView? {
            willSet { (textView as? TextView)?.onEmptyBackspace = nil }
            didSet {
                lastObservedNativeText = textView?.text ?? ""
                (textView as? TextView)?.onEmptyBackspace = { [weak self] in self?.emptyBackspace() }
            }
        }
        private var lastPublishedSelection: NSRange?
        private var lastPublishedText: String
        private var lastObservedNativeText = ""
        private var pendingExternalText: String?
        private var applyingModelText = false
        private var publishingNativeText = false
        private weak var control: Control?
        init(_ parent: NativeDraftEditor) {
            self.parent = parent
            lastPublishedText = parent.text
            lastPublishedSelection = nil
        }
        func attachControl(_ next: Control?) {
            if control !== next {
                if control?.coordinator === self { control?.coordinator = nil }
                control = next
            }
            next?.coordinator = self
        }
        private func emptyBackspace() {
            guard !parent.disabled, !parent.liveEditing, !parent.composing,
                  !applyingModelText, !publishingNativeText,
                  parent.text.isEmpty, let view = textView,
                  view.text.isEmpty, view.markedTextRange == nil else { return }
            // A deliberate model replacement must render before keyboard input
            // may act on the remote field; never delete behind a retained draft.
            observeExternalText()
            guard pendingExternalText == nil else { return }
            parent.onEmptyBackspace?()
        }
        @discardableResult
        func flushForSend() -> Bool {
            guard !applyingModelText, !publishingNativeText,
                  let view = textView, view.markedTextRange == nil else { return false }
            // This uses the same conflict ordering as normal delegate delivery:
            // explicit model clear/replacement wins, otherwise native text wins.
            publishNativeText(view)
            return view.markedTextRange == nil
        }
        func synchronizeText(_ view: UITextView) {
            guard !applyingModelText, !publishingNativeText else { return }
            observeExternalText()
            // Let IME/keyboard dictation finish its marked range before replacing it.
            guard view.markedTextRange == nil else { return }
            if let replacement = pendingExternalText {
                applyModelText(replacement, to: view)
            } else if view.text == lastObservedNativeText {
                // UIKit changes text before didChange. An unrelated render in that
                // interval must not write the previous binding over the new input.
                applyModelText(lastPublishedText, to: view)
            }
            if let selection = parent.selection?.wrappedValue,
               selection != lastPublishedSelection,
               selection.location >= 0, selection.length >= 0,
               selection.location <= view.text.utf16.count,
               selection.length <= view.text.utf16.count - selection.location {
                applyingModelText = true
                view.selectedRange = selection
                lastPublishedSelection = selection
                applyingModelText = false
            }
        }
        private func observeExternalText() {
            let current = parent.text
            pendingExternalText = current == lastPublishedText ? nil : current
        }
        private func applyModelText(_ text: String, to view: UITextView) {
            applyingModelText = true
            defer { applyingModelText = false }
            if view.text != text {
                let selection = view.selectedRange
                view.text = text
                let count = (text as NSString).length
                view.selectedRange = NSRange(location: min(selection.location, count),
                                             length: min(selection.length, max(0, count - selection.location)))
            }
            lastObservedNativeText = view.text ?? ""
            lastPublishedText = text
            pendingExternalText = nil
        }
        private func publishNativeText(_ view: UITextView) {
            guard !applyingModelText, !publishingNativeText else { return }
            observeExternalText()
            lastObservedNativeText = view.text ?? ""
            if pendingExternalText != nil {
                // A deliberate clear/dictation replacement wins over an older local
                // callback; while marked, retain it until composition finishes.
                synchronizeText(view)
            } else {
                publishingNativeText = true
                lastPublishedText = lastObservedNativeText
                if parent.text != lastPublishedText { parent.text = lastPublishedText }
                publishingNativeText = false
            }
            let marked = view.markedTextRange != nil
            if parent.composing != marked { parent.composing = marked }
            publishSelectionAndEdit(view, marked: marked)
        }
        private func publishSelectionAndEdit(_ view: UITextView, marked: Bool) {
            guard !applyingModelText, !publishingNativeText, pendingExternalText == nil else { return }
            publishingNativeText = true
            defer { publishingNativeText = false }
            let selection = view.selectedRange
            lastPublishedSelection = selection
            if parent.selection?.wrappedValue != selection { parent.selection?.wrappedValue = selection }
            parent.onEdit?(view.text ?? "", selection, marked)
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ textView: UITextView) {
            publishNativeText(textView)
            // Temporarily disabling for textBegin must not erase the user's
            // keyboard intent. The next acknowledged snapshot re-enables and
            // refocuses the editor; an explicit hide already sets intent false.
            if !(parent.disabled && parent.preservesFocusWhileLoading) { parent.isFocused = false }
            parent.composing = false
        }
        func textViewDidChange(_ textView: UITextView) {
            publishNativeText(textView)
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applyingModelText, !publishingNativeText else { return }
            let marked = textView.markedTextRange != nil
            if !marked && pendingExternalText != nil { synchronizeText(textView) }
            if parent.composing != marked { parent.composing = marked }
            // A keyboard edit can deliver selection before didChange. Publish
            // text and selection together so its first frame cannot contain the
            // previous text with the new caret. Select All also takes this path.
            if parent.onEdit != nil { publishNativeText(textView) }
        }
    }
}

struct TouchSurface: UIViewRepresentable {
    let enabled: Bool
    var control: Control? = nil
    var profile: TouchGestureState.Profile = .desktop
    var configuration: GestureConfiguration? = nil
    let onMove: (Double, Double) -> Void
    let onLeftTap: () -> Void
    let onRightTap: () -> Void
    let onDraggingChanged: (Bool) -> Void
    let onScroll: (Double) -> Void
    var onShortcut: (GestureAction) -> Void = { _ in }
    var onInteractionBegan: () -> Void = {}

    /// Overlay controls cancel the underlying pad synchronously before opening
    /// another UI. This also cancels deferred taps and releases an active drag.
    final class Control {
        fileprivate weak var view: TouchInputView?
        func cancel() { view?.cancelInput() }
    }

    func makeUIView(context: Context) -> TouchInputView {
        let view = TouchInputView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "touchpad"
        view.configure(self)
        return view
    }
    func updateUIView(_ view: TouchInputView, context: Context) { view.configure(self) }
    static func dismantleUIView(_ view: TouchInputView, coordinator: ()) { view.detach() }

    final class TouchInputView: UIView {
        private var parent: TouchSurface?
        private var state = TouchGestureState()
        private var pointerMotion = DesktopPointerMotion()
        private var pointerTimestamp = 0.0
        private var contacts: [ObjectIdentifier: CGPoint] = [:]
        private var contactOrigins: [ObjectIdentifier: CGPoint] = [:]
        private var deadlineTimer: Timer?
        private var active = true
        private lazy var effects = TouchParticleRenderer(in: layer)
        private var effectPoint = CGPoint.zero
        private var lastLiftPoint = CGPoint.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(inactive), name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { deadlineTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }

        func configure(_ parent: TouchSurface) {
            let configuration = (parent.configuration ?? GestureConfiguration(target: parent.profile == .desktop ? .computer : .television))
                .sanitized(for: parent.profile == .desktop ? .computer : .television)
            if state.profile != parent.profile || state.configuration != configuration {
                deadlineTimer?.invalidate()
                deadlineTimer = nil
                contacts.removeAll()
                contactOrigins.removeAll()
                // Keep the previous callbacks installed until its button is released.
                dispatch(state.cancel())
                state = TouchGestureState(profile: parent.profile, configuration: configuration)
                effects.clear()
            }
            if !parent.enabled && self.parent?.enabled == true {
                effects.setActive(false)
                cancelInput()
            }
            if self.parent?.control !== parent.control {
                if self.parent?.control?.view === self { self.parent?.control?.view = nil }
            }
            self.parent = parent
            parent.control?.view = self
            accessibilityLabel = parent.profile == .desktop ? String(localized: "电脑触控板") : String(localized: "电视触控板")
            accessibilityHint = String(localized: "在手势设置中查看和修改操作。")
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: parent.profile == .desktop ? String(localized: "左键单击") : String(localized: "确认"), target: self, selector: #selector(accessibleLeftClick))
            ]
            if parent.profile == .desktop {
                accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: String(localized: "右键单击"), target: self, selector: #selector(accessibleRightClick)))
            }
            isUserInteractionEnabled = parent.enabled && active
            effects.setInteractionFrameRate(parent.profile == .desktop ? (window?.screen.maximumFramesPerSecond ?? 60) : 60)
            effects.setActive(parent.enabled && active && window != nil)
#if targetEnvironment(simulator)
            effects.startPreviewIfRequested()
#endif
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            effects.layout(in: bounds)
#if targetEnvironment(simulator)
            if window != nil, active { effects.startPreviewIfRequested() }
#endif
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            effects.setInteractionFrameRate(parent?.profile == .desktop ? (window?.screen.maximumFramesPerSecond ?? 60) : 60)
            effects.setActive(window != nil && active && parent?.enabled == true)
            if window == nil { cancelInput() }
#if targetEnvironment(simulator)
            if window != nil { effects.startPreviewIfRequested() }
#endif
        }
        func detach() {
            effects.setActive(false)
            cancelInput()
            if parent?.control?.view === self { parent?.control?.view = nil }
        }
        @objc private func inactive() {
            active = false
            effects.setActive(false)
            cancelInput()
            isUserInteractionEnabled = false
        }
        @objc private func becameActive() {
            active = true
            isUserInteractionEnabled = parent?.enabled == true
            effects.setActive(parent?.enabled == true && window != nil)
#if targetEnvironment(simulator)
            effects.startPreviewIfRequested()
#endif
        }
        func cancelInput() {
            pointerMotion.reset()
            deadlineTimer?.invalidate()
            deadlineTimer = nil
            contacts.removeAll()
            contactOrigins.removeAll()
            dispatch(state.cancel())
            effects.clear()
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard parent?.enabled == true, active else { return }
            // Only the other overlay is cancelled. Contacts already on this
            // surface keep their normal two-finger gesture state.
            parent?.onInteractionBegan()
            for touch in touches {
                let id = ObjectIdentifier(touch), point = touch.location(in: self)
                contacts[id] = point
                contactOrigins[id] = point
            }
            effectPoint = CGPoint(x: centroid.x, y: centroid.y)
            pointerTimestamp = event?.timestamp ?? now
            pointerMotion.reset(at: pointerTimestamp)
#if DEBUG
            PointerTiming.shared.resetPulse("touchInterval")
            PointerTiming.shared.count("contacts")
#endif
            dispatch(state.begin(at: centroid, count: contacts.count, time: event?.timestamp ?? now, region: touchRegion))
            effects.beginContact(at: effectPoint)
            scheduleDeadline()
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard parent?.enabled == true, active else { cancelInput(); return }
            guard touches.contains(where: { contacts[ObjectIdentifier($0)] != nil }) else { return }
            for touch in touches where contacts[ObjectIdentifier(touch)] != nil {
                let id = ObjectIdentifier(touch), point = touch.location(in: self)
                if let origin = contactOrigins[id], hypot(point.x - origin.x, point.y - origin.y) > TouchGestureState.stationaryMovementTolerance {
                    state.invalidateStationaryGestures()
                }
                contacts[id] = point
            }
            if !contacts.isEmpty {
                effectPoint = CGPoint(x: centroid.x, y: centroid.y)
                effects.updateContact(at: effectPoint)
            }
            pointerTimestamp = event?.timestamp ?? now
#if DEBUG
            PointerTiming.shared.pulse("touchInterval", at: pointerTimestamp)
            PointerTiming.shared.sample("touchDelivery", seconds: now - pointerTimestamp)
#endif
            dispatch(state.move(to: centroid, count: contacts.count, time: event?.timestamp ?? now, region: touchRegion))
            scheduleDeadline()
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard parent?.enabled == true, active else { cancelInput(); return }
            // A control can cancel a contact while its finger is still down.
            // Its later UIKit end event must not end a new finger's gesture.
            guard touches.contains(where: { contacts[ObjectIdentifier($0)] != nil }) else { return }
            for touch in touches where contacts[ObjectIdentifier(touch)] != nil {
                let id = ObjectIdentifier(touch), point = touch.location(in: self)
                if let origin = contactOrigins[id], hypot(point.x - origin.x, point.y - origin.y) > TouchGestureState.stationaryMovementTolerance {
                    state.invalidateStationaryGestures()
                }
                contacts[id] = point
            }
            let finalPoint = centroid
            let finalRegion = touchRegion
            if !contacts.isEmpty {
                effectPoint = CGPoint(x: finalPoint.x, y: finalPoint.y)
                lastLiftPoint = effectPoint
                effects.updateContact(at: effectPoint)
            }
            for touch in touches {
                let id = ObjectIdentifier(touch)
                contacts.removeValue(forKey: id)
                contactOrigins.removeValue(forKey: id)
            }
            dispatch(state.end(at: finalPoint, remainingCount: contacts.count, time: event?.timestamp ?? now, region: finalRegion,
                               remainingPoint: contacts.isEmpty ? nil : centroid))
            pointerMotion.reset()
            effects.endContact()
            scheduleDeadline()
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.contains(where: { contacts[ObjectIdentifier($0)] != nil }) else { return }
            cancelInput()
        }

        private var now: Double { ProcessInfo.processInfo.systemUptime }
        private var touchRegion: TouchGestureState.Region { centroid.x < bounds.midX ? .left : .right }
        private var centroid: TouchGestureState.Point {
            guard !contacts.isEmpty else { return .init(x: 0, y: 0) }
            return .init(x: contacts.values.reduce(0) { $0 + $1.x } / Double(contacts.count),
                         y: contacts.values.reduce(0) { $0 + $1.y } / Double(contacts.count))
        }
        private func scheduleDeadline() {
            deadlineTimer?.invalidate()
            deadlineTimer = nil
            guard let deadline = state.nextDeadline, parent?.enabled == true, active else { return }
            let timer = Timer(timeInterval: max(0.001, deadline - now), repeats: false) { [weak self] _ in
                guard let self, self.parent?.enabled == true, self.active else { return }
                self.dispatch(self.state.advance(to: self.now))
                self.scheduleDeadline()
            }
            deadlineTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        private func dispatch(_ actions: [TouchGestureState.Action]) {
            guard let parent else { return }
            for action in actions {
                switch action {
                case .move(let dx, let dy):
                    if parent.profile == .desktop {
                        let motion = pointerMotion.feed(dx: dx, dy: dy, time: pointerTimestamp)
                        if motion.x != 0 || motion.y != 0 { parent.onMove(motion.x, motion.y) }
                    } else {
                        parent.onMove(dx, dy)
                    }
                    effects.moveTrail(to: effectPoint)
                case .leftClick:
                    parent.onLeftTap()
                    effects.click(at: lastLiftPoint, double: false)
                case .rightClick:
                    guard parent.profile == .desktop else { continue }
                    parent.onRightTap()
                    effects.click(at: lastLiftPoint, double: true)
                case .dragging(let down):
                    guard parent.profile == .desktop else { continue }
                    parent.onDraggingChanged(down)
                    effects.setDragging(down, at: effectPoint)
                case .scroll(let dy):
                    parent.onScroll(dy)
                    effects.moveTrail(to: effectPoint, scrolling: true)
                case .shortcut(let action):
                    parent.onShortcut(action)
                    effects.click(at: effectPoint, double: false)
                }
            }
        }
        @objc private func accessibleLeftClick() -> Bool {
            guard parent?.enabled == true, active else { return false }
            parent?.onLeftTap()
            effects.click(at: CGPoint(x: bounds.midX, y: bounds.midY), double: false)
            return true
        }
        @objc private func accessibleRightClick() -> Bool {
            guard parent?.enabled == true, parent?.profile == .desktop, active else { return false }
            parent?.onRightTap()
            effects.click(at: CGPoint(x: bounds.midX, y: bounds.midY), double: true)
            return true
        }
    }
}
