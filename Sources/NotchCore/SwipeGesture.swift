import Foundation

public enum IslandSwipeIntent: Equatable, Sendable {
    case hide
    case show
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
        return vertical > 0 ? .hide : .show
    }
}
