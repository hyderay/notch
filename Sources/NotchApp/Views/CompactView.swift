import NotchCore
import SwiftUI

/// The resting presentation: a slim strip that reads as the notch having grown
/// sideways. Content stays clear of the hardware cutout by reserving
/// `voidWidth` in the middle.
struct CompactView: View {
    static let activityHeight: CGFloat = 24

    let snapshot: StoreSnapshot
    let geometry: NotchGeometry
    /// Expanded header leaves the hardware-notch row empty.
    var showsRing: Bool = true
    var showsActivity: Bool = true

    private var state: SessionState { snapshot.globalState }

    /// Distance from the outer edge of the strip to the content.
    ///
    /// Must clear the concave flare at the top corners: below the flare the
    /// black body starts `topCornerRadius` in from the frame, so content laid
    /// out at the frame edge would spill onto the wallpaper.
    private var outerInset: CGFloat {
        geometry.topCornerRadius + 8
    }

    /// Content width available on each side of the cutout.
    private var contentWidth: CGFloat {
        max(0, geometry.sideWidth - outerInset)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.leading, outerInset)

                if geometry.voidWidth > 0 {
                    Color.clear.frame(width: geometry.voidWidth)
                }

                trailing
                    .frame(width: contentWidth, alignment: .trailing)
                    .padding(.trailing, outerInset)
            }
            .frame(width: geometry.bodyWidth, height: geometry.notchHeight)

            if showsActivity {
                Text(activityText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.primaryText.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: geometry.bodyWidth - 38)
                    .frame(height: Self.activityHeight, alignment: .top)
            }
        }
        .frame(
            width: geometry.bodyWidth,
            height: geometry.notchHeight + (showsActivity ? Self.activityHeight : 0),
            alignment: .top
        )
    }

    private var activityText: String {
        guard let session = snapshot.sessions.first else { return state.displayName }
        return session.detail ?? session.state.displayName
    }

    private var leading: some View {
        HStack(spacing: 6) {
            if showsRing {
                ProgressRing(state: state)
                    // The compact body extends below the hardware-notch row for
                    // the activity label. Centre the status light across that
                    // full height instead of leaving it near the top edge.
                    .offset(y: showsActivity ? Self.activityHeight / 2 : 0)
            }
            if !geometry.hasRealNotch, let session = snapshot.sessions.first {
                Text(session.agent.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var trailing: some View {
        HStack(spacing: 5) {
            if showsRing, snapshot.sessions.count > 1 {
                Text("\(snapshot.sessions.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText.opacity(0.9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            if showsRing, let start = snapshot.leadStartedAt {
                ElapsedLabel(start: start, frozenAt: frozenAt, compact: true)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .offset(y: showsActivity ? Self.activityHeight / 2 : 0)
            } else if showsRing {
                Text(state.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }

    /// Freeze the compact timer once nothing is busy, matching `AgentSession.elapsed`.
    private var frozenAt: Date? {
        guard snapshot.busyCount == 0 else { return nil }
        if let start = snapshot.leadStartedAt,
           let match = snapshot.sessions.first(where: { $0.startedAt == start })?.terminalAt {
            return match
        }
        return snapshot.sessions.first?.terminalAt
    }
}
