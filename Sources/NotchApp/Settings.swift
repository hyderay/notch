import Foundation

/// User preferences, backed by `UserDefaults` with environment overrides for
/// the debug switches described in DESIGN.md.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let hideInFullScreen = "hideInFullScreen"
        static let autoExpandOnAttention = "autoExpandOnAttention"
        static let watchCodex = "watchCodex"
        static let watchClaude = "watchClaude"
        static let forceVirtualNotch = "forceVirtualNotch"
        static let hapticFeedback = "hapticFeedback"
    }

    private init() {
        defaults.register(defaults: [
            Key.hideInFullScreen: true,
            Key.autoExpandOnAttention: true,
            Key.watchCodex: true,
            Key.watchClaude: true,
            Key.forceVirtualNotch: false,
            Key.hapticFeedback: true,
        ])
    }

    var hideInFullScreen: Bool {
        get { defaults.bool(forKey: Key.hideInFullScreen) }
        set { defaults.set(newValue, forKey: Key.hideInFullScreen) }
    }

    var autoExpandOnAttention: Bool {
        get { defaults.bool(forKey: Key.autoExpandOnAttention) }
        set { defaults.set(newValue, forKey: Key.autoExpandOnAttention) }
    }

    var watchCodex: Bool {
        get { defaults.bool(forKey: Key.watchCodex) }
        set { defaults.set(newValue, forKey: Key.watchCodex) }
    }

    var watchClaude: Bool {
        get { defaults.bool(forKey: Key.watchClaude) }
        set { defaults.set(newValue, forKey: Key.watchClaude) }
    }

    var hapticFeedback: Bool {
        get { defaults.bool(forKey: Key.hapticFeedback) }
        set { defaults.set(newValue, forKey: Key.hapticFeedback) }
    }

    var forceVirtualNotch: Bool {
        get {
            if ProcessInfo.processInfo.environment["NOTCH_FORCE_VIRTUAL"] == "1" { return true }
            return defaults.bool(forKey: Key.forceVirtualNotch)
        }
        set { defaults.set(newValue, forKey: Key.forceVirtualNotch) }
    }
}
