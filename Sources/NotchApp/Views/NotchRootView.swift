import NotchCore
import SwiftUI

/// Root of the overlay: draws the black silhouette and switches between the
/// compact strip and the expanded panel.
///
/// Compact content keeps its identity when expanding so the timer does not
/// rebuild. Rows are appended underneath; only the silhouette size animates.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel

    private static let motion = Animation.spring(response: 0.16, dampingFraction: 0.92)

    private var silhouette: NotchShape {
        NotchShape(
            topRadius: model.geometry.topCornerRadius,
            bottomRadius: model.presentation == .expanded ? 20 : model.geometry.bottomCornerRadius
        )
    }

    var body: some View {
        let size = model.contentSize
        let visible = model.presentation != .hidden

        ZStack(alignment: .top) {
            silhouette
                .fill(Theme.body)
                .overlay {
                    silhouette
                        .stroke(
                            Color.white.opacity(model.presentation == .expanded ? 0.12 : 0.07),
                            lineWidth: 0.75
                        )
                }
                .frame(width: size.width, height: size.height)

            if visible {
                VStack(spacing: 0) {
                    CompactView(
                        snapshot: model.snapshot,
                        geometry: model.geometry,
                        showsRing: model.presentation != .expanded,
                        showsActivity: model.presentation == .compact
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.toggleManualExpansion()
                    }
                    if model.presentation == .expanded {
                        ExpandedView(model: model)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(silhouette)
            }
        }
        .frame(
            width: size.width + NotchViewModel.windowPadding.width * 2,
            height: size.height + NotchViewModel.windowPadding.height,
            alignment: .top
        )
        .opacity(visible ? 1 : 0)
        // Hidden <-> compact is handled by the panel reveal/order-out path.
        // Animating zero-size SwiftUI content while AppKit restores the window
        // from its parked 1pt frame causes a visible first-frame hitch.
        .animation(Self.motion, value: model.presentation == .expanded)
        .animation(Self.motion, value: model.snapshot.sessions.count)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
