import AppKit

/// Where and how big the notch overlay should be drawn.
///
/// Two modes exist. With a real notch, the overlay grows out of the hardware
/// cutout and must keep its content clear of the cutout itself. Without one
/// (external display, older Mac, closed lid) it degrades to a centered pill
/// hanging from the top edge.
struct NotchGeometry: Equatable {
    /// Full frame of the screen the overlay lives on, in AppKit coordinates.
    var screenFrame: CGRect
    var hasRealNotch: Bool
    /// Width of the hardware cutout; zero in virtual mode.
    var voidWidth: CGFloat
    /// Vertical extent of the overlay's top strip.
    var notchHeight: CGFloat
    /// Width available for content on each side of the void.
    var sideWidth: CGFloat

    /// Width of the compact overlay.
    var bodyWidth: CGFloat { voidWidth + sideWidth * 2 }

    /// Width of the expanded panel.
    var expandedWidth: CGFloat { max(bodyWidth, 420) }

    /// Outer concave radius where the overlay blends into the screen edge.
    var topCornerRadius: CGFloat { hasRealNotch ? 8 : 0 }
    var bottomCornerRadius: CGFloat { hasRealNotch ? 12 : 12 }

    /// Screens with a cutout report a non-zero top safe area inset.
    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    static func current(forceVirtual: Bool = false) -> NotchGeometry {
        let notched = forceVirtual ? nil : notchedScreen()
        if let screen = notched {
            return real(screen: screen)
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        return virtual(screen: screen)
    }

    private static func real(screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let height = max(screen.safeAreaInsets.top, 24)

        var width: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = frame.width - left.width - right.width
        } else {
            // Empirical ratio across the 14"/16" notched MacBook Pro line.
            width = frame.width * 0.1565
        }
        width = min(max(width, 160), 260)

        return NotchGeometry(
            screenFrame: frame,
            hasRealNotch: true,
            voidWidth: width,
            notchHeight: height,
            // Wide enough for the session-count badge next to a five-character
            // timer once the outer inset is taken off.
            sideWidth: 76
        )
    }

    private static func virtual(screen: NSScreen?) -> NotchGeometry {
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menuBarHeight: CGFloat
        if let screen {
            menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        } else {
            menuBarHeight = NSStatusBar.system.thickness
        }
        return NotchGeometry(
            screenFrame: frame,
            hasRealNotch: false,
            voidWidth: 0,
            notchHeight: min(max(menuBarHeight, 22), 32),
            sideWidth: 120
        )
    }

    /// Places a content box of `size` flush against the top center of the screen.
    func windowFrame(contentSize: CGSize) -> CGRect {
        CGRect(
            x: (screenFrame.midX - size(contentSize).width / 2).rounded(),
            y: (screenFrame.maxY - size(contentSize).height).rounded(),
            width: size(contentSize).width.rounded(),
            height: size(contentSize).height.rounded()
        )
    }

    private func size(_ requested: CGSize) -> CGSize {
        CGSize(
            width: min(requested.width, screenFrame.width),
            height: min(requested.height, screenFrame.height)
        )
    }
}
