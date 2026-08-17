import AppKit
import NotchCore
import SwiftUI

/// Session rows that hang below the compact strip while expanded.
struct ExpandedView: View {
    static let rowHeight: CGFloat = 48
    static let verticalPadding: CGFloat = 8
    static let maxRows = 5

    @ObservedObject var model: NotchViewModel

    private var snapshot: StoreSnapshot { model.snapshot }

    var body: some View {
        let live = snapshot.sessions.contains { $0.terminalAt == nil }
        Group {
            if live {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    rows(now: context.date)
                }
            } else {
                rows(now: Date())
            }
        }
    }

    private func rows(now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshot.sessions.prefix(Self.maxRows))) { session in
                SessionRow(
                    session: session,
                    now: now,
                    isHighlighted: model.hoveredSessionID == session.id,
                    onDecision: { decision in
                        model.resolvePermission(for: session, decision: decision)
                    }
                ) { hovering in
                    model.hoveredSessionID = hovering ? session.id : nil
                }
                .frame(height: Self.rowHeight)
            }
            if snapshot.sessions.count > Self.maxRows {
                Text("+\(snapshot.sessions.count - Self.maxRows) more")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .frame(width: model.geometry.expandedWidth)
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let now: Date
    let isHighlighted: Bool
    let onDecision: (PermissionDecision) -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(session.agent.displayName)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                Text(session.detail ?? session.state.displayName)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if session.state == .waiting, session.permissionRequestID != nil {
                PermissionButtons(onDecision: onDecision)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatElapsed(session.elapsed(now: now)))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText.opacity(0.85))
                    Text(session.state.displayName)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.color(for: session.state))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isHighlighted ? 0.07 : 0))
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture {
            guard let cwd = session.cwd, !cwd.isEmpty else { return }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
        }
        .help(session.cwd ?? session.title)
    }
}

private struct PermissionButtons: View {
    let onDecision: (PermissionDecision) -> Void

    var body: some View {
        HStack(spacing: 6) {
            action(title: "Deny", symbol: "xmark", color: Theme.color(for: .error)) {
                onDecision(.reject)
            }
            action(title: "Allow", symbol: "checkmark", color: Theme.color(for: .done)) {
                onDecision(.approve)
            }
        }
    }

    private func action(
        title: String,
        symbol: String,
        color: Color,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
    }
}
