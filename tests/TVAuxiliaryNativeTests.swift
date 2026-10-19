import SwiftUI
import UIKit

private final class Touch: UITouch {
    var point = CGPoint(x: 66, y: 22)
    var time: TimeInterval = 1
    override func location(in view: UIView?) -> CGPoint { point }
    override var timestamp: TimeInterval { time }
}
private final class Event: UIEvent {
    var contacts: Set<UITouch> = []
    override var allTouches: Set<UITouch>? { contacts }
}

@main struct TVAuxiliaryNativeTests {
    @MainActor static func main() {
        var checks = 0, commands: [String] = []
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            guard value() else { fatalError("FAIL: " + name) }; checks += 1
        }
        let control = TVAuxiliaryPager.Control(), view = TVAuxiliaryPager.PagerView()
        func configure(_ identity: String) {
            func action(_ id: String) -> TVAuxiliaryPager.Action {
                .init(symbol: "house", label: id, identifier: id) { commands.append(id) }
            }
            view.configure(TVAuxiliaryPager(pages: [[action("back"), action("home")], [action("directions"), action("mode")], [action("youtube"), action("netflix")]],
                                            identity: identity, layout: TVAuxiliaryLayout(cardWidth: 320), interactionEnabled: true,
                                            control: control, onInteractionBegan: {}))
            view.frame = CGRect(x: 0, y: 0, width: 88, height: 56); view.layoutIfNeeded()
        }
        func element(_ index: Int) -> UIAccessibilityElement { (view.accessibilityElements as! [UIAccessibilityElement])[index] }
        configure("tvA")
        let oldBack = element(0)
        check("current native AX button activates Back", oldBack.accessibilityActivate() && commands == ["back"])
        check("native AX paging changes page", view.accessibilityScroll(.left))
        check("cached Back does not activate Directions on new page", !oldBack.accessibilityActivate() && commands == ["back"])
        let oldDirections = element(0)
        configure("tvB")
        check("cached previous-device button cannot act on new TV", !oldDirections.accessibilityActivate() && commands == ["back"])
        check("new device initially shows Back", element(0).accessibilityIdentifier == "back")
        configure("tvA")
        check("returning to original device does not revive cached AX action", !oldBack.accessibilityActivate() && commands == ["back"])
        check("current native action remains usable", element(1).accessibilityActivate() && commands == ["back", "home"])
        check("third local page exposes the TV app shortcuts", view.accessibilityScroll(.left) && view.accessibilityScroll(.left) && element(0).accessibilityIdentifier == "youtube" && element(1).accessibilityIdentifier == "netflix")
        let oldYouTube = element(0)
        check("YouTube quick action uses its own action", oldYouTube.accessibilityActivate() && commands.last == "youtube")
        check("returning to navigation page invalidates cached launch action", view.accessibilityScroll(.right) && !oldYouTube.accessibilityActivate())
        check("Back and Home remain the initial page", view.accessibilityScroll(.right) && element(0).accessibilityIdentifier == "back")
        let before = commands
        let toolbarFinger = Touch(), otherFinger = Touch(), event = Event()
        event.contacts = [toolbarFinger]
        view.touchesBegan([toolbarFinger], with: event)
        let main = TouchSurface.TouchInputView()
        main.configure(TouchSurface(enabled: true, onMove: { _,_ in }, onLeftTap: {}, onRightTap: {}, onDraggingChanged: { _ in }, onScroll: { _ in },
                                    onInteractionBegan: { control.cancel() }))
        event.contacts = [toolbarFinger, otherFinger]
        main.touchesBegan([otherFinger], with: event)
        main.touchesEnded([otherFinger], with: event)
        event.contacts = [toolbarFinger]; toolbarFinger.time = 1.2
        view.touchesEnded([toolbarFinger], with: event)
        check("toolbar-first then main contact cannot send delayed Home", commands == before)
        check("toolbar is still usable after cross-contact cancellation", element(1).accessibilityActivate() && commands.count == before.count + 1)
        var scrolls: [Double] = [], began = 0
        let twoFingerMain = TouchSurface.TouchInputView()
        twoFingerMain.configure(TouchSurface(enabled: true, onMove: { _,_ in }, onLeftTap: {}, onRightTap: {}, onDraggingChanged: { _ in }, onScroll: { scrolls.append($0) },
                                             onInteractionBegan: { began += 1; control.cancel() }))
        let first = Touch(), second = Touch()
        first.point = CGPoint(x: 40, y: 50); second.point = CGPoint(x: 80, y: 50)
        let normalEvent = Event(); normalEvent.contacts = [first]
        twoFingerMain.touchesBegan([first], with: normalEvent)
        normalEvent.contacts = [first, second]
        twoFingerMain.touchesBegan([second], with: normalEvent)
        first.point.y += 30; second.point.y += 30
        twoFingerMain.touchesMoved([first, second], with: normalEvent)
        check("each new main contact cancels only the tool contact", began == 2)
        check("normal main-surface two-finger scrolling remains intact", !scrolls.isEmpty)
        twoFingerMain.cancelInput()
        print("\(checks) native TV toolbar accessibility/contact checks passed; no windows or input injection.")
    }
}
