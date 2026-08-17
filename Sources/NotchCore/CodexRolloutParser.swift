import Foundation

/// The subset of Codex rollout events that affect displayed status.
public enum CodexRolloutEvent: Equatable {
    case meta(sessionID: String, cwd: String?, startedAt: Date?)
    case taskStarted(at: Date?)
    case taskComplete(at: Date?)
    case item(detail: String?, at: Date?)
    case aborted(at: Date?)
    case failure(message: String, at: Date?)
}

/// Parses `~/.codex/sessions/**/rollout-*.jsonl` lines.
///
/// Every field is optional on purpose: the rollout schema is internal to Codex
/// and shifts between releases, so an unrecognized line is skipped rather than
/// treated as an error.
public enum CodexRolloutParser {
    public static func parse(line: String) -> CodexRolloutEvent? {
        guard let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = root["type"] as? String
        else { return nil }

        let timestamp = parseTimestamp(root["timestamp"])

        switch type {
        case "session_meta":
            guard let payload = root["payload"] as? [String: Any] else { return nil }
            let sessionID = (payload["session_id"] as? String) ?? (payload["id"] as? String)
            guard let sessionID, !sessionID.isEmpty else { return nil }
            let cwd = payload["cwd"] as? String
            let startedAt = parseTimestamp(payload["timestamp"]) ?? timestamp
            return .meta(sessionID: sessionID, cwd: cwd, startedAt: startedAt)

        case "event_msg":
            guard let payload = root["payload"] as? [String: Any],
                  let kind = payload["type"] as? String
            else { return nil }
            switch kind {
            case "task_started":
                return .taskStarted(at: timestamp)
            case "task_complete":
                return .taskComplete(at: timestamp)
            case "turn_aborted", "task_aborted":
                return .aborted(at: timestamp)
            case "error", "stream_error":
                let message = (payload["message"] as? String) ?? "error"
                return .failure(message: message, at: timestamp)
            case "item_completed", "item_started", "item_updated":
                let item = payload["item"] as? [String: Any]
                return .item(detail: describe(item: item), at: timestamp)
            default:
                return nil
            }

        default:
            return nil
        }
    }

    /// Turns a rollout item into a one-line "what is it doing" description.
    static func describe(item: [String: Any]?) -> String? {
        guard let item, let type = item["type"] as? String else { return nil }
        switch type {
        case "CommandExecution":
            if let parsed = item["parsed_cmd"] as? [[String: Any]],
               let summary = summarize(parsedCommands: parsed) {
                return summary
            }
            if let command = item["command"] as? [String] {
                return "Run " + shortCommand(command)
            }
            return "Running a command"
        case "FileChange":
            if let changes = item["changes"] as? [[String: Any]], !changes.isEmpty {
                let names = changes.compactMap { change -> String? in
                    guard let path = change["path"] as? String else { return nil }
                    return URL(fileURLWithPath: path).lastPathComponent
                }
                if let first = names.first {
                    return names.count > 1 ? "Editing \(first) +\(names.count - 1)" : "Editing \(first)"
                }
            }
            return "Editing files"
        case "Reasoning":
            return "Thinking"
        case "AgentMessage":
            return "Writing a response"
        case "UserMessage":
            return nil
        case "ContextCompaction":
            return "Compacting context"
        case "WebSearch":
            if let query = item["query"] as? String, !query.isEmpty {
                return "Searching \(truncate(query, 32))"
            }
            return "Searching the web"
        case "McpToolCall":
            let server = item["server"] as? String
            let tool = item["tool"] as? String
            let name = [server, tool].compactMap { $0 }.joined(separator: ".")
            return name.isEmpty ? "Calling a tool" : "Calling \(name)"
        case "TodoList":
            return "Updating the plan"
        case "Error":
            return "Error"
        default:
            return nil
        }
    }

    private static func summarize(parsedCommands: [[String: Any]]) -> String? {
        guard let first = parsedCommands.first, let type = first["type"] as? String else { return nil }
        switch type {
        case "read":
            if let name = (first["name"] as? String) ?? (first["path"] as? String) {
                return "Reading \(URL(fileURLWithPath: name).lastPathComponent)"
            }
            return "Reading a file"
        case "list_files":
            return "Listing files"
        case "search":
            if let query = first["query"] as? String, !query.isEmpty {
                return "Searching \(truncate(query, 32))"
            }
            return "Searching"
        case "test":
            return "Running tests"
        case "lint":
            return "Linting"
        case "format":
            return "Formatting"
        default:
            if let cmd = first["cmd"] as? String, !cmd.isEmpty {
                return "Run \(truncate(cmd, 40))"
            }
            return nil
        }
    }

