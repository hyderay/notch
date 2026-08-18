import Foundation

public enum IslandSwipeIntent: Equatable, Sendable {
    case towardNotch
    case awayFromNotch
}

public enum IslandExpansionLevel: Int, Equatable, Sendable {
    case hidden = 0
    case compact = 1
    case expanded = 2
}

public enum IslandSwipeGesture {
    /// Converts a system scroll delta back into physical finger direction.
    public static func physicalDelta(_ delta: CGFloat, directionInverted: Bool) -> CGFloat {
        directionInverted ? -delta : delta
    }

    /// Positive vertical motion points toward the top-screen notch.
    public static func intent(
        vertical: CGFloat,
        horizontal: CGFloat,
        threshold: CGFloat = 24
    ) -> IslandSwipeIntent? {
        guard abs(vertical) >= threshold, abs(vertical) > abs(horizontal) * 1.2 else { return nil }
        return vertical > 0 ? .towardNotch : .awayFromNotch
    }

    /// Each deliberate swipe changes exactly one expansion level.
    public static func nextLevel(
        from level: IslandExpansionLevel,
        intent: IslandSwipeIntent
    ) -> IslandExpansionLevel? {
        switch (intent, level) {
        case (.towardNotch, .expanded): return .compact
        case (.towardNotch, .compact): return .hidden
        case (.awayFromNotch, .hidden): return .compact
        case (.awayFromNotch, .compact): return .expanded
        default: return nil
        }
    }
}
