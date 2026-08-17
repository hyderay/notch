import Foundation

/// Finds rollout files that are still held open by a Codex CLI process.
///
/// Codex does not always append a terminal event when its TUI is killed. The
/// open rollout descriptor is the one reliable lifecycle signal available in
/// that case. Callers should only probe while a transcript reports active work.
public enum CodexProcessProbe {
    public static func openRolloutPaths(_ paths: [String]) -> Set<String>? {
        guard !paths.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-a", "-c", "codex", "-Fpn", "--"] + paths

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 || process.terminationStatus == 1
        else { return nil }

        return parsePaths(from: data)
    }

    static func parsePaths(from data: Data) -> Set<String> {
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return Set(output.split(separator: "\n").compactMap { line in
            guard line.first == "n" else { return nil }
            return String(line.dropFirst())
        })
    }
}
