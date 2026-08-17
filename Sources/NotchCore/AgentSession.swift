import Foundation

/// Which coding agent produced a session.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
    case cursor
    case other

    public init(rawLenient: String) {
        let normalized = rawLenient.lowercased()
        switch normalized {
        case "codex", "codex-cli", "openai": self = .codex
        case "claude", "claude-code", "anthropic": self = .claude
        case "cursor", "cursor-agent": self = .cursor
        default: self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .cursor: return "cursor"
        case .other: return "agent"
        }
    }

    /// SF Symbol used in the compact/expanded UI.
    public var symbolName: String {
        switch self {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkle"
        case .cursor: return "cursorarrow.rays"
        case .other: return "cpu"
        }
    }
}

/// Lifecycle state of a single agent session.
///
/// `urgency` defines how states are aggregated: the most urgent state across all
/// live sessions becomes the global state rendered in the notch.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case idle
    case thinking
    case working
    case waiting
    case done
    case error

    public init(rawLenient: String) {
        self = SessionState(rawValue: rawLenient.lowercased()) ?? .idle
    }

    public var urgency: Int {
        switch self {
        case .error: return 5
        case .waiting: return 4
        case .working: return 3
        case .thinking: return 2
        case .done: return 1
        case .idle: return 0
        }
    }

    /// Whether the agent is actively burning tokens right now.
    public var isBusy: Bool {
        self == .thinking || self == .working
    }

    /// Whether the session should eventually be evicted from the store.
    public var isTerminal: Bool {
        self == .done || self == .error
    }

    public var displayName: String {
        switch self {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .working: return "working"
        case .waiting: return "waiting"
        case .done: return "done"
        case .error: return "error"
        }
    }
}

/// Where a session update came from. Higher priority sources win conflicts.
public enum SessionSource: Int, Codable, Sendable, Comparable {
    case file = 1
    case ipc = 2

    public static func < (lhs: SessionSource, rhs: SessionSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One tracked agent session.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public let agent: AgentKind
    public let sessionID: String
    public var state: SessionState
    /// Short human label, usually the project directory name.
    public var title: String
    /// What the agent is doing right now, e.g. `Bash: swift build`.
    public var detail: String?
    /// Non-nil while this session is waiting on a user decision.
    public var permissionRequestID: String?
    public var cwd: String?
    public var source: SessionSource
    /// When this session was first observed.
    public var startedAt: Date
    /// Last time any update arrived.
    public var updatedAt: Date
    /// When the session entered a terminal state, used for linger/eviction.
    public var terminalAt: Date?

    public var id: String { "\(agent.rawValue)/\(sessionID)" }

    public init(
        agent: AgentKind,
        sessionID: String,
        state: SessionState,
        title: String,
        detail: String? = nil,
        permissionRequestID: String? = nil,
        cwd: String? = nil,
        source: SessionSource,
        startedAt: Date,
        updatedAt: Date,
        terminalAt: Date? = nil
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.state = state
        self.title = title
        self.detail = detail
        self.permissionRequestID = permissionRequestID
        self.cwd = cwd
        self.source = source
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.terminalAt = terminalAt
    }

    public func elapsed(now: Date = Date()) -> TimeInterval {
        let end = terminalAt ?? now
        return max(0, end.timeIntervalSince(startedAt))
    }
}

/// Formats a duration as `M:SS` or `H:MM:SS`.
///
/// Clamps at zero: an agent's timestamp can land slightly ahead of the local
/// clock, and the overlay should show `0:00` rather than a negative timer.
public func formatElapsed(_ interval: TimeInterval) -> String {
    guard interval.isFinite else { return "0:00" }
    let total = max(0, Int(interval.rounded(.down)))
    let seconds = total % 60
    let minutes = (total / 60) % 60
    let hours = total / 3600
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

/// Same as `formatElapsed` but never wider than five characters.
///
/// The compact strip has roughly 60pt per side, and `1:02:05` does not fit
/// there alongside the session-count badge, so hours collapse to `1h02`.
public func formatElapsedCompact(_ interval: TimeInterval) -> String {
    guard interval.isFinite else { return "0:00" }
    let total = max(0, Int(interval.rounded(.down)))
    let hours = total / 3600
    guard hours > 0 else { return formatElapsed(interval) }
    if hours >= 100 { return "99h+" }
    return String(format: "%dh%02d", hours, (total / 60) % 60)
}
