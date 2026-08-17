import AppKit
import NotchCore
import SwiftUI

extension Notification.Name {
    static let notchPanelVisibilityDidChange = Notification.Name(
        "com.wanquanlin.notch.panelVisibilityDidChange"
    )
}

/// Borderless overlay panel that floats above the menu bar on every Space.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Above .mainMenu (24) and .statusBar (25) so it can paint over the menu bar.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        publishVisibilityChange()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        publishVisibilityChange()
    }

    private func publishVisibilityChange() {
        NotificationCenter.default.post(name: .notchPanelVisibilityDidChange, object: self)
    }
}

/// Reports whether the cursor is over the overlay.
///
/// Driven by mouse-moved events rather than a timer, so a stationary cursor
/// costs nothing. Two monitors are needed: the global one sees movement while
/// another app is active, and the local one sees events that land in this
/// process once the cursor is over the panel.
///
/// An `NSTrackingArea` would be the conventional choice and does not work here:
/// expanding resizes the panel, AppKit rebuilds the tracking area, and each
/// rebuild emits a spurious exit/enter pair, so the overlay oscillates between
/// compact and expanded several times a second. Evaluating the cursor against
/// the frame avoids that, and the hit region is hysteretic — entering requires
/// the compact strip, leaving requires exiting the whole panel.
@MainActor
final class HoverMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let hitRegion: () -> CGRect?
    private let onChange: (Bool) -> Void
    private var isInside = false

    private static let movement: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    init(hitRegion: @escaping () -> CGRect?, onChange: @escaping (Bool) -> Void) {
        self.hitRegion = hitRegion
        self.onChange = onChange
    }

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.movement) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.movement) { [weak self] event in
            MainActor.assumeIsolated { self?.evaluate() }
            return event
        }
        // The overlay may have appeared under an already-stationary cursor.
        evaluate()
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if isInside {
            isInside = false
            onChange(false)
        }
    }

    /// Also called when the layout changes, since the panel can move out from
    /// under a cursor that never generates another event.
    func evaluate() {
        let loc = NSEvent.mouseLocation
        guard let region = hitRegion() else {
            if isInside {
                isInside = false
                onChange(false)
            }
            return
        }
        // Mouse movement elsewhere on the screen is the common case; skip the
        // contains test until the cursor is near the overlay.
        if !isInside, loc.y < region.minY - 48 { return }
        let inside = region.contains(loc)
        guard inside != isInside else { return }
        isInside = inside
        onChange(inside)
    }
}

/// Recognizes a deliberate two-finger vertical trackpad sweep over the island.
///
/// This monitor remains active after the panel is ordered out, allowing the same
/// gesture in the top-center hot zone to bring a dismissed island back.
@MainActor
final class TwoFingerSwipeMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let hitRegion: () -> CGRect?
    private let onSwipe: (IslandSwipeIntent) -> Void
    private var horizontalTotal: CGFloat = 0
    private var verticalTotal: CGFloat = 0
    private var didTrigger = false
    private var lastEventAt = Date.distantPast

    init(
        hitRegion: @escaping () -> CGRect?,
        onSwipe: @escaping (IslandSwipeIntent) -> Void
    ) {
        self.hitRegion = hitRegion
        self.onSwipe = onSwipe
    }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        reset()
    }

    private func handle(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        let now = Date()
        if event.phase.contains(.began) || now.timeIntervalSince(lastEventAt) > 0.3 {
            reset()
        }
        lastEventAt = now

        guard let region = hitRegion(), region.contains(NSEvent.mouseLocation) else {
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { reset() }
            return
        }

        // Remove the user's natural-scrolling preference so this represents
        // physical finger motion: positive Y is toward the top-screen notch.
        horizontalTotal += IslandSwipeGesture.physicalDelta(
            event.scrollingDeltaX,
            directionInverted: event.isDirectionInvertedFromDevice
        )
        verticalTotal += IslandSwipeGesture.physicalDelta(
            event.scrollingDeltaY,
            directionInverted: event.isDirectionInvertedFromDevice
        )
        if !didTrigger,
           let intent = IslandSwipeGesture.intent(vertical: verticalTotal, horizontal: horizontalTotal) {
            didTrigger = true
            onSwipe(intent)
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            reset()
        }
    }

    private func reset() {
        horizontalTotal = 0
        verticalTotal = 0
        didTrigger = false
    }
}
