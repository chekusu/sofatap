import Foundation

@main
struct TouchGestureTests {
    static func main() {
        typealias State = TouchGestureState
        typealias Action = State.Action
        var passed = 0
        let origin = State.Point(x: 100, y: 100)
        let far = State.Point(x: 180, y: 170)
        func check(_ title: String, _ condition: Bool) {
            precondition(condition, title)
            passed += 1
        }
        func begin(_ state: inout State, _ time: Double = 0) -> [Action] {
            state.begin(at: origin, count: 1, time: time)
        }
        func end(_ state: inout State, _ time: Double) -> [Action] {
            state.end(at: origin, remainingCount: 0, time: time)
        }

        var single = State()
        check("touch starts without clicking", begin(&single).isEmpty)
        check("single release is deferred", end(&single, 0.05).isEmpty)
        check("single does not fire inside double-tap interval", single.advance(to: 0.329).isEmpty)
        check("single fires after double-tap interval", single.advance(to: 0.331) == [.leftClick])
        check("single never repeats", single.advance(to: 2).isEmpty)

        var double = State()
        _ = begin(&double); _ = end(&double, 0.04)
        check("second touch consumes pending single", begin(&double, 0.14).isEmpty)
        check("left-half double tap sends exactly two left clicks", end(&double, 0.20) == [.leftClick, .leftClick])
        check("double tap has no delayed or third click", double.advance(to: 2).isEmpty && double.nextDeadline == nil)

        var rightSingle = State()
        _ = rightSingle.begin(at: origin, count: 1, time: 0, region: .right)
        check("right-half single tap is deferred without clicking", rightSingle.end(at: origin, remainingCount: 0, time: 0.04, region: .right).isEmpty)
        check("right-half single tap remains exactly one left click", rightSingle.advance(to: 0.33) == [.leftClick])

        var rightDouble = State()
        _ = rightDouble.begin(at: origin, count: 1, time: 0, region: .right)
        _ = rightDouble.end(at: origin, remainingCount: 0, time: 0.04, region: .right)
        check("second right-half touch consumes pending single without stray left click", rightDouble.begin(at: origin, count: 1, time: 0.14, region: .right).isEmpty)
        check("right-half double tap sends exactly two right clicks", rightDouble.end(at: origin, remainingCount: 0, time: 0.20, region: .right) == [.rightClick, .rightClick])
        check("right double has no delayed or third click", rightDouble.advance(to: 2).isEmpty && rightDouble.nextDeadline == nil)

        for region in [State.Region.left, .right] {
            var triple = State()
            var actions: [Action] = []
            for index in 0..<3 {
                let time = Double(index) * 0.1
                actions += triple.begin(at: origin, count: 1, time: time, region: region)
                actions += triple.end(at: origin, remainingCount: 0, time: time + 0.03, region: region)
            }
            let pair: [Action] = region == .left ? [.leftClick, .leftClick] : [.rightClick, .rightClick]
            check("triple tap completes only one double click before timeout in \(region)", actions == pair)
            check("third tap is a fresh single left click in \(region)", triple.advance(to: 1) == [.leftClick] && triple.advance(to: 2).isEmpty)
        }

        for first in [State.Region.left, .right] {
            let second: State.Region = first == .left ? .right : .left
            var crossing = State()
            _ = crossing.begin(at: origin, count: 1, time: 0, region: first)
            _ = crossing.end(at: origin, remainingCount: 0, time: 0.04, region: first)
            check("different-half second tap preserves first single left click from \(first)", crossing.begin(at: origin, count: 1, time: 0.14, region: second) == [.leftClick])
            check("different-half second tap is a separate single from \(first)", crossing.end(at: origin, remainingCount: 0, time: 0.20, region: second).isEmpty)
            check("different-half taps never form a right or mixed-button double from \(first)", crossing.advance(to: 1) == [.leftClick] && crossing.advance(to: 2).isEmpty)
        }

        var crossingFirst = State()
        _ = crossingFirst.begin(at: origin, count: 1, time: 0, region: .right)
        _ = crossingFirst.move(to: origin, count: 1, time: 0.02, region: .left)
        _ = crossingFirst.end(at: origin, remainingCount: 0, time: 0.04, region: .right)
        check("crossing then returning cannot arm first half of double", crossingFirst.begin(at: origin, count: 1, time: 0.14, region: .right) == [.leftClick])
        _ = crossingFirst.end(at: origin, remainingCount: 0, time: 0.20, region: .right)
        check("crossed first tap stays an independent left click", crossingFirst.advance(to: 1) == [.leftClick])

        var crossingSecond = State()
        _ = crossingSecond.begin(at: origin, count: 1, time: 0, region: .right)
        _ = crossingSecond.end(at: origin, remainingCount: 0, time: 0.04, region: .right)
        _ = crossingSecond.begin(at: origin, count: 1, time: 0.14, region: .right)
        check("crossing second tap produces no premature click", crossingSecond.move(to: origin, count: 1, time: 0.16, region: .left).isEmpty)
        check("crossing second tap cancels right double and restores first left single", crossingSecond.end(at: origin, remainingCount: 0, time: 0.20, region: .right) == [.leftClick])
        check("crossed second tap finishes as independent left single", crossingSecond.advance(to: 1) == [.leftClick])

        var lateSecond = State()
        _ = lateSecond.begin(at: origin, count: 1, time: 0, region: .right)
        _ = lateSecond.end(at: origin, remainingCount: 0, time: 0.04, region: .right)
        check("second touch at timeout is separate, even if timer was delayed", lateSecond.begin(at: origin, count: 1, time: 0.321, region: .right) == [.leftClick])
        _ = lateSecond.end(at: origin, remainingCount: 0, time: 0.36, region: .right)
        check("late second right-half tap sends one left single", lateSecond.advance(to: 1) == [.leftClick])

        var cancelledRight = State()
        _ = cancelledRight.begin(at: origin, count: 1, time: 0, region: .right)
        _ = cancelledRight.end(at: origin, remainingCount: 0, time: 0.04, region: .right)
        check("overlay cancellation drops pending right-half tap", cancelledRight.cancel().isEmpty && cancelledRight.advance(to: 1).isEmpty)

        var separated = State()
        _ = begin(&separated); _ = end(&separated, 0.04)
        check("separate distant tap flushes first left click", separated.begin(at: far, count: 1, time: 0.12) == [.leftClick])
        check("second distinct single is deferred", separated.end(at: far, remainingCount: 0, time: 0.16).isEmpty)
        check("second distinct single fires once", separated.advance(to: 1) == [.leftClick])

        var hold = State()
        _ = begin(&hold)
        check("hold cannot begin before 300ms", hold.advance(to: 0.299).isEmpty && !hold.isDragging)
        check("hold begins at exactly 300ms", hold.advance(to: 0.300) == [.dragging(true)] && hold.isDragging)
        check("hold does not repeat down", hold.advance(to: 0.4).isEmpty)
        check("drag movement reaches receiver", hold.move(to: .init(x: 114, y: 106), count: 1, time: 0.42) == [.move(14, 6)])
        check("release ends drag without click", hold.end(at: .init(x: 114, y: 106), remainingCount: 0, time: 0.5) == [.dragging(false)])
        check("released hold has no delayed click", hold.advance(to: 2).isEmpty && !hold.isDragging)

        var cancelledHold = State()
        _ = begin(&cancelledHold); _ = cancelledHold.advance(to: 0.3)
        check("cancel releases held button", cancelledHold.cancel() == [.dragging(false)])
        check("repeated cancel is idempotent", cancelledHold.cancel().isEmpty)
        check("cancel clears timer", cancelledHold.nextDeadline == nil)

        var cancelledTap = State()
        _ = begin(&cancelledTap); _ = end(&cancelledTap, 0.03)
        check("cancel drops deferred tap", cancelledTap.cancel().isEmpty && cancelledTap.advance(to: 5).isEmpty)
        var earlyCancel = State()
        _ = begin(&earlyCancel)
        check("background before hold cannot arm later", earlyCancel.cancel().isEmpty && earlyCancel.advance(to: 5).isEmpty)

        var slide = State()
        _ = begin(&slide)
        check("slide moves without waiting 300ms", slide.move(to: .init(x: 110, y: 100), count: 1, time: 0.05) == [.move(10, 0)])
        check("moving finger never becomes hold", slide.advance(to: 0.5).isEmpty)
        check("slide lift never clicks", slide.end(at: .init(x: 110, y: 100), remainingCount: 0, time: 0.6).isEmpty)
        var delayedTimer = State()
        _ = begin(&delayedTimer)
        check("delayed timer cannot turn existing movement into drag", delayedTimer.move(to: far, count: 1, time: 0.4) == [.move(80, 70)])

        var jitter = State()
        _ = begin(&jitter)
        check("stationary jitter does not move cursor", jitter.move(to: .init(x: 102, y: 101), count: 1, time: 0.15).isEmpty)
        check("stationary jitter still permits 300ms hold", jitter.advance(to: 0.3) == [.dragging(true)])
        _ = jitter.cancel()

        var roll = State()
        _ = begin(&roll)
        check("early finger roll moves the pointer", roll.move(to: .init(x: 105, y: 100), count: 1, time: 0.05) == [.move(5, 0)])
        check("finger roll inside the stationary tolerance keeps the hold armed", roll.nextDeadline == 0.3)
        check("settled finger roll still begins a drag at 300ms", roll.advance(to: 0.3) == [.dragging(true)])
        check("settled finger roll releases without a click", roll.end(at: .init(x: 105, y: 100), remainingCount: 0, time: 0.4) == [.dragging(false)])
        var slowSlide = State()
        _ = begin(&slowSlide)
        var slowActions: [Action] = []
        for step in 1...6 {
            slowActions += slowSlide.move(to: .init(x: 100 + 1.1 * Double(step), y: 100), count: 1, time: 0.05 * Double(step))
        }
        slowActions += slowSlide.advance(to: 0.5)
        check("slow slide inside the stationary tolerance only moves the pointer",
              slowActions.count == 4 && !slowActions.contains(.dragging(true)) && !slowSlide.isDragging)
        check("slow slide lift never clicks", slowSlide.end(at: .init(x: 106.6, y: 100), remainingCount: 0, time: 0.6).isEmpty)
        var lateTimer = State()
        _ = begin(&lateTimer)
        _ = lateTimer.move(to: .init(x: 104, y: 100), count: 1, time: 0.05)
        check("movement after the deadline cancels a late hold",
              lateTimer.move(to: .init(x: 106, y: 100), count: 1, time: 0.35) == [.move(2, 0)] && !lateTimer.isDragging)
        check("late hold stays cancelled once the finger rests", lateTimer.advance(to: 1).isEmpty && lateTimer.nextDeadline == nil)
        _ = lateTimer.cancel()
        var rollPastTolerance = State()
        _ = begin(&rollPastTolerance)
        _ = rollPastTolerance.move(to: .init(x: 108, y: 100), count: 1, time: 0.05)
        check("leaving the stationary tolerance still cancels the hold",
              rollPastTolerance.nextDeadline == nil && rollPastTolerance.advance(to: 0.5).isEmpty)
        _ = rollPastTolerance.cancel()

        var scroll = State()
        _ = begin(&scroll)
        check("second finger cancels hold", scroll.begin(at: origin, count: 2, time: 0.1).isEmpty && scroll.nextDeadline == nil)
        check("two fingers down pull content down (wheel up) without moving cursor", scroll.move(to: .init(x: 120, y: 140), count: 2, time: 0.2) == [.scroll(40)])
        check("two fingers up push content up (wheel down)", scroll.move(to: .init(x: 120, y: 110), count: 2, time: 0.21) == [.scroll(-30)])
        check("scroll finger lift is silent", scroll.end(at: origin, remainingCount: 1, time: 0.25).isEmpty)
        check("remaining scroll finger cannot move pointer", scroll.move(to: far, count: 1, time: 0.3).isEmpty)
        check("scroll release never clicks", end(&scroll, 0.4).isEmpty && scroll.advance(to: 2).isEmpty)
        var twoTap = State()
        _ = twoTap.begin(at: origin, count: 2, time: 0, region: .right)
        check("stationary two-finger tap remains silent", twoTap.end(at: origin, remainingCount: 0, time: 0.1, region: .right).isEmpty && twoTap.advance(to: 1).isEmpty)

        var scrollAfterDrag = State()
        _ = begin(&scrollAfterDrag); _ = scrollAfterDrag.advance(to: 0.3)
        check("adding second finger releases active drag", scrollAfterDrag.begin(at: origin, count: 2, time: 0.4) == [.dragging(false)])
        check("two fingers cannot leave sticky hold", !scrollAfterDrag.isDragging)
        _ = scrollAfterDrag.cancel()

        var secondHold = State()
        _ = begin(&secondHold); _ = end(&secondHold, 0.03); _ = begin(&secondHold, 0.12)
        check("holding second touch starts drag without phantom left click", secondHold.advance(to: 0.43) == [.dragging(true)])
        check("holding second touch does not right click", end(&secondHold, 0.5) == [.dragging(false)])
        check("holding second touch leaves no delayed action", secondHold.advance(to: 3).isEmpty)
        var secondRoll = State()
        _ = begin(&secondRoll); _ = end(&secondRoll, 0.03); _ = begin(&secondRoll, 0.12)
        _ = secondRoll.move(to: .init(x: 104, y: 102), count: 1, time: 0.16)
        check("settled roll on the second touch still starts its drag", secondRoll.advance(to: 0.43) == [.dragging(true)])
        check("second-touch roll releases without a click", end(&secondRoll, 0.5) == [.dragging(false)])
        check("second-touch roll leaves no delayed action", secondRoll.advance(to: 3).isEmpty)
        var rightSecondHold = State()
        _ = rightSecondHold.begin(at: origin, count: 1, time: 0, region: .right)
        _ = rightSecondHold.end(at: origin, remainingCount: 0, time: 0.03, region: .right)
        _ = rightSecondHold.begin(at: origin, count: 1, time: 0.12, region: .right)
        check("right-half second hold begins drag without right or left click", rightSecondHold.advance(to: 0.43) == [.dragging(true)])
        check("right-half second hold releases exactly once", rightSecondHold.end(at: origin, remainingCount: 0, time: 0.5, region: .right) == [.dragging(false)] && rightSecondHold.advance(to: 1).isEmpty)

        var thirdFinger = State()
        _ = thirdFinger.begin(at: origin, count: 3, time: 0)
        check("three fingers suppressed", thirdFinger.move(to: far, count: 3, time: 0.2).isEmpty)
        check("three finger lift never clicks", end(&thirdFinger, 0.3).isEmpty)

        var tvTap = State(profile: .tvPointer)
        check("TV touch starts silently", begin(&tvTap).isEmpty)
        check("TV single tap confirms immediately on lift", end(&tvTap, 0.05) == [.leftClick])
        check("TV tap leaves no pending timer", tvTap.nextDeadline == nil)
        _ = begin(&tvTap, 0.14)
        check("TV second quick tap confirms again instead of right clicking", end(&tvTap, 0.20) == [.leftClick])
        check("TV taps never repeat later", tvTap.advance(to: 2).isEmpty)
        var tvRightTap = State(profile: .tvPointer)
        _ = tvRightTap.begin(at: origin, count: 1, time: 0, region: .right)
        check("TV right-half single confirms immediately", tvRightTap.end(at: origin, remainingCount: 0, time: 0.04, region: .right) == [.leftClick])
        _ = tvRightTap.begin(at: origin, count: 1, time: 0.14, region: .right)
        check("TV right-half rapid tap never emits right clicks", tvRightTap.end(at: origin, remainingCount: 0, time: 0.20, region: .right) == [.leftClick] && tvRightTap.advance(to: 1).isEmpty)

        var tvHold = State(profile: .tvPointer)
        _ = begin(&tvHold)
        check("TV stationary hold before deadline stays silent", tvHold.advance(to: 0.299).isEmpty)
        check("TV stationary hold never presses a button", tvHold.advance(to: 0.300).isEmpty && !tvHold.isDragging)
        check("TV completed hold clears its deadline", tvHold.nextDeadline == nil)
        check("TV held finger does not click on lift", end(&tvHold, 0.4).isEmpty && tvHold.advance(to: 2).isEmpty)
        _ = begin(&tvHold, 3)
        check("TV tap after a completed hold works normally", end(&tvHold, 3.05) == [.leftClick])

        var tvDelayedHold = State(profile: .tvPointer)
        _ = begin(&tvDelayedHold)
        check("TV delayed timer still suppresses a 300ms lift", end(&tvDelayedHold, 0.300).isEmpty && !tvDelayedHold.isDragging)
        var tvHoldMove = State(profile: .tvPointer)
        _ = begin(&tvHoldMove); _ = tvHoldMove.advance(to: 0.300)
        check("TV movement after hold is normal pointer motion", tvHoldMove.move(to: far, count: 1, time: 0.4) == [.move(80, 70)] && !tvHoldMove.isDragging)
        check("TV moved hold releases no button and clicks nothing", tvHoldMove.end(at: far, remainingCount: 0, time: 0.5).isEmpty)

        var tvScroll = State(profile: .tvPointer)
        _ = begin(&tvScroll)
        check("TV second finger cancels pending hold", tvScroll.begin(at: origin, count: 2, time: 0.1).isEmpty && tvScroll.nextDeadline == nil)
        check("TV two fingers down pull content down (wheel up)", tvScroll.move(to: .init(x: 120, y: 140), count: 2, time: 0.2) == [.scroll(40)])
        check("TV two fingers up push content up (wheel down)", tvScroll.move(to: .init(x: 120, y: 110), count: 2, time: 0.21) == [.scroll(-30)])
        _ = tvScroll.end(at: origin, remainingCount: 1, time: 0.25)
        check("TV remaining scroll finger cannot move or click", tvScroll.move(to: far, count: 1, time: 0.3).isEmpty && end(&tvScroll, 0.4).isEmpty)

        var switchPending = State()
        _ = begin(&switchPending); _ = end(&switchPending, 0.03)
        check("switch to TV cancels the desktop delayed click", switchPending.changeProfile(to: .tvPointer).isEmpty && switchPending.nextDeadline == nil && switchPending.advance(to: 2).isEmpty)
        check("switch ignores the old contact lift", end(&switchPending, 2.1).isEmpty)
        _ = begin(&switchPending, 3)
        check("first new TV contact confirms immediately", end(&switchPending, 3.05) == [.leftClick])

        var switchDrag = State()
        _ = begin(&switchDrag); _ = switchDrag.advance(to: 0.300)
        check("profile switch returns exactly one old-target drag release", switchDrag.changeProfile(to: .tvPointer) == [.dragging(false)] && !switchDrag.isDragging)
        check("same TV profile preserves the cancellation boundary", switchDrag.changeProfile(to: .tvPointer).isEmpty && switchDrag.advance(to: 2).isEmpty)
        _ = begin(&switchDrag, 3)
        check("TV to desktop cancels a live TV contact without a key event", switchDrag.changeProfile(to: .desktop).isEmpty && end(&switchDrag, 3.05).isEmpty)
        _ = begin(&switchDrag, 4)
        check("desktop semantics return after switching back", switchDrag.advance(to: 4.3) == [.dragging(true)])
        _ = switchDrag.cancel()
        print("PASS \(passed) touch gesture checks (deterministic, no desktop input)")
    }
}
