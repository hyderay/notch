import AppKit
import Combine
import NotchCore

enum NotchPresentation: Equatable {
    case hidden
    case compact
    case expanded
}

/// Drives what the overlay shows: owns the snapshot, explicit expansion, and
/// auto-expansion when a session needs attention.
@MainActor
final class NotchViewModel: ObservableObject {
    /// Extra room around the content so spring overshoot is not clipped.
    static let windowPadding = CGSize(width: 10, height: 10)

    @Published private(set) var snapshot: StoreSnapshot = .empty
    @Published private(set) var presentation: NotchPresentation = .hidden
    @Published private(set) var geometry: NotchGeometry
    @Published var hoveredSessionID: String?
    private var manualExpansionLevel: IslandExpansionLevel?

    private let store: SessionStore
    private(set) var isHovering = false
    private var hoverWorkItem: DispatchWorkItem?
    private var autoExpandDeadline: Date?
    private var autoExpandTimer: Timer?
    private var lastGlobalState: SessionState = .idle

    /// Called whenever the window needs a new frame.
    var onLayoutChange: ((CGSize) -> Void)?
    /// Called after any observable change, including ones that do not resize
    /// the window, so diagnostics stay in sync.
    var onStateChange: (() -> Void)?
    var onPermissionDecision: ((AgentSession, PermissionDecision) -> Void)?

    init(store: SessionStore) {
        self.store = store
        self.geometry = NotchGeometry.current()
    }

    // MARK: - Data

    func refresh() {
        let next = store.snapshot()
        guard next != snapshot else { return }
        let previousState = lastGlobalState
        snapshot = next
        lastGlobalState = next.globalState
        if next.sessions.isEmpty {
            manualExpansionLevel = nil
            cancelAutoExpansion()
        }

        if Settings.shared.autoExpandOnAttention,
           next.globalState != previousState,
           next.globalState == .waiting || next.globalState == .error {
            scheduleAutoExpand(seconds: 4)
        }

        updatePresentation()
        onStateChange?()
    }

    func recomputeGeometry() {
        let next = NotchGeometry.current()
        guard next != geometry else { return }
        geometry = next
        onLayoutChange?(contentSize)
    }

    // MARK: - Hover

    func setHovering(_ hovering: Bool) {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        // Re-entering while a collapse is queued must cancel that collapse even
        // though `isHovering` is still true.
        if hovering == isHovering { return }

        if hovering {
            applyHover(true)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.applyHover(false)
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func applyHover(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if !hovering, presentation == .expanded {
            collapse()
        }
        onStateChange?()
    }

    func toggleManualExpansion() {
        guard presentation != .hidden else { return }
        if presentation == .expanded {
            setManualExpansionLevel(.compact)
        } else {
            setManualExpansionLevel(.expanded)
        }
        onStateChange?()
    }

    /// Moves one step through hidden, compact, and expanded in the swipe direction.
    func applyTwoFingerSwipe(_ intent: IslandSwipeIntent) {
        guard Settings.shared.swipeGestures, !snapshot.sessions.isEmpty else { return }
        let before = presentation
        let current: IslandExpansionLevel
        switch presentation {
        case .hidden: current = .hidden
        case .compact: current = .compact
        case .expanded: current = .expanded
        }

        guard let target = IslandSwipeGesture.nextLevel(from: current, intent: intent) else { return }

        setManualExpansionLevel(target)
        if presentation != before {
            Haptics.twoFingerSwipeDidTransition()
        }
        onStateChange?()
    }

    private func collapse() {
        setManualExpansionLevel(.compact)
    }

    private func setManualExpansionLevel(_ level: IslandExpansionLevel) {
        manualExpansionLevel = level
        cancelAutoExpansion()
        updatePresentation()
    }

    private func cancelAutoExpansion() {
        autoExpandDeadline = nil
        autoExpandTimer?.invalidate()
        autoExpandTimer = nil
    }

    // MARK: - Presentation

    private func scheduleAutoExpand(seconds: TimeInterval) {
        autoExpandDeadline = Date().addingTimeInterval(seconds)
        autoExpandTimer?.invalidate()
        autoExpandTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.autoExpandDeadline = nil
                self?.updatePresentation()
                self?.onStateChange?()
            }
        }
    }

    var wantsAutoExpand: Bool {
        guard let deadline = autoExpandDeadline else { return false }
        return deadline > Date()
    }

    private func updatePresentation() {
        let next: NotchPresentation
        if snapshot.sessions.isEmpty {
            next = .hidden
        } else if manualExpansionLevel == .hidden {
            next = .hidden
        } else if manualExpansionLevel == .expanded || wantsAutoExpand {
            next = .expanded
        } else {
            next = .compact
        }
        guard next != presentation else { return }
        presentation = next
        if next == .hidden {
            hoveredSessionID = nil
        }
        onLayoutChange?(contentSize)
    }

    var expansionLevel: Int {
        switch presentation {
        case .hidden: return 0
        case .compact: return 1
        case .expanded: return 2
        }
    }

    func resolvePermission(for session: AgentSession, decision: PermissionDecision) {
        onPermissionDecision?(session, decision)
    }

    // MARK: - Layout

    /// Size of the drawn overlay, excluding window padding.
    var contentSize: CGSize {
        switch presentation {
        case .hidden:
            return .zero
        case .compact:
            return CGSize(
                width: geometry.bodyWidth,
                height: geometry.notchHeight + CompactView.activityHeight
            )
        case .expanded:
            return CGSize(width: geometry.expandedWidth, height: expandedHeight)
        }
    }

    var expandedHeight: CGFloat {
        let rows = max(1, min(snapshot.sessions.count, 5))
        return geometry.notchHeight + CGFloat(rows) * ExpandedView.rowHeight + ExpandedView.verticalPadding * 2
    }

    /// Window frame including padding, positioned at the top center.
    var windowFrame: CGRect {
        let content = contentSize
        guard content != .zero else {
            // A zero-size window is illegal; park a 1pt window off to the side.
            return CGRect(x: geometry.screenFrame.midX, y: geometry.screenFrame.maxY - 1, width: 1, height: 1)
        }
        let size = CGSize(
            width: content.width + Self.windowPadding.width * 2,
            height: content.height + Self.windowPadding.height
        )
        return geometry.windowFrame(contentSize: size)
    }
}
