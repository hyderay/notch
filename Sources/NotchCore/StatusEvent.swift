import Foundation

/// Wire format for `notchctl` -> app messages, one JSON object per line.
///
/// Decoding is deliberately lenient: an agent hook is a shell one-liner written
/// by a user, so unknown states or missing fields degrade instead of failing.
public struct StatusEvent: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var v: Int
    public var agent: String
    public var session: String
    public var state: String
    public var title: String?
    public var detail: String?
    public var cwd: String?
    public var ts: Double?
    /// When true, drop the session immediately instead of applying a state.
    public var remove: Bool?
    /// Request/response verb. `nil` means "apply this update".
    public var op: String?
    public var permissionRequestID: String?

    public init(
        v: Int = StatusEvent.currentVersion,
        agent: String,
        session: String,
        state: String,
        title: String? = nil,
        detail: String? = nil,
        cwd: String? = nil,
        ts: Double? = nil,
        remove: Bool? = nil,
        op: String? = nil,
        permissionRequestID: String? = nil
    ) {
        self.v = v
        self.agent = agent
        self.session = session
        self.state = state
        self.title = title
        self.detail = detail
        self.cwd = cwd
        self.ts = ts
        self.remove = remove
        self.op = op
        self.permissionRequestID = permissionRequestID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decode(Int.self, forKey: .v)) ?? StatusEvent.currentVersion
        agent = (try? c.decode(String.self, forKey: .agent)) ?? "other"
        session = (try? c.decode(String.self, forKey: .session)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? "working"
        title = try? c.decode(String.self, forKey: .title)
        detail = try? c.decode(String.self, forKey: .detail)
        cwd = try? c.decode(String.self, forKey: .cwd)
        ts = try? c.decode(Double.self, forKey: .ts)
        remove = try? c.decode(Bool.self, forKey: .remove)
        op = try? c.decode(String.self, forKey: .op)
        permissionRequestID = try? c.decode(String.self, forKey: .permissionRequestID)
    }

    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    /// Converts the wire event into the store's normalized update.
    public func asUpdate(receivedAt: Date = Date()) -> SessionUpdate {
        let timestamp: Date
        if let ts, ts > 0, ts.isFinite {
            // Accept both seconds and milliseconds since epoch.
            timestamp = Date(timeIntervalSince1970: ts > 1_000_000_000_000 ? ts / 1000 : ts)
        } else {
            timestamp = receivedAt
        }
        let kind = AgentKind(rawLenient: agent)
        let id = session.isEmpty ? "default" : session
        return SessionUpdate(
            agent: kind,
            sessionID: id,
            state: SessionState(rawLenient: state),
            title: title ?? projectLabel(forPath: cwd),
            detail: detail,
            permissionRequestID: permissionRequestID,
            cwd: cwd,
            source: .ipc,
            timestamp: timestamp,
            remove: remove ?? false
        )
    }
}

/// Normalized, source-agnostic session update fed into `SessionStore`.
public struct SessionUpdate: Equatable, Sendable {
    public var agent: AgentKind
    public var sessionID: String
    public var state: SessionState
    public var title: String?
    public var detail: String?
    public var permissionRequestID: String?
    public var cwd: String?
    public var source: SessionSource
    public var timestamp: Date
    public var remove: Bool
    /// Overrides the session start time; used when a transcript tells us when
    /// the session actually began rather than when we first noticed it.
    public var startedAt: Date?

    public init(
        agent: AgentKind,
        sessionID: String,
        state: SessionState,
        title: String? = nil,
        detail: String? = nil,
        permissionRequestID: String? = nil,
        cwd: String? = nil,
        source: SessionSource,
        timestamp: Date = Date(),
        remove: Bool = false,
        startedAt: Date? = nil
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.state = state
        self.title = title
        self.detail = detail
        self.permissionRequestID = permissionRequestID
        self.cwd = cwd
        self.source = source
        self.timestamp = timestamp
        self.remove = remove
        self.startedAt = startedAt
    }
}
