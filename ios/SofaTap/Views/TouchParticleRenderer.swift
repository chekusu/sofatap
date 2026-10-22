import UIKit

/// Local feedback only. The full dot field uses four batched paths, no per-dot
/// views or layers, and has no knowledge of the computer's cursor or transport.
final class TouchParticleRenderer: NSObject {
    private struct Dot {
        let origin: CGPoint
        let phase: CGFloat
        let radius: CGFloat
        var displacement = CGPoint.zero
    }
    private struct Ripple {
        var active = false
        var born = 0.0
        var life = 0.0
        var point = CGPoint.zero
        var radius: CGFloat = 0
        var travel: CGFloat = 0
        var force: CGFloat = 0
    }
    private struct Wave {
        let point: CGPoint
        let radius: CGFloat
        let force: CGFloat
        let brightness: CGFloat
    }
    private final class FrameTarget: NSObject {
        weak var renderer: TouchParticleRenderer?
        @objc func step(_ link: CADisplayLink) { renderer?.step(at: link.timestamp) }
    }

    private let surface = CALayer()
    private let fieldLayers = (0..<4).map { _ in CAShapeLayer() }
    private let glow = CAGradientLayer()
    private let staticPulse = CAShapeLayer()
    private let mint = UIColor(red: 0.64, green: 1, blue: 0.82, alpha: 1)
    private let ice = UIColor(red: 0.74, green: 0.92, blue: 1, alpha: 1)
    private let rippleLayers = (0..<8).map { _ in CAShapeLayer() }
    private var dots: [Dot] = []
    private var ripples = [Ripple](repeating: Ripple(), count: 8)
    private var nextRipple = 0
    private var displayLink: CADisplayLink?
    private let frameTarget = FrameTarget()
    private var preferredFPS: Float = 0
    private var interactionFPS: Float = 60
    private var renderingActive = false
    private var hasContact = false
    private var dragging = false
    private var contactPoint = CGPoint.zero
    private var previousPoint = CGPoint.zero
    private var flow = CGPoint.zero
    private var contactStrength: CGFloat = 0
    private var ambientPhase: CGFloat = 0
    private var lastFrameTime: Double?
    private var reducedMotion = UIAccessibility.isReduceMotionEnabled
    private var pulseClear: DispatchWorkItem?
    private var canvasBounds = CGRect.zero
#if targetEnvironment(simulator)
    private var previewStart: Double?
    private var previewPhase = -1
    private var previewWasStarted = false
#endif

