import AppKit
import SwiftUI

/// The state arc used by `ProgressRing`.
///
/// This deliberately avoids long-running Core Animation. The panel sits above
/// the status-bar window, so an infinite animation makes WindowServer
/// composite the whole menu-bar stack at the display refresh rate. Instead a
/// low-rate timer advances a few discrete frames and stops with the view.
struct SpinnerArc: NSViewRepresentable {
    enum Motion: Equatable {
        /// A trimmed arc sweeping clockwise.
        case spin
        /// A full ring breathing in and out.
        case pulse
        /// A full ring, no animation.
        case still
    }

    let color: Color
    let lineWidth: CGFloat
    let motion: Motion

    func makeNSView(context: Context) -> SpinnerArcView {
        SpinnerArcView()
    }

    func updateNSView(_ view: SpinnerArcView, context: Context) {
        view.apply(color: NSColor(color), lineWidth: lineWidth, motion: motion)
    }
}

final class SpinnerArcView: NSView {
    private let arc = CAShapeLayer()
    private var motion: SpinnerArc.Motion = .still
    private var motionTimer: Timer?
    private var phase: CGFloat = 0
    private var pulseOn = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(arc)
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: .notchPanelVisibilityDidChange,
                object: window
            )
        }
        stopMotionTimer()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        arc.contentsScale = scale
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityChanged),
                name: .notchPanelVisibilityDidChange,
                object: window
            )
        }
        syncMotionTimer()
    }

    @objc private func windowVisibilityChanged() {
        syncMotionTimer()
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        arc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let inset = arc.lineWidth / 2
        arc.path = CGPath(ellipseIn: arc.bounds.insetBy(dx: inset, dy: inset), transform: nil)
    }

    func apply(color: NSColor, lineWidth: CGFloat, motion: SpinnerArc.Motion) {
        // Layer property changes carry an implicit animation by default, which
        // would make a state change fade rather than switch.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeColor = color.cgColor
        if arc.lineWidth != lineWidth {
            arc.lineWidth = lineWidth
            needsLayout = true
        }
        switch motion {
        case .spin:
            arc.strokeEnd = 0.68
            arc.opacity = 1
            arc.transform = CATransform3DMakeRotation(-Double.pi / 2, 0, 0, 1)
        case .pulse:
            arc.strokeEnd = 1
            arc.opacity = 0.72
            arc.transform = CATransform3DIdentity
        case .still:
            arc.strokeEnd = 1
            arc.opacity = 1
            arc.transform = CATransform3DIdentity
        }
        CATransaction.commit()

        if motion != self.motion {
            self.motion = motion
            phase = 0
            pulseOn = true
            syncMotionTimer()
        }
    }

    private func syncMotionTimer() {
        stopMotionTimer()
        guard window?.isVisible == true, motion != .still else { return }

        let interval: TimeInterval = motion == .spin ? 0.25 : 0.5
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceMotion() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func stopMotionTimer() {
        motionTimer?.invalidate()
        motionTimer = nil
    }

    private func advanceMotion() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch motion {
        case .spin:
            phase += .pi / 4
            arc.transform = CATransform3DMakeRotation(phase, 0, 0, 1)
        case .pulse:
            pulseOn.toggle()
            arc.opacity = pulseOn ? 1 : 0.45
        case .still:
            break
        }
        CATransaction.commit()
    }
}
