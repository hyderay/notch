import SwiftUI

/// The overlay silhouette: flush with the top screen edge, rounded at the
/// bottom, and flared with concave curves at the top corners so it reads as an
/// extension of the hardware cutout rather than a floating rectangle.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        guard width > 0, height > 0 else { return path }

        // Radii must fit; a short overlay would otherwise self-intersect.
        let top = max(0, min(topRadius, width / 4, height / 2))
        let bottom = max(0, min(bottomRadius, (width - top * 2) / 2, height - top))

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        if top > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                control: CGPoint(x: rect.minX + top, y: rect.minY)
            )
        }

        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        if bottom > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + top, y: rect.maxY)
            )
        }

        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        if bottom > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - top, y: rect.maxY)
            )
        }

        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        if top > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rect.maxX - top, y: rect.minY)
            )
        }

        path.closeSubpath()
        return path
    }
}
