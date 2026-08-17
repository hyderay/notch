import Foundation

/// Wires agent hooks up to `notchctl`.
///
/// Everything here is additive and idempotent. If a config already has a
/// conflicting value the installer reports it instead of overwriting, because
/// these files belong to the user, not to this app.
public enum HookInstaller {
    public struct Report {
        public var messages: [String] = []
        public var didChange = false
        public var needsManualStep = false

        public init() {}

        mutating func note(_ message: String) { messages.append(message) }
    }

    /// Absolute path to the `notchctl` binary, preferring one already on PATH so
    /// the written config survives moving the app bundle.
    public static func notchctlPath() -> String {
        let candidates = [
            NotchPaths.home.appendingPathComponent(".local/bin/notchctl").path,
            "/usr/local/bin/notchctl",
            "/opt/homebrew/bin/notchctl",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let sibling = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/notchctl").path
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        return "notchctl"
    }

    public static func installAll() -> Report {
        var report = Report()
        installClaude(into: &report)
        installCodex(into: &report)
        return report
    }

    public static func uninstallAll() -> Report {
        var report = Report()
        removeClaude(into: &report)
        removeCodex(into: &report)
        return report
    }

    // MARK: - Claude Code

    /// Recognizes a previously installed hook. Matched as two separate
    /// fragments because the binary path is shell-quoted when it contains a
    /// space, which would otherwise split a single contiguous marker.
    private static func isNotchCommand(_ command: String) -> Bool {
        command.contains("notchctl") && command.contains("hook claude")
    }

    public static func installClaude(into report: inout Report) {
        let settingsURL = NotchPaths.claudeSettings
        guard FileManager.default.fileExists(atPath: NotchPaths.claudeHome.path) else {
            report.note("Claude Code not found (~/.claude missing); skipped.")
            return
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let binary = notchctlPath()
        var changed = false

        let wiring: [(event: String, matcher: String?, state: String, timeout: Int)] = [
            ("UserPromptSubmit", nil, "thinking", 5),
            ("PreToolUse", "*", "working", 5),
            ("PostToolUse", "*", "thinking", 5),
            ("PermissionRequest", nil, "permission", 3_600),
            ("Notification", nil, "waiting", 5),
            ("Stop", nil, "done", 5),
            ("SessionEnd", nil, "end", 5),
        ]

        for entry in wiring {
            let command = "\(shellQuote(binary)) hook claude \(entry.state)"
            var groups = hooks[entry.event] as? [[String: Any]] ?? []

            let alreadyPresent = groups.contains { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { isNotchCommand(($0["command"] as? String) ?? "") }
            }
            if alreadyPresent { continue }

            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": entry.timeout]]
            ]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[entry.event] = groups
            changed = true
        }

        guard changed else {
            report.note("Claude Code hooks already installed.")
            return
        }

        root["hooks"] = hooks
        do {
            try backup(settingsURL)
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: settingsURL, options: .atomic)
            report.didChange = true
            report.note("Installed Claude Code hooks into \(settingsURL.path)")
        } catch {
            report.needsManualStep = true
            report.note("Could not write \(settingsURL.path): \(error.localizedDescription)")
        }
    }

    public static func removeClaude(into report: inout Report) {
        let settingsURL = NotchPaths.claudeSettings
        guard let data = try? Data(contentsOf: settingsURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any]
        else {
            report.note("Nothing to remove from Claude Code settings.")
            return
        }

        var changed = false
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let filtered = groups.filter { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return true }
                return !inner.contains { isNotchCommand(($0["command"] as? String) ?? "") }
            }
            guard filtered.count != groups.count else { continue }
            changed = true
            if filtered.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filtered
            }
        }

        guard changed else {
            report.note("No Notch hooks found in Claude Code settings.")
            return
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        do {
            try backup(settingsURL)
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try out.write(to: settingsURL, options: .atomic)
            report.didChange = true
            report.note("Removed Notch hooks from \(settingsURL.path)")
        } catch {
            report.note("Could not write \(settingsURL.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Codex CLI

    public static func installCodex(into report: inout Report) {
        let configURL = NotchPaths.codexConfig
        guard FileManager.default.fileExists(atPath: NotchPaths.codexHome.path) else {
            report.note("Codex CLI not found (~/.codex missing); skipped.")
            return
        }

        let binary = notchctlPath()
        let desired = "notify = [\"\(binary)\", \"hook\", \"codex-notify\"]"

        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        if existing.contains("notchctl") {
            report.note("Codex notify already points at notchctl.")
            return
        }

        if let line = firstNotifyLine(in: existing) {
            report.needsManualStep = true
            report.note("""
            Codex already defines notify:
                \(line)
            Notch will not overwrite it. Codex status still works without this \
            (it is read from ~/.codex/sessions transcripts); the hook only adds a \
            more precise completion signal. To wire it up manually, chain your \
            existing program with:
                \(desired)
            """)
            return
        }

        do {
            try backup(configURL)
            var contents = existing
            if !contents.isEmpty, !contents.hasSuffix("\n") { contents += "\n" }
            // Prepend so the key lands in the root table rather than inside
            // whatever [section] happens to be last in the file.
            contents = desired + "\n" + contents
            try contents.write(to: configURL, atomically: true, encoding: .utf8)
            report.didChange = true
            report.note("Added notify hook to \(configURL.path)")
        } catch {
            report.needsManualStep = true
            report.note("Could not write \(configURL.path): \(error.localizedDescription)")
        }
    }

    public static func removeCodex(into report: inout Report) {
        let configURL = NotchPaths.codexConfig
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            report.note("Nothing to remove from Codex config.")
            return
        }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("notify") && trimmed.contains("notchctl"))
        }
        guard kept.count != lines.count else {
            report.note("No Notch notify hook found in Codex config.")
            return
        }
        do {
            try backup(configURL)
            try kept.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
            report.didChange = true
            report.note("Removed Notch notify hook from \(configURL.path)")
        } catch {
            report.note("Could not write \(configURL.path): \(error.localizedDescription)")
        }
    }

    /// Finds a top-level `notify = ...` assignment, ignoring comments.
    private static func firstNotifyLine(in contents: String) -> String? {
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("notify") , line.contains("=") { return line }
        }
        return nil
    }

    // MARK: - Helpers

    private static func backup(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let backupURL = url.appendingPathExtension("notch-backup")
        if fm.fileExists(atPath: backupURL.path) { try fm.removeItem(at: backupURL) }
        try fm.copyItem(at: url, to: backupURL)
    }

    private static func shellQuote(_ path: String) -> String {
        guard path.contains(" ") || path.contains("'") else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
