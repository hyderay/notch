import AppKit
import Foundation

/// A thread-safe mirror of what the overlay is currently drawing.
///
/// The socket handler runs off the main thread and must not block on it, so the
/// UI publishes here whenever the layout changes and the handler just reads.
/// Exposed through `notchctl inspect`, which is the only way to verify geometry
/// on a machine where screen recording is not permitted.
final class OverlayDebugState: @unchecked Sendable {
    struct Snapshot {
        var presentation = "hidden"
        var hasRealNotch = false
        var screenFrame: CGRect = .zero
        var voidWidth: CGFloat = 0
        var notchHeight: CGFloat = 0
        var sideWidth: CGFloat = 0
        var contentSize: CGSize = .zero
        var windowFrame: CGRect = .zero
        var isVisible = false
        var sessionCount = 0
        var globalState = "idle"
        var isHovering = false
        var autoExpanding = false
        var fullScreenActive = false
        var hideInFullScreen = true
    }

    static let shared = OverlayDebugState()

    private let lock = NSLock()
    private var storage = Snapshot()

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func update(_ body: (inout Snapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }

    var asJSON: [String: Any] {
        let s = snapshot
        func rect(_ r: CGRect) -> [String: CGFloat] {
            ["x": r.origin.x, "y": r.origin.y, "w": r.width, "h": r.height]
        }
        return [
            "presentation": s.presentation,
            "hasRealNotch": s.hasRealNotch,
            "screenFrame": rect(s.screenFrame),
            "voidWidth": s.voidWidth,
            "notchHeight": s.notchHeight,
            "sideWidth": s.sideWidth,
            "contentSize": ["w": s.contentSize.width, "h": s.contentSize.height],
            "windowFrame": rect(s.windowFrame),
            "visible": s.isVisible,
            "sessionCount": s.sessionCount,
            "globalState": s.globalState,
            "hovering": s.isHovering,
            "autoExpanding": s.autoExpanding,
            "fullScreenActive": s.fullScreenActive,
            "hideInFullScreen": s.hideInFullScreen,
        ]
    }
}
