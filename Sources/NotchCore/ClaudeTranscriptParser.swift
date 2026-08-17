import Foundation

/// The subset of Claude Code transcript entries that affect displayed status.
public enum ClaudeTranscriptEvent: Equatable {
    case userPrompt(at: Date?)
    case toolResult(at: Date?)
    case assistantTool(detail: String?, at: Date?)
    case assistantText(at: Date?)
    case meta(sessionID: String?, cwd: String?, at: Date?)
}

/// Parses `~/.claude/projects/<slug>/<session>.jsonl` lines.
///
/// Claude Code has no explicit turn markers in the transcript, so the state is
/// inferred from the shape of the last entry. Hook-driven IPC events supersede
/// this whenever they are available.
public enum ClaudeTranscriptParser {
    public static func parse(line: String) -> ClaudeTranscriptEvent? {
        guard let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // Sidechains are sub-agent transcripts; they would double-count turns.
        if root["isSidechain"] as? Bool == true { return nil }

        let timestamp = CodexRolloutParser.parseTimestamp(root["timestamp"])
        let type = root["type"] as? String

        // Every entry carries identity; surface it so the first line seen wins.
        let sessionID = root["sessionId"] as? String
        let cwd = root["cwd"] as? String
        if type == nil || type == "summary" || type == "system" {
            if sessionID != nil || cwd != nil {
                return .meta(sessionID: sessionID, cwd: cwd, at: timestamp)
            }
            return nil
        }

        let blocks = contentBlocks(root["message"])

        switch type {
        case "user":
            if root["isMeta"] as? Bool == true { return nil }
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                return .toolResult(at: timestamp)
            }
            return .userPrompt(at: timestamp)

        case "assistant":
            if let toolUse = blocks.first(where: { $0["type"] as? String == "tool_use" }) {
                return .assistantTool(detail: describe(toolUse: toolUse), at: timestamp)
            }
            return .assistantText(at: timestamp)

        default:
            return nil
        }
    }

    /// `message.content` is either a plain string or an array of typed blocks.
    private static func contentBlocks(_ message: Any?) -> [[String: Any]] {
        guard let message = message as? [String: Any] else { return [] }
        if let blocks = message["content"] as? [[String: Any]] { return blocks }
        if let text = message["content"] as? String, !text.isEmpty {
            return [["type": "text", "text": text]]
        }
        return []
    }

    static func describe(toolUse: [String: Any]) -> String? {
        guard let name = toolUse["name"] as? String, !name.isEmpty else { return nil }
        let input = toolUse["input"] as? [String: Any] ?? [:]

        let argument: String?
        switch name {
        case "Bash":
            argument = input["command"] as? String
        case "Read", "Write", "NotebookEdit":
            argument = (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        case "Edit", "MultiEdit":
            argument = (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        case "Grep":
            argument = input["pattern"] as? String
        case "Glob":
            argument = input["pattern"] as? String
        case "WebFetch":
            argument = (input["url"] as? String).flatMap { URL(string: $0)?.host }
        case "WebSearch":
            argument = input["query"] as? String
        case "Task":
            argument = input["description"] as? String
        default:
            argument = nil
        }

        guard let argument, !argument.isEmpty else { return name }
        return "\(name): \(CodexRolloutParser.truncate(argument, 34))"
    }
}

/// Folds a stream of transcript entries into the current state of one Claude session.
public final class ClaudeSessionTracker {
    public private(set) var sessionID: String?
    public private(set) var cwd: String?
    public private(set) var startedAt: Date?
    public private(set) var state: SessionState = .idle
    public private(set) var detail: String?
    public private(set) var lastEventAt: Date?

    private let fallbackID: String
    private var sawAnyEntry = false

    public init(fallbackID: String) {
        self.fallbackID = fallbackID
    }

    public func consume(line: String, now: Date = Date()) {
        guard let event = ClaudeTranscriptParser.parse(line: line) else { return }
        adoptIdentity(from: line)

        switch event {
        case let .meta(_, _, at):
            if let at { lastEventAt = at }
        case let .userPrompt(at):
            state = .thinking
            detail = "Thinking"
            lastEventAt = at ?? now
        case let .toolResult(at):
            if state != .thinking { state = .working }
            lastEventAt = at ?? now
        case let .assistantTool(toolDetail, at):
            state = .working
            if let toolDetail { detail = toolDetail }
            lastEventAt = at ?? now
        case let .assistantText(at):
            state = .done
            detail = nil
            lastEventAt = at ?? now
        }

        if startedAt == nil { startedAt = lastEventAt }
        sawAnyEntry = true
    }

    /// Identity fields live on every entry, so scrape them once cheaply.
    private func adoptIdentity(from line: String) {
        guard sessionID == nil || cwd == nil else { return }
        guard let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        if sessionID == nil, let id = root["sessionId"] as? String, !id.isEmpty { sessionID = id }
        if cwd == nil, let path = root["cwd"] as? String, !path.isEmpty { cwd = normalizeCwd(path) }
    }

    public func update(fileModifiedAt: Date, now: Date = Date()) -> SessionUpdate? {
        guard sawAnyEntry, state != .idle else { return nil }
        let timestamp = max(lastEventAt ?? fileModifiedAt, fileModifiedAt)
        return SessionUpdate(
            agent: .claude,
            sessionID: sessionID ?? fallbackID,
            state: state,
            title: projectLabel(forPath: cwd) ?? "claude",
            detail: detail,
            cwd: cwd,
            source: .file,
            timestamp: min(timestamp, now),
            startedAt: startedAt
        )
    }
}
