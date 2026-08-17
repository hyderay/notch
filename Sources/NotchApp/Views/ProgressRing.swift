import NotchCore
import SwiftUI

/// Static state indicator. Runtime activity is communicated by color only;
/// there is deliberately no continuously-running animation in the notch.
struct ProgressRing: View {
    let state: SessionState
    var diameter: CGFloat = 18

    private var tint: Color { Theme.color(for: state) }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint)
                .frame(width: diameter * 0.52, height: diameter * 0.52)
                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
        }
        .frame(width: diameter, height: diameter)
    }
}
