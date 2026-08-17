import AppKit
import ApplicationServices
import NotchCore
import QuartzCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var model: NotchViewModel!
    private var panel: NotchPanel!
    private var hostingView: NSHostingView<NotchRootView>!
    private var hoverMonitor: HoverMonitor!
    private var twoFingerSwipeMonitor: TwoFingerSwipeMonitor!
    private var sources: [StatusSource] = []
    private var statusItem: NSStatusItem?
    private var pruneTimer: Timer?
    private var fullScreenUpdateWorkItems: [DispatchWorkItem] = []
    private var fullScreenActive = false
    private var fullScreenFadeGeneration: Int?
    private var fullScreenFadeWorkItem: DispatchWorkItem?

    /// Coalesces bursts of source updates into one main-thread refresh.
    private var refreshScheduled = false
    /// Invalidates pending shrink work when the layout changes again first.
    private var layoutGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        model = NotchViewModel(store: store)
        model.onLayoutChange = { [weak self] _ in self?.applyLayout() }
        model.onStateChange = { [weak self] in self?.publishDebugState() }
        model.onPermissionDecision = { [weak self] session, decision in
            self?.resolvePermission(for: session, decision: decision)
        }

        buildPanel()
        buildStatusItem()
        startSources()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(frontmostApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        Log.debug("started; notch=\(model.geometry.hasRealNotch ? "detected" : "unavailable") socket=\(NotchPaths.socket.path)")
        refreshFullScreenState()
        applyLayout()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pruneTimer?.invalidate()
        fullScreenUpdateWorkItems.forEach { $0.cancel() }
        fullScreenUpdateWorkItems.removeAll()
        fullScreenFadeWorkItem?.cancel()
        hoverMonitor?.stop()
        twoFingerSwipeMonitor?.stop()
        sources.forEach { $0.stop() }
        sources.removeAll()
    }

    // MARK: - Setup

    private func buildPanel() {
        hostingView = NSHostingView(rootView: NotchRootView(model: model))
        hostingView.wantsLayer = true

        panel = NotchPanel(contentRect: model.windowFrame)
        panel.contentView = hostingView
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)

        hoverMonitor = HoverMonitor(
            hitRegion: { [weak self] in self?.hoverHitRegion },
            onChange: { [weak self] hovering in
                Log.debug("hover: \(hovering)")
                self?.model.setHovering(hovering)
            }
        )
        twoFingerSwipeMonitor = TwoFingerSwipeMonitor(
            hitRegion: { [weak self] in self?.twoFingerSwipeHitRegion },
            onSwipe: { [weak self] intent in
                let hidden = intent == .hide
                Log.debug("two-finger swipe: \(hidden ? "hide" : "show")")
                self?.model.setGestureHidden(hidden)
            }
        )
        twoFingerSwipeMonitor.start()
    }

    /// Entering requires the cursor to be on the drawn strip; leaving requires
    /// it to exit the whole panel. Without that asymmetry, expanding would move
    /// the boundary out from under the cursor and immediately un-hover.
    private var hoverHitRegion: CGRect? {
        guard model.presentation != .hidden, !isHiddenForFullScreen else { return nil }
        let frame = panel.frame
        if model.isHovering { return frame.insetBy(dx: -10, dy: -10) }
        let content = model.contentSize
        // Extra height below the strip: the compact target is only ~32pt tall
        // and sits under the hardware notch, so a few points of slop makes
        // hover feel aimed rather than pixel-hunting.
        let enterSlop: CGFloat = 16
        return CGRect(
            x: frame.midX - content.width / 2,
            y: frame.maxY - content.height - enterSlop,
            width: content.width,
            height: content.height + enterSlop
        )
    }

    /// Stays available while gesture-hidden so a second sweep can restore it.
    private var twoFingerSwipeHitRegion: CGRect? {
        guard model.geometry.hasRealNotch,
              Settings.shared.swipeGestures,
              !model.snapshot.sessions.isEmpty,
              !isHiddenForFullScreen
        else { return nil }
        let geometry = model.geometry
        let height = geometry.notchHeight + CompactView.activityHeight + 12
        return CGRect(
            x: geometry.screenFrame.midX - geometry.bodyWidth / 2,
            y: geometry.screenFrame.maxY - height,
            width: geometry.bodyWidth,
            height: height
        )
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.menuBarImage
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let install = NSMenuItem(
            title: "Install agent hooks\u{2026}",
            action: #selector(installHooks),
            keyEquivalent: ""
        )
        install.target = self
        menu.addItem(install)

        let autoExpand = NSMenuItem(
            title: "Auto-expand when attention is needed",
            action: #selector(toggleAutoExpand),
            keyEquivalent: ""
        )
        autoExpand.target = self
        autoExpand.state = Settings.shared.autoExpandOnAttention ? .on : .off
        menu.addItem(autoExpand)

        let haptics = NSMenuItem(
            title: "Haptic feedback on hover",
            action: #selector(toggleHaptics),
            keyEquivalent: ""
        )
        haptics.target = self
        haptics.state = Settings.shared.hapticFeedback ? .on : .off
        menu.addItem(haptics)

        let swipeGestures = NSMenuItem(
            title: "Two-finger push to hide or show",
            action: #selector(toggleSwipeGestures),
            keyEquivalent: ""
        )
        swipeGestures.target = self
        swipeGestures.state = Settings.shared.swipeGestures ? .on : .off
        menu.addItem(swipeGestures)

        let hideInFullScreen = NSMenuItem(
            title: "Hide overlay in full screen",
            action: #selector(toggleHideInFullScreen),
            keyEquivalent: ""
        )
        hideInFullScreen.target = self
        hideInFullScreen.state = Settings.shared.hideInFullScreen ? .on : .off
        menu.addItem(hideInFullScreen)

        menu.addItem(.separator())

        let demo = NSMenuItem(title: "Run demo sequence", action: #selector(runDemo), keyEquivalent: "")
        demo.target = self
        menu.addItem(demo)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func startSources() {
        let onChange: () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }

        let ipc = IPCSource(store: store, onChange: onChange)
        ipc.snapshotHandler = { [weak self] path in
            self?.renderSnapshot(to: path) ?? "app is shutting down"
        }

        var started: [StatusSource] = [ipc]
        if Settings.shared.watchCodex {
            started.append(CodexFileSource(store: store, onChange: onChange))
        }
        if Settings.shared.watchClaude {
            started.append(ClaudeFileSource(store: store, onChange: onChange))
        }
        started.forEach { $0.start() }
        sources = started
    }

    /// Renders the overlay to a PNG without going through the window server.
    ///
    /// `screencapture` needs Screen Recording permission, which a terminal-
    /// hosted tool often does not have. Rendering the panel's own layer tree
    /// sidesteps that entirely, and the flat backdrop makes anything painting
    /// outside the black silhouette obvious.
    ///
    /// This renders the live layer tree rather than a fresh `ImageRenderer`
    /// pass over the SwiftUI view: `ImageRenderer` draws `NSViewRepresentable`
    /// content as an "unsupported" placeholder, which would hide the spinner.
    private func renderSnapshot(to path: String) -> String {
        guard model.presentation != .hidden else {
            return "overlay is hidden; start a session first"
        }
        guard let view = panel.contentView, let layer = view.layer else {
            return "overlay has no layer to render"
        }

        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return "overlay has no size" }

        let scale: CGFloat = 2
        guard let context = CGContext(
            data: nil,
            width: Int(size.width * scale),
            height: Int(size.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return "could not create a bitmap context"
        }

        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor(white: 0.42, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        // CoreGraphics puts the origin bottom-left; the layer tree assumes
        // top-left, so it comes out upside down without this.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)

        guard let image = context.makeImage() else { return "render failed" }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return "PNG encoding failed"
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return "could not write \(path): \(error.localizedDescription)"
        }
        return "wrote \(Int(size.width))x\(Int(size.height)) \(model.presentation) overlay to \(path)"
    }

    // MARK: - Refresh and layout

    @MainActor
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.model.refresh()
            self.syncPruneTimer()
        }
    }

    /// Expiry only matters while there is something to expire, so the timer
    /// exists only then — a one-shot aimed at the next eviction, not a 1 Hz poll.
    private func syncPruneTimer() {
        pruneTimer?.invalidate()
        pruneTimer = nil
        guard let date = store.nextPruneDate() else { return }
        let delay = max(0.05, date.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.store.prune() {
                    self.scheduleRefresh()
                } else {
                    self.syncPruneTimer()
                }
            }
        }
        timer.tolerance = min(1.0, max(0.1, delay * 0.25))
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    private func resolvePermission(for session: AgentSession, decision: PermissionDecision) {
        guard let requestID = session.permissionRequestID else { return }
        do {
            try PermissionBridge.resolve(requestID: requestID, decision: decision)
        } catch {
            Log.error("permission response failed: \(error)")
            return
        }
        let detail = decision == .approve ? "Permission approved" : "Permission rejected"
        if store.apply(
            SessionUpdate(
                agent: session.agent,
                sessionID: session.sessionID,
                state: .thinking,
                title: session.title,
                detail: detail,
                cwd: session.cwd,
                source: .ipc,
                timestamp: Date()
            )
        ) {
            scheduleRefresh()
        }
    }

    /// Resizes the panel around the animation instead of during it: grow first
    /// so a spring has room to overshoot, shrink only after it settles.
    private func applyLayout() {
        layoutGeneration += 1
        let generation = layoutGeneration
        let target = model.windowFrame

        if !model.geometry.hasRealNotch {
            cancelFullScreenFade()
            hoverMonitor.stop()
            model.setHovering(false)
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            panel.alphaValue = 1
            publishDebugState()
            return
        }

        if isHiddenForFullScreen {
            hoverMonitor.stop()
            model.setHovering(false)
            panel.ignoresMouseEvents = true
            fadeOutPanel(generation: generation)
            publishDebugState()
            return
        }

        cancelFullScreenFade()

        if model.presentation == .hidden {
            hoverMonitor.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.panel.ignoresMouseEvents = true
                self.panel.orderOut(nil)
                self.panel.setFrame(target, display: false)
                self.publishDebugState()
            }
            return
        }

        let needsReveal = !panel.isVisible
        panel.ignoresMouseEvents = false
        if needsReveal {
            revealPanel(at: target)
        } else {
            let grown = panel.frame.isEmpty ? target : panel.frame.union(target)
            panel.setFrame(grown, display: true)
            panel.orderFrontRegardless()
        }
        hoverMonitor.start()
        publishDebugState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.layoutGeneration == generation else { return }
            guard self.model.presentation != .hidden, !self.isHiddenForFullScreen else { return }
            self.panel.setFrame(self.model.windowFrame, display: false)
            self.hoverMonitor.evaluate()
            self.publishDebugState()
        }
    }

    /// Restores an ordered-out panel only after its final compact layout has
    /// rendered. This keeps AppKit's 1pt parked frame out of the visible path.
    private func revealPanel(at frame: CGRect) {
        panel.alphaValue = 0
        panel.setFrame(frame, display: false)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOutPanel(generation: Int) {
        guard panel.isVisible else {
            cancelFullScreenFade()
            panel.orderOut(nil)
            return
        }
        guard fullScreenFadeGeneration == nil else { return }
        fullScreenFadeGeneration = generation

        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.fullScreenFadeGeneration == generation,
                  self.isHiddenForFullScreen
            else { return }
            self.fullScreenFadeWorkItem = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                self.panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          self.fullScreenFadeGeneration == generation
                    else { return }
                    self.fullScreenFadeGeneration = nil
                    guard self.isHiddenForFullScreen else { return }
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                    self.publishDebugState()
                }
            }
        }
        fullScreenFadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func cancelFullScreenFade() {
        fullScreenFadeWorkItem?.cancel()
        fullScreenFadeWorkItem = nil
        fullScreenFadeGeneration = nil
        panel.alphaValue = 1
    }

    private func publishDebugState() {
        let presentation = model.presentation
        let geometry = model.geometry
        let snapshot = model.snapshot
        let frame = panel.frame
        let visible = panel.isVisible
        let contentSize = model.contentSize
        let hovering = model.isHovering
        let autoExpanding = model.wantsAutoExpand

        OverlayDebugState.shared.update { state in
            state.presentation = String(describing: presentation)
            state.hasRealNotch = geometry.hasRealNotch
            state.screenFrame = geometry.screenFrame
            state.voidWidth = geometry.voidWidth
            state.notchHeight = geometry.notchHeight
            state.sideWidth = geometry.sideWidth
            state.contentSize = contentSize
            state.windowFrame = frame
            state.isVisible = visible
            state.sessionCount = snapshot.sessions.count
            state.globalState = snapshot.globalState.rawValue
            state.isHovering = hovering
            state.autoExpanding = autoExpanding
            state.fullScreenActive = fullScreenActive
            state.hideInFullScreen = Settings.shared.hideInFullScreen
            state.gestureHidden = model.isGestureHidden
            state.swipeGestures = Settings.shared.swipeGestures
        }
    }

    private var isHiddenForFullScreen: Bool {
        Settings.shared.hideInFullScreen && fullScreenActive
    }

    private func refreshFullScreenState(allowReveal: Bool = true) {
        let next = FullScreenDetector.isFrontmostAppFullScreen(on: model.geometry.screenFrame)
        // Positive results are useful immediately. During a Space animation,
        // transient negative results would briefly reveal the panel over the
        // destination app, so only the last scheduled sample may reveal it.
        guard next || allowReveal else { return }

        let wasHidden = isHiddenForFullScreen
        fullScreenActive = next
        let hidden = isHiddenForFullScreen
        if hidden != wasHidden {
            Log.debug("full screen: \(next ? "active" : "inactive")")
            applyLayout()
        } else {
            publishDebugState()
        }
    }

    private func scheduleFullScreenRefresh() {
        fullScreenUpdateWorkItems.forEach { $0.cancel() }
        let delays: [TimeInterval] = [0.08, 0.35, 0.8, 1.4]
        fullScreenUpdateWorkItems = delays.enumerated().map { index, delay in
            let isFinalSample = index == delays.indices.last
            let work = DispatchWorkItem { [weak self] in
                self?.refreshFullScreenState(allowReveal: isFinalSample)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    @objc private func screenParametersChanged() {
        model.recomputeGeometry()
        scheduleFullScreenRefresh()
        applyLayout()
    }

    @objc private func activeSpaceChanged() {
        scheduleFullScreenRefresh()
    }

    @objc private func frontmostApplicationChanged() {
        scheduleFullScreenRefresh()
    }

    // MARK: - Menu actions

    @objc private func installHooks() {
        let report = HookInstaller.installAll()
        let alert = NSAlert()
        alert.messageText = report.didChange ? "Agent hooks updated" : "No changes made"
        alert.informativeText = report.messages.isEmpty
            ? "No supported agents were found."
            : report.messages.joined(separator: "\n\n")
        alert.alertStyle = report.needsManualStep ? .warning : .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleAutoExpand(_ sender: NSMenuItem) {
        Settings.shared.autoExpandOnAttention.toggle()
        sender.state = Settings.shared.autoExpandOnAttention ? .on : .off
    }

    @objc private func toggleHideInFullScreen(_ sender: NSMenuItem) {
        Settings.shared.hideInFullScreen.toggle()
        sender.state = Settings.shared.hideInFullScreen ? .on : .off
        refreshFullScreenState()
        applyLayout()
    }

    @objc private func toggleHaptics(_ sender: NSMenuItem) {
        Haptics.isEnabled.toggle()
        sender.state = Haptics.isEnabled ? .on : .off
        if Haptics.isEnabled { Haptics.overlayDidSnap() }
    }

    @objc private func toggleSwipeGestures(_ sender: NSMenuItem) {
        Settings.shared.swipeGestures.toggle()
        sender.state = Settings.shared.swipeGestures ? .on : .off
        if !Settings.shared.swipeGestures {
            model.resetGestureHidden()
        }
        publishDebugState()
    }

    @objc private func runDemo() {
        DemoDriver.run(store: store) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    /// Template glyph: a wide, shallow notch silhouette. Drawn once.
    private static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let body = NSRect(x: 1.5, y: 5.5, width: 15, height: 7)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: body, xRadius: 2.6, yRadius: 2.6).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private enum FullScreenDetector {
    static func isFrontmostAppFullScreen(on screenFrame: CGRect) -> Bool {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID != ProcessInfo.processInfo.processIdentifier,
              let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }

        let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let frontmostWindowBounds = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmostPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            return bounds
        }

        switch accessibilityFullScreenState(
            processID: frontmostPID,
            display: displayBounds,
            onScreenWindows: frontmostWindowBounds
        ) {
        case true:
            return true
        case false:
            // Some apps implement a custom full-screen window while reporting
            // AXFullScreen=false. Accept that only when it covers the complete
            // display; the looser fallback below would include maximized windows.
            return frontmostWindowBounds.contains {
                FullScreenWindowCoverage.coversEntireDisplay(window: $0, display: displayBounds)
            } || FullScreenWindowCoverage.collectivelyCoversDisplay(
                windows: frontmostWindowBounds,
                display: displayBounds,
                minimumAreaCoverage: 0.995
            )
        case nil:
            // Chrome composes its full-screen UI from several layer-0 surfaces
            // (content, toolbar, tab strip). No individual surface is tall
            // enough, but together they cover the same area as a native window.
            return frontmostWindowBounds.contains {
                FullScreenWindowCoverage.coversDisplay(window: $0, display: displayBounds)
            } || FullScreenWindowCoverage.collectivelyCoversDisplay(
                windows: frontmostWindowBounds,
                display: displayBounds,
                minimumAreaCoverage: 0.94
            )
        }
    }

    /// Checks every relevant window, not just the focused one. Chromium apps
    /// can move focus to a child or update the focused window before the actual
    /// full-screen window during a Space transition.
    private static func accessibilityFullScreenState(
        processID: pid_t,
        display: CGRect,
        onScreenWindows: [CGRect]
    ) -> Bool? {
        let application = AXUIElementCreateApplication(processID)
        var candidates: [(window: AXUIElement, mayLackFrame: Bool)] = []

        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            candidates.append((focusedValue as! AXUIElement, true))
        }

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success, let windows = windowsValue as? [AXUIElement] {
            candidates.append(contentsOf: windows.map { ($0, false) })
        }

        var foundRelevantState = false
        for candidate in candidates {
            if let frame = accessibilityFrame(of: candidate.window) {
                guard isMostlyOnDisplay(window: frame, display: display) else { continue }
                // AXWindows includes windows parked on other Spaces. Match the
                // candidate to Quartz's on-screen list before trusting it.
                guard candidate.mayLackFrame || onScreenWindows.contains(where: {
                    framesRepresentSameWindow($0, frame)
                }) else { continue }
            } else if !candidate.mayLackFrame {
                continue
            }

            guard let fullScreen = accessibilityBoolean(
                candidate.window,
                attribute: "AXFullScreen" as CFString
            ) else { continue }
            foundRelevantState = true
            if fullScreen { return true }
        }
        return foundRelevantState ? false : nil
    }

    private static func accessibilityBoolean(
        _ element: AXUIElement,
        attribute: CFString
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let number = value as? NSNumber
        else { return nil }
        return number.boolValue
    }

    /// Accessibility and Quartz both use a top-left global coordinate system
    /// for external application windows, so the frame can be compared directly
    /// with CGDisplayBounds.
    private static func accessibilityFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success, let positionValue,
              AXUIElementCopyAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func isMostlyOnDisplay(window: CGRect, display: CGRect) -> Bool {
        guard window.width > 0, window.height > 0 else { return false }
        let intersection = window.intersection(display)
        guard !intersection.isNull else { return false }
        return intersection.width * intersection.height >= window.width * window.height * 0.5
    }

    private static func framesRepresentSameWindow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 8
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

}
