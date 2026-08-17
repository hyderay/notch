import Foundation

/// User preferences backed by `UserDefaults`.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let hideInFullScreen = "hideInFullScreen"
        static let autoExpandOnAttention = "autoExpandOnAttention"
        static let watchCodex = "watchCodex"
        static let watchClaude = "watchClaude"
        static let hapticFeedback = "hapticFeedback"
        static let swipeGestures = "swipeGestures"
    }

    private init() {
        defaults.register(defaults: [
            Key.hideInFullScreen: true,
            Key.autoExpandOnAttention: true,
            Key.watchCodex: true,
            Key.watchClaude: true,
            Key.hapticFeedback: true,
            Key.swipeGestures: true,
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

    var swipeGestures: Bool {
        get { defaults.bool(forKey: Key.swipeGestures) }
        set { defaults.set(newValue, forKey: Key.swipeGestures) }
    }
}
