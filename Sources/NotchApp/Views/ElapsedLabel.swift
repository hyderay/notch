import AppKit
import NotchCore
import SwiftUI

/// Live elapsed-time text that updates itself.
///
/// A clock on the view model would redraw the whole overlay. `TimelineView`
/// only invalidates this label, and a terminal session is a static `Text` with
/// no timer at all. Compact mode uses an AppKit label whose one-second timer
/// changes only that label, avoiding a SwiftUI invalidation of the entire
/// status-bar-level panel. Expanded mode uses `TimelineView` while the user is
/// actively inspecting it.
struct ElapsedLabel: View {
    let start: Date
    var frozenAt: Date? = nil
    var compact: Bool = false

    var body: some View {
        Group {
            if let frozenAt {
                Text(text(at: frozenAt))
            } else if compact {
                CompactElapsedText(start: start)
            } else {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(text(at: context.date))
                }
            }
        }
        .monospacedDigit()
    }

    private func text(at date: Date) -> String {
        let interval = date.timeIntervalSince(start)
        return compact ? formatElapsedCompact(interval) : formatElapsed(interval)
    }
}

private struct CompactElapsedText: NSViewRepresentable {
    let start: Date

    func makeNSView(context: Context) -> CompactElapsedTextField {
        CompactElapsedTextField(start: start)
    }

    func updateNSView(_ view: CompactElapsedTextField, context: Context) {
        view.setStart(start)
    }

    static func dismantleNSView(_ view: CompactElapsedTextField, coordinator: Void) {
        view.stopClock()
    }
}

@MainActor
private final class CompactElapsedTextField: NSTextField {
    private var start: Date
    private var clock: Timer?

    init(start: Date) {
        self.start = start
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        alignment = .right
        maximumNumberOfLines = 1
        lineBreakMode = .byClipping
        textColor = NSColor.white.withAlphaComponent(0.85)
        let descriptor = NSFont.systemFont(ofSize: 11, weight: .medium)
            .fontDescriptor.withDesign(.rounded)
        font = descriptor.map { NSFont(descriptor: $0, size: 11) } ?? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        updateText(at: Date())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityChanged),
                name: .notchPanelVisibilityDidChange,
                object: window
            )
        }
        syncClock()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: .notchPanelVisibilityDidChange,
                object: window
            )
        }
        stopClock()
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowVisibilityChanged() {
        syncClock()
    }

    private func syncClock() {
        if window?.isVisible == true {
            startClock()
        } else {
            stopClock()
        }
    }

    func setStart(_ next: Date) {
        guard next != start else { return }
        start = next
        updateText(at: Date())
    }

    private func startClock() {
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateText(at: Date()) }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    private func updateText(at date: Date) {
        let next = formatElapsedCompact(date.timeIntervalSince(start))
        guard next != stringValue else { return }
        stringValue = next
    }
}
