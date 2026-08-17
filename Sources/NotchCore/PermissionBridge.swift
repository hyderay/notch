import Foundation

/// Small file-backed response channel used by hooks that must wait for a
/// decision while the Notch remains a normal, non-blocking UI process.
public enum PermissionBridge {
    public static func prepare(requestID: String) {
        NotchPaths.ensureStateDirectory()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(at: url(for: requestID))
    }

    public static func resolve(requestID: String, decision: PermissionDecision) throws {
        prepare(requestID: requestID)
        let url = url(for: requestID)
        try Data(decision.rawValue.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func wait(for requestID: String, timeout: TimeInterval = 900) -> PermissionDecision? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? String(contentsOf: url(for: requestID), encoding: .utf8),
               let decision = PermissionDecision(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                try? FileManager.default.removeItem(at: url(for: requestID))
                return decision
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? FileManager.default.removeItem(at: url(for: requestID))
        return nil
    }

    private static let directory = NotchPaths.stateDirectory.appendingPathComponent("permissions", isDirectory: true)

    private static func url(for requestID: String) -> URL {
        let safe = requestID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent(safe.isEmpty ? "request" : safe)
    }
}

public enum PermissionDecision: String, Codable, Sendable {
    case approve
    case reject
}
