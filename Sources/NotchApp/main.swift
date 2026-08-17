import AppKit

// AppKit lifecycle rather than a SwiftUI `@main App`: the overlay needs an
// accessory activation policy and a fully custom NSPanel, and this stays
// predictable when built by SwiftPM without Xcode.
// Top-level code is nonisolated, but this all runs on the main thread before
// the run loop starts.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    // Retain the delegate for the process lifetime; NSApplication does not.
    objc_setAssociatedObject(application, "notch.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    application.setActivationPolicy(.accessory)
    application.run()
}
