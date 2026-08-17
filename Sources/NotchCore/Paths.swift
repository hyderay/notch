import Foundation

/// Filesystem locations the app and CLI agree on.
///
/// Every path is a `static let`, resolved once. These were computed properties,
/// which meant each access rebuilt `ProcessInfo.environment` — a dictionary of
/// the entire process environment. The file watchers touch them several times a
/// second, and that alone was most of the app's idle CPU. The environment
/// cannot change mid-process, so resolving once is safe.
public enum NotchPaths {
    private static let environment = ProcessInfo.processInfo.environment

    private static func override(_ key: String, isDirectory: Bool = false) -> URL? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: isDirectory)
    }

    public static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    /// `~/.notch` — created with 0700 on demand.
    public static let stateDirectory = home.appendingPathComponent(".notch", isDirectory: true)

    /// `~/.notch/notch.sock`
    ///
    /// Overridable via `NOTCH_SOCKET` so tests and multiple dev instances can
    /// coexist without stomping on the user's real socket.
    public static let socket = override("NOTCH_SOCKET")
        ?? stateDirectory.appendingPathComponent("notch.sock")

    public static let codexHome = override("CODEX_HOME", isDirectory: true)
        ?? home.appendingPathComponent(".codex", isDirectory: true)

    public static let codexSessions = codexHome.appendingPathComponent("sessions", isDirectory: true)

    public static let codexConfig = codexHome.appendingPathComponent("config.toml")

    /// Claude Code honors `CLAUDE_CONFIG_DIR`, so follow it.
    public static let claudeHome = override("CLAUDE_CONFIG_DIR", isDirectory: true)
        ?? home.appendingPathComponent(".claude", isDirectory: true)

    public static let claudeProjects = claudeHome.appendingPathComponent("projects", isDirectory: true)

    public static let claudeSettings = claudeHome.appendingPathComponent("settings.json")

    /// Creates `~/.notch` with owner-only permissions if it does not exist.
    @discardableResult
    public static func ensureStateDirectory() -> Bool {
        let dir = stateDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return false
            }
        }
        return true
    }
}

/// Best-effort short label for a working directory.
public func projectLabel(forPath path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let name = URL(fileURLWithPath: path).lastPathComponent
    if name.isEmpty || name == "/" { return nil }
    return name
}
