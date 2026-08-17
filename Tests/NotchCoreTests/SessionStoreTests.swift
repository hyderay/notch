import Foundation
import Testing
@testable import NotchCore

@Suite("SessionStore")
struct SessionStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func update(
        _ agent: AgentKind = .codex,
        _ id: String = "s1",
        _ state: SessionState,
        source: SessionSource = .file,
        at offset: TimeInterval = 0,
        detail: String? = nil,
        remove: Bool = false,
        startedAt: Date? = nil
    ) -> SessionUpdate {
        SessionUpdate(
            agent: agent,
            sessionID: id,
            state: state,
            detail: detail,
            cwd: "/tmp/project",
            source: source,
            timestamp: epoch.addingTimeInterval(offset),
            remove: remove,
            startedAt: startedAt
        )
    }

    @Test("aggregates the most urgent state across sessions")
    func aggregate() {
        let store = SessionStore()
        #expect(store.apply(update(.codex, "a", .working)))
        #expect(store.apply(update(.claude, "b", .waiting, at: 1)))

        let snapshot = store.snapshot(now: epoch.addingTimeInterval(2))
        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.globalState == .waiting)
        #expect(snapshot.busyCount == 1)
        #expect(snapshot.sessions.first?.state == .waiting, "most urgent sorts first")
    }

    @Test("title falls back to the project directory name")
    func titleFallback() {
        let store = SessionStore()
        store.apply(update(.codex, "a", .working))
        #expect(store.snapshot().sessions.first?.title == "project")
    }

    @Test("an identical update reports no change")
    func idempotent() {
        let store = SessionStore()
        #expect(store.apply(update(.codex, "a", .working, detail: "build")))
        #expect(!store.apply(update(.codex, "a", .working, detail: "build")))
    }

    @Test("remove drops the session and is idempotent")
    func remove() {
        let store = SessionStore()
        store.apply(update(.codex, "a", .working))
        #expect(store.apply(update(.codex, "a", .idle, at: 1, remove: true)))
        #expect(store.snapshot().sessions.isEmpty)
        #expect(!store.apply(update(.codex, "a", .idle, at: 2, remove: true)))
    }

    @Test("a hook event is not overridden by a transcript guess")
    func ipcStickiness() {
        let store = SessionStore()
        store.apply(update(.claude, "a", .waiting, source: .ipc, at: 0))
        #expect(!store.apply(update(.claude, "a", .working, source: .file, at: 10)))
        #expect(store.snapshot().sessions.first?.state == .waiting)
    }

    @Test("the transcript takes over once the hook goes quiet")
    func stickinessExpires() {
        let store = SessionStore()
        store.apply(update(.claude, "a", .waiting, source: .ipc, at: 0))
        #expect(store.apply(update(.claude, "a", .working, source: .file, at: 61)))
        #expect(store.snapshot().sessions.first?.state == .working)
    }

    @Test("a hook always overrides the transcript")
    func ipcWins() {
        let store = SessionStore()
        store.apply(update(.claude, "a", .working, source: .file, at: 0))
        #expect(store.apply(update(.claude, "a", .done, source: .ipc, at: 1)))
        #expect(store.snapshot().sessions.first?.state == .done)
    }

    @Test("next prune date is the soonest linger or timeout")
    func nextPruneDate() {
        let store = SessionStore()
        #expect(store.nextPruneDate() == nil)

        store.apply(update(.codex, "a", .done, at: 0))
        let next = store.nextPruneDate(now: epoch)
        #expect(next == epoch.addingTimeInterval(8))
    }

    @Test("done sessions are evicted after the linger window")
    func doneLinger() {
        let store = SessionStore()
        store.apply(update(.codex, "a", .done))
        #expect(!store.prune(now: epoch.addingTimeInterval(5)))
        #expect(store.snapshot().sessions.count == 1)

        #expect(store.prune(now: epoch.addingTimeInterval(9)))
        #expect(store.snapshot().sessions.isEmpty)
    }

    @Test("a nil detail leaves the existing label alone")
    func partialUpdatesKeepDetail() throws {
        let store = SessionStore()
        store.apply(update(.codex, "a", .working, at: 0, detail: "Run swift build"))
        store.apply(update(.codex, "a", .thinking, at: 1))
        #expect(try #require(store.snapshot().sessions.first).detail == "Run swift build")
    }

    @Test("finishing clears a stale action label")
    func terminalClearsDetail() throws {
        let store = SessionStore()
        store.apply(update(.codex, "a", .working, at: 0, detail: "Run swift build"))
        store.apply(update(.codex, "a", .done, at: 1))
        #expect(try #require(store.snapshot().sessions.first).detail == nil)
    }

    @Test("an error keeps the message it came with")
    func errorKeepsDetail() throws {
        let store = SessionStore()
        store.apply(update(.codex, "a", .working, at: 0, detail: "Run swift build"))
        store.apply(update(.codex, "a", .error, at: 1, detail: "exit 1"))
        #expect(try #require(store.snapshot().sessions.first).detail == "exit 1")
    }

    @Test("permission identity is kept only while waiting")
    func permissionLifecycle() throws {
        let store = SessionStore()
        var waiting = update(.claude, "a", .waiting, source: .ipc, at: 0, detail: "Allow write?")
        waiting.permissionRequestID = "request-1"
        store.apply(waiting)
        #expect(try #require(store.snapshot().sessions.first).permissionRequestID == "request-1")

        store.apply(update(.claude, "a", .thinking, source: .ipc, at: 1))
        #expect(try #require(store.snapshot().sessions.first).permissionRequestID == nil)
    }

    @Test("errors linger longer than completions")
    func errorLinger() {
        let store = SessionStore()
        store.apply(update(.codex, "a", .error))
        #expect(!store.prune(now: epoch.addingTimeInterval(20)))
        #expect(store.prune(now: epoch.addingTimeInterval(31)))
    }

    @Test("elapsed freezes when a session finishes")
    func frozenElapsed() throws {
        let store = SessionStore()
        store.apply(update(.codex, "a", .working, at: 0))
        store.apply(update(.codex, "a", .done, at: 5))

        let session = try #require(store.snapshot().sessions.first)
        #expect(abs(session.elapsed(now: epoch.addingTimeInterval(300)) - 5) < 0.01)
    }

    @Test("repeated done events do not extend the linger window")
    func repeatedDone() {
        let store = SessionStore()
        store.apply(update(.codex, "a", .done, at: 0))
        store.apply(update(.codex, "a", .done, at: 4, detail: "again"))
        #expect(store.prune(now: epoch.addingTimeInterval(9)))
    }

    @Test("a busy session that stops reporting is demoted rather than spinning forever")
    func busyDemotion() throws {
        let store = SessionStore()
        store.apply(update(.codex, "a", .working, at: 0, detail: "build"))
        #expect(store.prune(now: epoch.addingTimeInterval(121)))

        let session = try #require(store.snapshot().sessions.first)
        #expect(session.state == .idle)
        #expect(session.detail == nil)
    }

    @Test("sessions that never report again are evicted")
    func staleEviction() {
        let store = SessionStore()
        store.apply(update(.codex, "a", .working, at: 0))
        #expect(store.prune(now: epoch.addingTimeInterval(16 * 60)))
        #expect(store.snapshot().sessions.isEmpty)
    }

    @Test("the compact timer follows the oldest busy session")
    func leadStart() {
        let store = SessionStore()
        store.apply(update(.codex, "a", .working, at: 0, startedAt: epoch))
        store.apply(update(.claude, "b", .working, at: 30, startedAt: epoch.addingTimeInterval(30)))
        #expect(store.snapshot().leadStartedAt == epoch)
    }

    @Test("an empty store is idle and inactive")
    func empty() {
        let snapshot = SessionStore().snapshot()
        #expect(snapshot.globalState == .idle)
        #expect(!snapshot.isActive)
    }

    @Test("concurrent writers do not corrupt the store")
    func concurrency() {
        let store = SessionStore()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            store.apply(
                SessionUpdate(
                    agent: .codex,
                    sessionID: "s\(index % 10)",
                    state: .working,
                    source: .file,
                    timestamp: Date()
                )
            )
            _ = store.snapshot()
        }
        #expect(store.snapshot().sessions.count == 10)
    }
}
