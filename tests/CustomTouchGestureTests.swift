import Foundation

@main
struct ConfigurableGestureTests {
    static func main() {
        typealias State = TouchGestureState
        typealias Action = State.Action
        var passed = 0
        let p = State.Point(x: 100, y: 100)
        func check(_ name: String, _ condition: Bool) {
            precondition(condition, name)
            passed += 1
        }
        func config(_ mappings: [GestureID: GestureAction], target: GestureTarget = .computer) -> GestureConfiguration {
            var configuration = GestureConfiguration(target: target)
            for (gesture, action) in mappings { configuration.setAction(action, for: gesture) }
            return configuration
        }
        func tap(_ state: inout State, at time: Double = 0, region: State.Region = .left) -> [Action] {
            state.begin(at: p, count: 1, time: time, region: region) +
                state.end(at: p, remainingCount: 0, time: time + 0.04, region: region)
        }

        let immediate = config([.singleTap: .confirm, .leftDoubleTap: .none,
                                .rightDoubleTap: .none, .doubleTapHold: .none])
        var remapSingle = State(configuration: immediate)
        check("no competing doubles means immediate remapped single", tap(&remapSingle) == [.shortcut(.confirm)])
        check("immediate single leaves no pending click", remapSingle.nextDeadline == nil && remapSingle.advance(to: 1).isEmpty)

        let split = config([.leftDoubleTap: .rightClick, .rightDoubleTap: .toggleKeyboard])
        var left = State(configuration: split)
        check("first remapped double candidate is deferred", tap(&left).isEmpty)
        check("left double executes assigned single right click", tap(&left, at: 0.12) == [.rightClick])
        check("remapped double has no extra single", left.advance(to: 1).isEmpty)
        var right = State(configuration: split)
        _ = tap(&right, region: .right)
        check("right double dispatches keyboard shortcut", tap(&right, at: 0.12, region: .right) == [.shortcut(.toggleKeyboard)])

        var regionOnly = State(configuration: config([.rightDoubleTap: .none, .doubleTapHold: .none]))
        check("disabled right double does not delay right single", tap(&regionOnly, region: .right) == [.leftClick])
        check("enabled left double still reserves left single", tap(&regionOnly, at: 1).isEmpty)
        check("reserved single uses configured timeout", regionOnly.advance(to: 1.321) == [.leftClick])

        var hold = State(configuration: config([.longPress: .toggleDictation, .doubleTapHold: .drag]))
        _ = hold.begin(at: p, count: 1, time: 0)
        check("discrete hold fires once at threshold", hold.advance(to: 0.3) == [.shortcut(.toggleDictation)])
        check("discrete hold never presses mouse button", !hold.isDragging && hold.advance(to: 1).isEmpty)
        check("discrete hold lift never clicks", hold.end(at: p, remainingCount: 0, time: 1.1).isEmpty)
        _ = tap(&hold, at: 2)
        _ = hold.begin(at: p, count: 1, time: 2.12)
        check("double tap hold differs from ordinary long press", hold.advance(to: 2.42) == [.dragging(true)])
        check("double tap hold releases once", hold.end(at: p, remainingCount: 0, time: 2.5) == [.dragging(false)] && hold.cancel().isEmpty)

        var panelHold = State(configuration: config([.longPress: .shortcutPanel, .doubleTapHold: .drag]))
        _ = panelHold.begin(at: p, count: 1, time: 0)
        check("hold opens the shortcut panel once", panelHold.advance(to: 0.3) == [.shortcut(.shortcutPanel)] && !panelHold.isDragging)
        check("panel hold lift never clicks", panelHold.end(at: p, remainingCount: 0, time: 0.8).isEmpty && panelHold.advance(to: 2).isEmpty)
        var panelTap = State(configuration: config([.threeFingerTap: .shortcutPanel]))
        _ = panelTap.begin(at: p, count: 3, time: 0)
        check("three finger tap can open the shortcut panel", panelTap.end(at: p, remainingCount: 0, time: 0.1) == [.shortcut(.shortcutPanel)])

        var pairAsSingles = State(configuration: config([.leftDoubleTap: .none, .rightDoubleTap: .none,
                                                        .singleTap: .confirm, .doubleTapHold: .drag]))
        _ = tap(&pairAsSingles)
        check("double hold alone preserves two short single taps", tap(&pairAsSingles, at: 0.12) == [.shortcut(.confirm), .shortcut(.confirm)])
        check("short pair never triggers deferred hold", pairAsSingles.advance(to: 1).isEmpty)

        var longDouble = State(configuration: config([.longPress: .rightClick, .doubleTapHold: .toggleKeyboard]))
        _ = tap(&longDouble)
        _ = longDouble.begin(at: p, count: 1, time: 0.12)
        check("discrete double hold consumes preceding tap", longDouble.advance(to: 0.42) == [.shortcut(.toggleKeyboard)])
        check("discrete double hold cannot double fire on lift", longDouble.end(at: p, remainingCount: 0, time: 0.5).isEmpty && longDouble.advance(to: 2).isEmpty)

        var timing = config([.longPress: .rightClick])
        timing.holdDuration = 0.6
        timing.doubleTapInterval = 0.45
        var customTiming = State(configuration: timing)
        _ = customTiming.begin(at: p, count: 1, time: 0)
        check("configured hold delay has no legacy early firing", customTiming.advance(to: 0.3).isEmpty)
        check("configured hold fires at requested threshold", customTiming.advance(to: 0.6) == [.rightClick])
        _ = customTiming.end(at: p, remainingCount: 0, time: 0.7)
        _ = tap(&customTiming, at: 1)
        check("configured double interval defers until its deadline", customTiming.advance(to: 1.48).isEmpty)
        check("configured double interval completes once", customTiming.advance(to: 1.491) == [.leftClick])

        var lateMove = State(configuration: config([.longPress: .toggleKeyboard]))
        _ = lateMove.begin(at: p, count: 1, time: 0)
        check("delayed timer cannot fire discrete hold after movement", lateMove.move(to: .init(x: 120, y: 108), count: 1, time: 0.4) == [.move(20, 8)])
        check("late moving lift never activates shortcut", lateMove.end(at: .init(x: 120, y: 108), remainingCount: 0, time: 0.5).isEmpty)

        var swap = State(configuration: config([.oneFingerMove: .scroll, .twoFingerMove: .movePointer]))
        _ = swap.begin(at: p, count: 1, time: 0)
        check("one finger can scroll without pointer input", swap.move(to: .init(x: 120, y: 130), count: 1, time: 0.1) == [.scroll(30)])
        _ = swap.end(at: .init(x: 120, y: 130), remainingCount: 0, time: 0.2)
        _ = swap.begin(at: p, count: 2, time: 1)
        check("two fingers can move pointer without wheel input", swap.move(to: .init(x: 120, y: 130), count: 2, time: 1.1) == [.move(20, 30)])
        _ = swap.end(at: .init(x: 120, y: 130), remainingCount: 1, time: 1.12, remainingPoint: .init(x: 160, y: 130))
        check("remapped two finger motion suppresses survivor tail", swap.move(to: .init(x: 180, y: 150), count: 1, time: 1.15).isEmpty && swap.end(at: .init(x: 180, y: 150), remainingCount: 0, time: 1.2).isEmpty)

        var reverse = config([.oneFingerMove: .scroll])
        reverse.naturalScrolling = false
        var reversed = State(configuration: reverse)
        _ = reversed.begin(at: p, count: 1, time: 0)
        check("scroll direction applies to remapped one finger motion", reversed.move(to: .init(x: 100, y: 120), count: 1, time: 0.1) == [.scroll(-20)])
        _ = reversed.cancel()
        _ = reversed.begin(at: p, count: 2, time: 1)
        check("scroll direction applies to two finger motion", reversed.move(to: .init(x: 100, y: 80), count: 2, time: 1.1) == [.scroll(20)])

        let multi = config([.twoFingerTap: .rightClick, .threeFingerTap: .toggleKeyboard])
        var simultaneous = State(configuration: multi)
        _ = simultaneous.begin(at: p, count: 2, time: 0)
        check("stationary two finger tap dispatches its mapping", simultaneous.end(at: p, remainingCount: 0, time: 0.12) == [.rightClick])
        check("multi tap has no deferred single or hold", simultaneous.advance(to: 1).isEmpty && simultaneous.nextDeadline == nil)
        _ = simultaneous.begin(at: p, count: 3, time: 1)
        check("stationary three finger tap dispatches its mapping", simultaneous.end(at: p, remainingCount: 0, time: 1.12) == [.shortcut(.toggleKeyboard)])

        var staggered = State(configuration: multi)
        _ = staggered.begin(at: .init(x: 60, y: 100), count: 1, time: 0)
        check("second finger arriving at changed centroid does not move", staggered.begin(at: p, count: 2, time: 0.04).isEmpty)
        check("first multi lift is deferred until last finger lifts", staggered.end(at: p, remainingCount: 1, time: 0.1, remainingPoint: .init(x: 140, y: 100)).isEmpty)
        check("staggered lifts tolerate centroid shift", staggered.end(at: .init(x: 140, y: 100), remainingCount: 0, time: 0.14) == [.rightClick])
        check("staggered multi tap never restores initial single", staggered.advance(to: 1).isEmpty)

        var three = State(configuration: multi)
        _ = three.begin(at: .init(x: 40, y: 100), count: 1, time: 0)
        _ = three.begin(at: .init(x: 70, y: 100), count: 2, time: 0.03)
        _ = three.begin(at: p, count: 3, time: 0.06)
        _ = three.end(at: p, remainingCount: 2, time: 0.1, remainingPoint: .init(x: 130, y: 100))
        _ = three.end(at: .init(x: 130, y: 100), remainingCount: 1, time: 0.13, remainingPoint: .init(x: 160, y: 100))
        check("staged three finger tap fires only highest contact gesture", three.end(at: .init(x: 160, y: 100), remainingCount: 0, time: 0.16) == [.shortcut(.toggleKeyboard)])

        var jitter = State(configuration: multi)
        _ = jitter.begin(at: p, count: 2, time: 0)
        check("stationary multi jitter does not accidentally scroll", jitter.move(to: .init(x: 102, y: 102), count: 2, time: 0.04).isEmpty)
        check("stationary multi jitter preserves intended tap", jitter.end(at: .init(x: 102, y: 102), remainingCount: 0, time: 0.1) == [.rightClick])

        var scrollNoTap = State(configuration: multi)
        _ = scrollNoTap.begin(at: p, count: 2, time: 0)
        check("multi movement still scrolls", scrollNoTap.move(to: .init(x: 100, y: 120), count: 2, time: 0.04) == [.scroll(20)])
        check("returning to origin cannot restore multi tap", scrollNoTap.move(to: p, count: 2, time: 0.08) == [.scroll(-20)] && scrollNoTap.end(at: p, remainingCount: 0, time: 0.12).isEmpty)

        var survivorMove = State(configuration: multi)
        _ = survivorMove.begin(at: p, count: 2, time: 0)
        _ = survivorMove.end(at: p, remainingCount: 1, time: 0.1, remainingPoint: .init(x: 140, y: 100))
        check("survivor motion cannot become pointer input", survivorMove.move(to: .init(x: 160, y: 100), count: 1, time: 0.12).isEmpty)
        check("survivor movement cancels multi tap even after returning", survivorMove.end(at: .init(x: 140, y: 100), remainingCount: 0, time: 0.16).isEmpty)

        var endOnlyMotion = State(configuration: multi)
        _ = endOnlyMotion.begin(at: p, count: 3, time: 0)
        _ = endOnlyMotion.end(at: p, remainingCount: 2, time: 0.05, remainingPoint: p)
        _ = endOnlyMotion.end(at: .init(x: 120, y: 100), remainingCount: 1, time: 0.1, remainingPoint: .init(x: 160, y: 100))
        check("end event movement during staged three finger lift cancels tap", endOnlyMotion.end(at: .init(x: 160, y: 100), remainingCount: 0, time: 0.15).isEmpty)

        var pinch = State(configuration: multi)
        _ = pinch.begin(at: p, count: 2, time: 0)
        pinch.invalidateStationaryGestures()
        check("opposing individual finger motion cannot hide behind stable centroid", pinch.move(to: p, count: 2, time: 0.08).isEmpty && pinch.end(at: p, remainingCount: 0, time: 0.12).isEmpty)
        var dragIndividualMotion = State(configuration: config([.longPress: .drag]))
        _ = dragIndividualMotion.begin(at: p, count: 1, time: 0)
        _ = dragIndividualMotion.advance(to: 0.3)
        dragIndividualMotion.invalidateStationaryGestures()
        check("individual motion observation never releases an active drag", dragIndividualMotion.isDragging && dragIndividualMotion.move(to: .init(x: 130, y: 100), count: 1, time: 0.4) == [.move(30, 0)])
        check("observed drag motion still releases exactly once", dragIndividualMotion.end(at: .init(x: 130, y: 100), remainingCount: 0, time: 0.5) == [.dragging(false)])

        var lateMulti = State(configuration: multi)
        _ = lateMulti.begin(at: p, count: 2, time: 0)
        check("long stationary two finger contact does not become a tap", lateMulti.end(at: p, remainingCount: 0, time: 0.26).isEmpty)
        _ = lateMulti.begin(at: p, count: 1, time: 1)
        _ = lateMulti.begin(at: p, count: 2, time: 1.27)
        check("late arriving second finger cannot turn old contact into tap", lateMulti.end(at: p, remainingCount: 0, time: 1.3).isEmpty)

        var transition = State(configuration: config([.twoFingerTap: .rightClick, .threeFingerTap: .toggleKeyboard, .longPress: .drag]))
        _ = transition.begin(at: p, count: 1, time: 0)
        _ = transition.advance(to: 0.3)
        check("second finger releases drag before changing semantics", transition.begin(at: p, count: 2, time: 0.31) == [.dragging(false)])
        check("released drag does not turn into multi tap", transition.end(at: p, remainingCount: 0, time: 0.35).isEmpty)

        var movedThenAdd = State(configuration: multi)
        _ = movedThenAdd.begin(at: p, count: 1, time: 0)
        _ = movedThenAdd.move(to: .init(x: 120, y: 100), count: 1, time: 0.02)
        _ = movedThenAdd.begin(at: .init(x: 150, y: 100), count: 2, time: 0.04)
        check("adding finger cannot erase prior movement into a tap", movedThenAdd.end(at: .init(x: 150, y: 100), remainingCount: 0, time: 0.1).isEmpty)

        var fourth = State(configuration: multi)
        _ = fourth.begin(at: p, count: 3, time: 0)
        _ = fourth.begin(at: p, count: 4, time: 0.04)
        _ = fourth.end(at: p, remainingCount: 3, time: 0.08, remainingPoint: p)
        check("unsupported fourth finger suppresses complete sequence", fourth.end(at: p, remainingCount: 0, time: 0.12).isEmpty)

        var newDuringTail = State(configuration: multi)
        _ = newDuringTail.begin(at: p, count: 2, time: 0)
        _ = newDuringTail.end(at: p, remainingCount: 1, time: 0.06, remainingPoint: p)
        _ = newDuringTail.begin(at: p, count: 2, time: 0.08)
        check("finger added during suppressed tail cannot rearm tap", newDuringTail.end(at: p, remainingCount: 0, time: 0.12).isEmpty)

        var cancelMulti = State(configuration: multi)
        _ = cancelMulti.begin(at: p, count: 2, time: 0)
        _ = cancelMulti.end(at: p, remainingCount: 1, time: 0.06, remainingPoint: p)
        check("cancelling partial lift clears pending multi tap", cancelMulti.cancel().isEmpty && cancelMulti.end(at: p, remainingCount: 0, time: 0.12).isEmpty)

        var change = State(configuration: config([.longPress: .drag]))
        _ = change.begin(at: p, count: 1, time: 0)
        _ = change.advance(to: 0.3)
        check("configuration change releases old active drag", change.changeConfiguration(to: immediate) == [.dragging(false)] && !change.isDragging)
        check("configuration change discards prior touch lift", change.end(at: p, remainingCount: 0, time: 0.4).isEmpty)
        check("new configuration takes effect for fresh contact", tap(&change, at: 1) == [.shortcut(.confirm)])
        check("same configuration does not reset a gesture", change.begin(at: p, count: 1, time: 2).isEmpty && change.changeConfiguration(to: immediate).isEmpty && change.end(at: p, remainingCount: 0, time: 2.04) == [.shortcut(.confirm)])

        var pending = State()
        _ = tap(&pending)
        check("configuration change drops queued old tap", pending.changeConfiguration(to: immediate).isEmpty && pending.advance(to: 1).isEmpty)

        var profile = State(configuration: multi)
        _ = profile.begin(at: p, count: 2, time: 0)
        check("profile switch cancels pending multi gesture", profile.changeProfile(to: .tvPointer).isEmpty && profile.end(at: p, remainingCount: 0, time: 0.1).isEmpty)
        check("TV default remains immediate after switching", tap(&profile, at: 1) == [.leftClick])
        _ = profile.changeProfile(to: .desktop)
        check("desktop defaults restored by compatibility profile API", profile.configuration == GestureConfiguration())

        var television = State(profile: .tvPointer, configuration: config([.longPress: .back, .threeFingerTap: .home], target: .television))
        check("TV custom hold does not delay single when doubles disabled", tap(&television) == [.leftClick])
        _ = television.begin(at: p, count: 1, time: 1)
        check("TV custom long press dispatches back without drag", television.advance(to: 1.3) == [.shortcut(.back)] && !television.isDragging)
        _ = television.end(at: p, remainingCount: 0, time: 1.4)
        _ = television.begin(at: p, count: 3, time: 2)
        check("TV multi tap dispatches home", television.end(at: p, remainingCount: 0, time: 2.1) == [.shortcut(.home)])
        print("PASS \(passed) configurable gesture checks (deterministic, no desktop input)")
    }
}
