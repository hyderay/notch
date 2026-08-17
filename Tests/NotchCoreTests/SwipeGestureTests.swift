import Testing
@testable import NotchCore

@Suite("Island swipe gesture")
struct SwipeGestureTests {
    @Test("natural scrolling is normalized to physical finger motion")
    func naturalScrolling() {
        #expect(IslandSwipeGesture.physicalDelta(12, directionInverted: false) == 12)
        #expect(IslandSwipeGesture.physicalDelta(-12, directionInverted: true) == 12)
        #expect(IslandSwipeGesture.physicalDelta(-8, directionInverted: false) == -8)
        #expect(IslandSwipeGesture.physicalDelta(8, directionInverted: true) == -8)
    }

    @Test("motion toward the notch hides and motion away shows")
    func direction() {
        #expect(IslandSwipeGesture.intent(vertical: 30, horizontal: 2) == .hide)
        #expect(IslandSwipeGesture.intent(vertical: -30, horizontal: 2) == .show)
    }

    @Test("short and mostly horizontal gestures are ignored")
    func ignoredGestures() {
        #expect(IslandSwipeGesture.intent(vertical: 20, horizontal: 0) == nil)
        #expect(IslandSwipeGesture.intent(vertical: 30, horizontal: 28) == nil)
    }
}