    /// Unwraps the `zsh -lc "<script>"` shape Codex uses for shell calls.
    private static func shortCommand(_ command: [String]) -> String {
        guard !command.isEmpty else { return "command" }
        if command.count >= 3,
           let shell = command.first,
           shell.hasSuffix("sh"),
           command[1].hasPrefix("-") {
            return truncate(command[2], 40)
        }
        return truncate(command.joined(separator: " "), 40)
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "\u{2026}"
    }

    static func parseTimestamp(_ raw: Any?) -> Date? {
        if let string = raw as? String {
            return ISO8601DateFormatter.notchParse(string)
        }
        if let number = raw as? Double, number > 0 {
            return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1000 : number)
        }
        return nil
    }
}

extension ISO8601DateFormatter {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Codex writes fractional seconds; Claude sometimes does not.
    static func notchParse(_ string: String) -> Date? {
        withFractional.date(from: string) ?? plain.date(from: string)
    }
}

/// Folds a stream of rollout events into the current state of one Codex session.
public final class CodexSessionTracker {
    public private(set) var sessionID: String?
    public private(set) var cwd: String?
    public private(set) var startedAt: Date?
    public private(set) var state: SessionState = .idle
    public private(set) var detail: String?
    public private(set) var lastEventAt: Date?

    /// Fallback identity when the transcript has not yet emitted `session_meta`.
    private let fallbackID: String

    public init(fallbackID: String) {
        self.fallbackID = fallbackID
    }

    public func consume(line: String, now: Date = Date()) {
        guard let event = CodexRolloutParser.parse(line: line) else { return }
        switch event {
        case let .meta(sessionID, cwd, startedAt):
            self.sessionID = sessionID
            if let cwd { self.cwd = normalizeCwd(cwd) }
            self.startedAt = startedAt
            lastEventAt = startedAt ?? now
        case let .taskStarted(at):
            state = .working
            detail = "Thinking"
            lastEventAt = at ?? now
        case let .taskComplete(at):
            state = .done
            detail = nil
            lastEventAt = at ?? now
        case let .aborted(at):
            state = .idle
            detail = nil
            lastEventAt = at ?? now
        case let .failure(message, at):
            state = .error
            detail = CodexRolloutParser.truncate(message, 48)
            lastEventAt = at ?? now
        case let .item(itemDetail, at):
            // Items also arrive while idle (e.g. a queued user message); they
            // refresh the label but must not resurrect a finished turn.
            if state.isBusy, let itemDetail { detail = itemDetail }
            lastEventAt = at ?? now
        }
    }

    public func update(fileModifiedAt: Date, now: Date = Date()) -> SessionUpdate? {
        guard state != .idle || detail != nil else { return nil }
        let timestamp = max(lastEventAt ?? fileModifiedAt, fileModifiedAt)
        return SessionUpdate(
            agent: .codex,
            sessionID: sessionID ?? fallbackID,
            state: state,
            title: projectLabel(forPath: cwd) ?? "codex",
            detail: detail,
            cwd: cwd,
            source: .file,
            timestamp: min(timestamp, now),
            startedAt: startedAt
        )
    }

    /// Removes a busy session whose Codex process disappeared without writing a
    /// terminal rollout event. A later `task_started` can reuse this tracker if
    /// Codex resumes and appends to the same file.
    public func processExited(now: Date = Date()) -> SessionUpdate? {
        guard state.isBusy else { return nil }
        state = .idle
        detail = nil
        lastEventAt = now
        return SessionUpdate(
            agent: .codex,
            sessionID: sessionID ?? fallbackID,
            state: .idle,
            title: projectLabel(forPath: cwd) ?? "codex",
            cwd: cwd,
            source: .file,
            timestamp: now,
            remove: true,
            startedAt: startedAt
        )
    }
}

/// Codex writes `cwd` as either a plain path or a `file://` URL.
func normalizeCwd(_ raw: String) -> String {
    guard raw.hasPrefix("file://") else { return raw }
    if let url = URL(string: raw), url.isFileURL { return url.path }
    return raw
}
