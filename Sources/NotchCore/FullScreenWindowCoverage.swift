import CoreGraphics

/// Pure geometry used when an application does not expose AXFullScreen.
public enum FullScreenWindowCoverage {
    public static func coversDisplay(window: CGRect, display: CGRect) -> Bool {
        guard display.width > 0, display.height > 0 else { return false }
        let intersection = window.intersection(display)
        guard !intersection.isNull else { return false }

        let widthCoverage = intersection.width / display.width
        let heightCoverage = intersection.height / display.height
        let bottomAligned = abs(window.maxY - display.maxY) <= 4
        return widthCoverage >= 0.99 && heightCoverage >= 0.94 && bottomAligned
    }

    public static func coversEntireDisplay(window: CGRect, display: CGRect) -> Bool {
        guard display.width > 0, display.height > 0 else { return false }
        let tolerance: CGFloat = 4
        return abs(window.minX - display.minX) <= tolerance
            && abs(window.minY - display.minY) <= tolerance
            && abs(window.maxX - display.maxX) <= tolerance
            && abs(window.maxY - display.maxY) <= tolerance
    }

    /// Computes the union area instead of the bounding box, so two small
    /// windows on opposite corners cannot masquerade as one full-screen window.
    public static func collectivelyCoversDisplay(
        windows: [CGRect],
        display: CGRect,
        minimumAreaCoverage: CGFloat
    ) -> Bool {
        guard display.width > 0, display.height > 0 else { return false }
        let clipped = windows.map { $0.intersection(display) }.filter { !$0.isNull && !$0.isEmpty }
        guard !clipped.isEmpty else { return false }

        let tolerance: CGFloat = 4
        guard clipped.map(\.minX).min().map({ abs($0 - display.minX) <= tolerance }) == true,
              clipped.map(\.maxX).max().map({ abs($0 - display.maxX) <= tolerance }) == true,
              clipped.map(\.maxY).max().map({ abs($0 - display.maxY) <= tolerance }) == true
        else { return false }

        let xEdges = Array(Set(clipped.flatMap { [$0.minX, $0.maxX] })).sorted()
        var coveredArea: CGFloat = 0
        for (left, right) in zip(xEdges, xEdges.dropFirst()) where right > left {
            let intervals = clipped
                .filter { $0.minX < right && $0.maxX > left }
                .map { ($0.minY, $0.maxY) }
                .sorted { $0.0 < $1.0 }
            guard var merged = intervals.first else { continue }
            var coveredHeight: CGFloat = 0
            for interval in intervals.dropFirst() {
                if interval.0 <= merged.1 {
                    merged.1 = max(merged.1, interval.1)
                } else {
                    coveredHeight += merged.1 - merged.0
                    merged = interval
                }
            }
            coveredHeight += merged.1 - merged.0
            coveredArea += (right - left) * coveredHeight
        }

        return coveredArea / (display.width * display.height) >= minimumAreaCoverage
    }
}