    init(in layer: CALayer) {
        super.init()
        frameTarget.renderer = self
        surface.masksToBounds = true
        layer.addSublayer(surface)
        let shades = [
            UIColor(red: 0.43, green: 0.79, blue: 0.65, alpha: 0.35),
            UIColor(red: 0.53, green: 0.88, blue: 0.74, alpha: 0.52),
            mint.withAlphaComponent(0.78), ice.withAlphaComponent(0.98)
        ]
        for (index, field) in fieldLayers.enumerated() {
            field.fillColor = shades[index].cgColor
            field.strokeColor = nil
            surface.addSublayer(field)
        }
        // Broad, low-contrast light supports the matrix deformation without a
        // cursor graphic or a detached bright tracer.
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [mint.withAlphaComponent(0.075).cgColor,
                       mint.withAlphaComponent(0.025).cgColor,
                       mint.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.35, 1]
        glow.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        glow.opacity = 0
        surface.addSublayer(glow)
        for ripple in rippleLayers {
            ripple.opacity = 0
            ripple.fillColor = UIColor.clear.cgColor
            ripple.lineWidth = 0.8
            surface.addSublayer(ripple)
        }
        staticPulse.fillColor = mint.withAlphaComponent(0.06).cgColor
        staticPulse.strokeColor = mint.withAlphaComponent(0.7).cgColor
        staticPulse.lineWidth = 1.2
        staticPulse.opacity = 0
        surface.addSublayer(staticPulse)
        NotificationCenter.default.addObserver(self, selector: #selector(motionPreferenceChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    deinit {
        displayLink?.invalidate()
        pulseClear?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func layout(in bounds: CGRect) {
        guard bounds != canvasBounds else { return }
        canvasBounds = bounds
        withoutAnimations {
            surface.frame = bounds
            for field in fieldLayers { field.frame = surface.bounds }
            // RemoteView owns the final pad shape, including the overlay controls.
            rebuildField()
            drawField(delta: 0, waves: [], moving: false)
        }
        if dots.isEmpty { stopFrames() } else { startFrames() }
    }

    /// Visible, enabled foreground pads animate. Unavailable/disconnected pads
    /// retain a static field; none of their display links continue running.
    func setActive(_ active: Bool) {
        guard renderingActive != active else { return }
        renderingActive = active
        if active { lastFrameTime = nil; startFrames() }
        else { clear() }
    }

    func beginContact(at point: CGPoint) {
        guard renderingActive else { return }
        hasContact = true
        contactPoint = point
        previousPoint = point
        flow = .zero
        withoutAnimations {
            glow.position = point
            if reducedMotion { glow.opacity = 0.8 }
        }
        startFrames()
    }

    func updateContact(at point: CGPoint) {
        contactPoint = point
        guard hasContact else { return }
        withoutAnimations { glow.position = point }
    }

    /// The recognized movement is carried by the local field, not a separate
    /// bright cursor-like trail. The method name preserves the input-view API.
    func moveTrail(to point: CGPoint, scrolling: Bool = false) {
        guard renderingActive else { return }
        let gain: CGFloat = scrolling ? 0.6 : 1.25
        let dx = (point.x - previousPoint.x) * gain
        let dy = (point.y - previousPoint.y) * gain
        let magnitude = max(1, hypot(dx, dy) / 22)
        flow = CGPoint(x: flow.x * 0.45 + dx / magnitude * 0.55,
                       y: flow.y * 0.45 + dy / magnitude * 0.55)
        previousPoint = point
        startFrames()
    }

    func endContact() {
        hasContact = false
        if reducedMotion { withoutAnimations { glow.opacity = 0 } }
        startFrames()
    }

    func click(at point: CGPoint, double: Bool) {
        guard renderingActive else { return }
        if reducedMotion { staticFeedback(at: point, strong: double); return }
        let time = CACurrentMediaTime()
        ripple(at: point, radius: 8, travel: double ? 157 : 118,
               life: double ? 1.0 : 0.85, force: double ? 18 : 12,
               color: double ? ice : mint, at: time)
        if double { ripple(at: point, radius: 28, travel: 155, life: 1.15, force: 10, color: mint, at: time) }
        startFrames()
    }

    func setDragging(_ down: Bool, at point: CGPoint) {
        guard dragging != down else { return }
        dragging = down
        contactPoint = point
        guard renderingActive else { return }
        if reducedMotion { staticFeedback(at: point, strong: down); return }
        ripple(at: point, radius: down ? 43 : 24, travel: down ? -22 : 64,
               life: down ? 0.48 : 0.58, force: down ? -11 : 7, color: ice, at: CACurrentMediaTime())
        startFrames()
    }

    /// Clears gesture/preview effects. Intentional ambient motion resumes if the
    /// pad remains enabled; otherwise all frame callbacks stop.
    func clear() {
        stopFrames()
        pulseClear?.cancel()
        pulseClear = nil
        hasContact = false
        dragging = false
        contactStrength = 0
        flow = .zero
#if targetEnvironment(simulator)
        // A launch-time scene transition may cancel the scheduled preview before
        // it produces its first contact. Permit that one unfinished start to be
        // requested again once the app is truly foregrounded.
        if let previewStart, previewPhase < 1, CACurrentMediaTime() - previewStart < 0.35 {
            previewWasStarted = false
        }
        previewStart = nil
#endif
        withoutAnimations {
            glow.opacity = 0
            staticPulse.opacity = 0
            for index in ripples.indices { ripples[index].active = false; rippleLayers[index].opacity = 0 }
            for index in dots.indices { dots[index].displacement = .zero }
            drawField(delta: 0, waves: [], moving: false)
        }
        startFrames()
    }

    @objc private func motionPreferenceChanged() {
        let contactWasActive = hasContact
        let dragWasActive = dragging
        let point = contactPoint
        reducedMotion = UIAccessibility.isReduceMotionEnabled
#if targetEnvironment(simulator)
        let wasPreviewing = previewStart != nil
#endif
        clear()
#if targetEnvironment(simulator)
        if wasPreviewing { return }
#endif
        if contactWasActive {
            beginContact(at: point)
            if dragWasActive { setDragging(true, at: point) }
        }
    }

    private func rebuildField() {
        dots.removeAll(keepingCapacity: true)
        guard canvasBounds.width > 0, canvasBounds.height > 0 else { return }
        // Cap density for unusually large layouts, too. Normal iPhone layouts
        // contain 700–1000 dots, all batched into four shape layers.
        let spacing = max(CGFloat(16), sqrt(canvasBounds.width * canvasBounds.height / 1050))
        let columns = min(1050, max(1, Int(canvasBounds.width / spacing)))
        let rows = min(max(1, Int(canvasBounds.height / spacing)), max(1, 1050 / columns))
        let startX = (canvasBounds.width - CGFloat(columns - 1) * spacing) / 2
        let startY = (canvasBounds.height - CGFloat(rows - 1) * spacing) / 2
        for row in 0..<rows {
            for column in 0..<columns {
                let phase = CGFloat((row * 17 + column * 31) % 97) / 97 * .pi * 2
                dots.append(Dot(origin: CGPoint(x: startX + CGFloat(column) * spacing,
                                                y: startY + CGFloat(row) * spacing),
                                phase: phase, radius: 0.78 + CGFloat((row + column * 3) % 5) * 0.08))
            }
        }
    }

    private func drawField(delta: Double, waves: [Wave], moving: Bool) {
        let paths = (0..<4).map { _ in CGMutablePath() }
        let blend = CGFloat(1 - exp(-delta * (hasContact ? 10 : 6)))
        for index in dots.indices {
            let dot = dots[index]
            let phase = reducedMotion ? 0 : ambientPhase
            let driftX = sin(phase + dot.origin.y * 0.018) * 1.9 + cos(phase * 0.63 + dot.phase) * 0.65
            let driftY = cos(phase * 0.83 + dot.origin.x * 0.020) * 1.65 + sin(phase * 0.46 + dot.phase) * 0.6
            let base = CGPoint(x: dot.origin.x + driftX, y: dot.origin.y + driftY)
            var target = CGPoint.zero
            var light = (sin(phase * 0.7 + dot.origin.x * 0.025 + dot.origin.y * 0.012) + 1) * 0.23
            if moving, contactStrength > 0.002 {
                let dx = base.x - contactPoint.x, dy = base.y - contactPoint.y
                let distance = max(0.5, hypot(dx, dy))
                let fraction = max(0, 1 - distance / (dragging ? 122 : 106))
                let influence = fraction * fraction * (3 - 2 * fraction) * contactStrength
                let repel = (dragging ? CGFloat(46) : 36) * influence
                let curl = (dragging ? CGFloat(28) : 5) * influence
                target.x += dx / distance * repel - dy / distance * curl + flow.x * influence * 0.45
                target.y += dy / distance * repel + dx / distance * curl + flow.y * influence * 0.45
                light += influence * (dragging ? 1.7 : 1.4)
            }
            for wave in waves {
                let dx = base.x - wave.point.x, dy = base.y - wave.point.y
                let distance = max(0.5, hypot(dx, dy))
                let band = (distance - wave.radius) / 16
                let influence = exp(-band * band)
                target.x += dx / distance * wave.force * influence
                target.y += dy / distance * wave.force * influence
                light += wave.brightness * influence
            }
            if moving {
                dots[index].displacement.x += (target.x - dot.displacement.x) * blend
                dots[index].displacement.y += (target.y - dot.displacement.y) * blend
            }
            let offset = moving ? dots[index].displacement : .zero
            let position = CGPoint(x: base.x + offset.x, y: base.y + offset.y)
            let shade = light > 1.05 ? 3 : (light > 0.62 ? 2 : (light > 0.29 ? 1 : 0))
            let radius = dot.radius + min(light, 1.7) * 0.16
            paths[shade].addEllipse(in: CGRect(x: position.x - radius, y: position.y - radius,
                                              width: radius * 2, height: radius * 2))
        }
        for index in fieldLayers.indices { fieldLayers[index].path = paths[index] }
    }

    private func staticFeedback(at point: CGPoint, strong: Bool) {
        pulseClear?.cancel()
        withoutAnimations {
            let radius: CGFloat = strong ? 24 : 17
            staticPulse.position = point
            staticPulse.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
            staticPulse.opacity = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.withoutAnimations { self?.staticPulse.opacity = 0 } }
        pulseClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func ripple(at point: CGPoint, radius: CGFloat, travel: CGFloat, life: Double,
                        force: CGFloat, color: UIColor, at time: Double) {
        let index = nextRipple
        nextRipple = (nextRipple + 1) % ripples.count
        ripples[index] = Ripple(active: true, born: time, life: life, point: point,
                               radius: radius, travel: travel, force: force)
        withoutAnimations { rippleLayers[index].strokeColor = color.cgColor }
    }

    private func startFrames() {
        guard renderingActive, !reducedMotion, !dots.isEmpty else { return }
        if displayLink == nil {
            let link = CADisplayLink(target: frameTarget, selector: #selector(FrameTarget.step(_:)))
            displayLink = link
            preferredFPS = 0
            lastFrameTime = nil
            link.add(to: .main, forMode: .common)
        }
        updateFrameRate()
    }

    func setInteractionFrameRate(_ maximum: Int) {
        interactionFPS = Float(min(120, max(60, maximum)))
        updateFrameRate()
    }

    private func updateFrameRate() {
        let interaction = hasContact || contactStrength > 0.015 || ripples.contains(where: { $0.active })
        let fps: Float = hasContact ? interactionFPS : (interaction ? 60 : 30)
        guard preferredFPS != fps else { return }
        preferredFPS = fps
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: fps >= 60 ? 60 : 15, maximum: fps, preferred: fps)
    }

    private func stopFrames() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTime = nil
        preferredFPS = 0
    }

    private func step(at time: Double) {
#if DEBUG
        let renderStart = ProcessInfo.processInfo.systemUptime
        // CADisplayLink is installed only on RunLoop.main.
        defer { if hasContact { MainActor.assumeIsolated {
            PointerTiming.shared.sample("particleCPU", seconds: ProcessInfo.processInfo.systemUptime - renderStart)
        } } }
#endif
        guard renderingActive, !reducedMotion else { stopFrames(); return }
        let delta = min(0.1, max(0, time - (lastFrameTime ?? time)))
        lastFrameTime = time
#if targetEnvironment(simulator)
        advancePreview(at: time)
#endif
        ambientPhase += CGFloat(delta * 0.30)
        contactStrength += ((hasContact ? 1 : 0) - contactStrength) * CGFloat(1 - exp(-delta * 9))
        let decay = CGFloat(exp(-delta * 7))
        flow.x *= decay
        flow.y *= decay
        withoutAnimations {
            var waves: [Wave] = []
            for index in ripples.indices where ripples[index].active {
                let ripple = ripples[index]
                let progress = max(0, (time - ripple.born) / ripple.life)
                guard progress < 1 else {
                    ripples[index].active = false
                    rippleLayers[index].opacity = 0
                    continue
                }
                let eased = CGFloat(1 - pow(1 - progress, 2))
                let radius = max(1, ripple.radius + ripple.travel * eased)
                let fade = CGFloat(pow(1 - progress, 1.3))
                let layer = rippleLayers[index]
                layer.position = ripple.point
                layer.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
                layer.opacity = Float(fade * 0.55)
                layer.lineWidth = 0.9 - CGFloat(progress) * 0.4
                waves.append(Wave(point: ripple.point, radius: radius, force: ripple.force * fade, brightness: fade * 1.15))
            }
            glow.position = contactPoint
            glow.opacity = Float(contactStrength)
            drawField(delta: delta, waves: waves, moving: true)
        }
        updateFrameRate()
    }

    private func withoutAnimations(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }

#if targetEnvironment(simulator)
    /// Explicit simulator-only visual QA. No synthetic UITouch, gesture state,
    /// controller callback, pairing request or desktop input is involved.
    func startPreviewIfRequested() {
        guard renderingActive, !previewWasStarted, canvasBounds.width > 0, !reducedMotion,
              UIApplication.shared.applicationState == .active,
              ProcessInfo.processInfo.arguments.contains("--demo"),
              ProcessInfo.processInfo.arguments.contains("--preview-effects") else { return }
        previewWasStarted = true
        previewStart = CACurrentMediaTime()
        startFrames()
    }

    private func advancePreview(at time: Double) {
        guard let previewStart else { return }
        let elapsed = time - previewStart
        guard elapsed < 24 else {
            self.previewStart = nil
            setDragging(false, at: contactPoint)
            endContact()
            return
        }
        let cycle = max(0, elapsed.truncatingRemainder(dividingBy: 8))
        let phase: Int
        if cycle < 0.35 { phase = 0 }
        else if cycle < 2.25 { phase = 1 }
        else if cycle < 2.75 { phase = 2 }
        else if cycle < 3.50 { phase = 3 }
        else if cycle < 4.0 { phase = 4 }
        else if cycle < 4.30 { phase = 5 }
        else if cycle < 6.85 { phase = 6 }
        else { phase = 7 }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: canvasBounds.width * x, y: canvasBounds.height * y)
        }
        if phase != previewPhase {
            previewPhase = phase
            switch phase {
            case 1: beginContact(at: point(0.27, 0.52))
            case 2: endContact(); click(at: point(0.63, 0.45), double: false)
            case 3: click(at: point(0.43, 0.57), double: true)
            case 5: beginContact(at: point(0.30, 0.48))
            case 6: setDragging(true, at: point(0.30, 0.48))
            case 7: setDragging(false, at: contactPoint); endContact()
            default: break
            }
        }
        if phase == 1 {
            let t = CGFloat((cycle - 0.35) / 1.90)
            let p = point(0.27 + t * 0.40, 0.52 - sin(t * .pi * 1.2) * 0.15)
            updateContact(at: p)
            moveTrail(to: p)
        } else if phase == 6 {
            let t = CGFloat((cycle - 4.30) / 2.55)
            let p = point(0.30 + t * 0.36, 0.48 + sin(t * .pi * 1.4) * 0.13)
            updateContact(at: p)
            moveTrail(to: p)
        }
    }
#endif
}
