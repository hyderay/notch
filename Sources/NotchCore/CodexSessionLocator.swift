import Foundation

/// Finds the Codex session that a hook invocation belongs to.
///
/// Codex's `notify` program receives no session identity, only a JSON blob
/// about the turn. Matching on the working directory against the most recently
/// written rollout file recovers the id, which keeps the hook's event merged
/// into the same session the transcript watcher already tracks.
public enum CodexSessionLocator {
    public struct Match: Equatable {
        public let sessionID: String
        public let cwd: String?
    }

    public static func mostRecentSession(
        matchingCwd cwd: String?,
        now: Date = Date(),
        window: TimeInterval = 6 * 60 * 60
    ) -> Match? {
        let fm = FileManager.default
        let calendar = Calendar.current
        var candidates: [(url: URL, modified: Date)] = []

        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let directory = NotchPaths.codexSessions
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", dayOfMonth))
            guard let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where url.pathExtension == "jsonl" {
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                    now.timeIntervalSince(modified) <= window
                else { continue }
                candidates.append((url, modified))
            }
        }

        let ordered = candidates.sorted { $0.modified > $1.modified }
        var firstAny: Match?

        for candidate in ordered {
            guard let meta = readMeta(at: candidate.url) else { continue }
            if firstAny == nil { firstAny = meta }
            guard let cwd, !cwd.isEmpty else { return meta }
            if let metaCwd = meta.cwd, samePath(metaCwd, cwd) { return meta }
        }

        // No directory match; fall back to the newest session overall only when
        // the caller did not care about the directory.
        return cwd == nil ? firstAny : nil
    }

    /// Reads only the `session_meta` header, which Codex always writes first.
    static func readMeta(at url: URL) -> Match? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024), !head.isEmpty else { return nil }
        guard let newline = head.firstIndex(of: 0x0A) else { return nil }
        let lineData = head[head.startIndex..<newline]
        guard let line = String(data: lineData, encoding: .utf8),
              case let .some(event) = CodexRolloutParser.parse(line: line),
              case let .meta(sessionID, cwd, _) = event
        else { return nil }
        return Match(sessionID: sessionID, cwd: cwd.map(normalizeCwd))
    }

    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        let a = URL(fileURLWithPath: normalizeCwd(lhs)).standardizedFileURL.resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: normalizeCwd(rhs)).standardizedFileURL.resolvingSymlinksInPath().path
        return a == b
    }
}
