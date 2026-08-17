import Foundation

public struct SessionStoreConfig: Sendable {
    /// How long a `done` session stays visible before eviction.
    public var doneLinger: TimeInterval = 8
    /// How long an `error` session stays visible before eviction.
    public var errorLinger: TimeInterval = 30
    /// A lower-priority source cannot overwrite a session that a higher-priority
    /// source touched within this window.
    public var sourceStickiness: TimeInterval = 60
    /// Any session with no update at all for this long is dropped, which covers
    /// agents that were killed without emitting a terminal event.
    public var staleTimeout: TimeInterval = 15 * 60
    /// A busy session that stops updating for this long is demoted to `idle`
    /// rather than spinning forever.
    public var busyIdleTimeout: TimeInterval = 120

    public init() {}
}

/// Immutable view of the store, safe to hand to the UI.
public struct StoreSnapshot: Equatable, Sendable {
    public var sessions: [AgentSession]
    public var globalState: SessionState
    public var busyCount: Int
    /// Start time of the longest-running busy session, for the compact timer.
    public var leadStartedAt: Date?

    public static let empty = StoreSnapshot(sessions: [], globalState: .idle, busyCount: 0, leadStartedAt: nil)

    public var isActive: Bool { !sessions.isEmpty }

    public init(sessions: [AgentSession], globalState: SessionState, busyCount: Int, leadStartedAt: Date?) {
        self.sessions = sessions
        self.globalState = globalState
        self.busyCount = busyCount
        self.leadStartedAt = leadStartedAt
    }
}

/// Merges updates from every status source into one coherent set of sessions.
///
/// Thread-safe; sources call in from their own queues.
public final class SessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: AgentSession] = [:]
    /// Last time each session was touched by each source, used for stickiness.
    private var lastTouch: [String: [SessionSource: Date]] = [:]
    private let config: SessionStoreConfig

    public init(config: SessionStoreConfig = SessionStoreConfig()) {
        self.config = config
    }

    /// Applies an update. Returns true if the resulting snapshot changed.
    @discardableResult
    public func apply(_ update: SessionUpdate) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyLocked(update)
    }

    @discardableResult
    public func apply(_ updates: [SessionUpdate]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for update in updates where applyLocked(update) {
            changed = true
        }
        return changed
    }

    private func applyLocked(_ update: SessionUpdate) -> Bool {
        let key = "\(update.agent.rawValue)/\(update.sessionID)"

        if update.remove {
            guard sessions.removeValue(forKey: key) != nil else { return false }
            lastTouch[key] = nil
            return true
        }

        if let existing = sessions[key], !isAllowedLocked(update: update, existing: existing, key: key) {
            return false
        }

        var touches = lastTouch[key] ?? [:]
        touches[update.source] = update.timestamp
        lastTouch[key] = touches

        if var session = sessions[key] {
            let before = session
            session.state = update.state
            session.source = update.source
            session.updatedAt = max(session.updatedAt, update.timestamp)
            if let title = update.title, !title.isEmpty { session.title = title }
            if let detail = update.detail {
                session.detail = detail.isEmpty ? nil : detail
            } else if update.state.isTerminal {
                // A nil detail normally means "unchanged", so partial hook
                // updates keep their label. A finished session has no current
                // action though, so a stale one would be misleading.
                session.detail = nil
            }
            if update.state == .waiting {
                if let requestID = update.permissionRequestID, !requestID.isEmpty {
                    session.permissionRequestID = requestID
                }
            } else {
                session.permissionRequestID = nil
            }
            if let cwd = update.cwd, !cwd.isEmpty { session.cwd = cwd }
            if let startedAt = update.startedAt { session.startedAt = startedAt }

            if update.state.isTerminal {
                // Keep the first terminal timestamp so the linger window and the
                // frozen elapsed time do not shift on repeated terminal events.
                if session.terminalAt == nil || before.state != update.state {
                    session.terminalAt = update.timestamp
                }
            } else {
                session.terminalAt = nil
            }

            guard session != before else { return false }
            sessions[key] = session
            return true
        }

        let started = update.startedAt ?? update.timestamp
        let session = AgentSession(
            agent: update.agent,
            sessionID: update.sessionID,
            state: update.state,
            title: update.title ?? projectLabel(forPath: update.cwd) ?? update.agent.displayName,
            detail: update.detail?.isEmpty == true ? nil : update.detail,
            permissionRequestID: update.permissionRequestID,
            cwd: update.cwd,
            source: update.source,
            startedAt: min(started, update.timestamp),
            updatedAt: update.timestamp,
            terminalAt: update.state.isTerminal ? update.timestamp : nil
        )
        sessions[key] = session
        return true
    }

    /// Stickiness check: a file-derived update must not clobber a session that
    /// a hook (IPC) described more recently.
    private func isAllowedLocked(update: SessionUpdate, existing: AgentSession, key: String) -> Bool {
        guard update.source < existing.source else { return true }
        guard let higherTouch = lastTouch[key]?[existing.source] else { return true }
        return update.timestamp.timeIntervalSince(higherTouch) >= config.sourceStickiness
    }

    /// Evicts expired sessions and demotes stalled ones. Returns true if the
    /// snapshot changed.
    @discardableResult
    public func prune(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var changed = false

        for (key, session) in Array(sessions) {
            if let terminalAt = session.terminalAt {
                let linger = session.state == .error ? config.errorLinger : config.doneLinger
                if now.timeIntervalSince(terminalAt) >= linger {
                    sessions[key] = nil
                    lastTouch[key] = nil
                    changed = true
                    continue
                }
            }

            if now.timeIntervalSince(session.updatedAt) >= config.staleTimeout {
                sessions[key] = nil
                lastTouch[key] = nil
                changed = true
                continue
            }

            if session.state.isBusy, now.timeIntervalSince(session.updatedAt) >= config.busyIdleTimeout {
                var demoted = session
                demoted.state = .idle
                demoted.detail = nil
                sessions[key] = demoted
                changed = true
            }
        }

        return changed
    }

    /// The next moment `prune` can change anything, or nil when the store is empty.
    ///
    /// Lets the UI arm a one-shot timer instead of waking every second.
    public func nextPruneDate(now: Date = Date()) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        var earliest: Date?
        func consider(_ date: Date) {
            if earliest == nil || date < earliest! { earliest = date }
        }
        for session in sessions.values {
            if let terminalAt = session.terminalAt {
                let linger = session.state == .error ? config.errorLinger : config.doneLinger
                consider(terminalAt.addingTimeInterval(linger))
            }
            consider(session.updatedAt.addingTimeInterval(config.staleTimeout))
            if session.state.isBusy {
                consider(session.updatedAt.addingTimeInterval(config.busyIdleTimeout))
            }
        }
        return earliest
    }

    public func snapshot(now: Date = Date()) -> StoreSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked(now: now)
    }

    private func snapshotLocked(now: Date) -> StoreSnapshot {
        let all = sessions.values.sorted { lhs, rhs in
            if lhs.state.urgency != rhs.state.urgency { return lhs.state.urgency > rhs.state.urgency }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
        let global = all.map(\.state).max(by: { $0.urgency < $1.urgency }) ?? .idle
        let busy = all.filter { $0.state.isBusy }
        let lead = busy.map(\.startedAt).min() ?? all.first?.startedAt
        return StoreSnapshot(
            sessions: all,
            globalState: global,
            busyCount: busy.count,
            leadStartedAt: lead
        )
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll()
        lastTouch.removeAll()
    }
}
