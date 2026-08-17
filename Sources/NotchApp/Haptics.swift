import AppKit

/// Force Touch trackpad feedback for opening the overlay by hover.
///
/// `NSHapticFeedbackManager` is a no-op on hardware without a Force Touch
/// trackpad and respects the system "Force Click and haptic feedback" setting,
/// so no capability check is needed here.
enum Haptics {
    /// Suppresses repeats when the overlay is toggled faster than the taps can
    /// be felt as distinct.
    private static let minimumInterval: TimeInterval = 0.25
    private static var lastFired: Date = .distantPast

    static var isEnabled: Bool {
        get { Settings.shared.hapticFeedback }
        set { Settings.shared.hapticFeedback = newValue }
    }

    /// A single crisp tap, matching the feel of snapping to an alignment guide.
    static func overlayDidExpand() {
        guard isEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFired) >= minimumInterval else { return }
        lastFired = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
