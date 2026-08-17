import Foundation
import NotchCore

/// Anything that can feed session updates into the store.
protocol StatusSource: AnyObject {
    func start()
    func stop()
}

/// Shared machinery for sources that tail JSONL transcripts on disk.
///
/// Work is driven by FSEvents rather than a poll: while no agent is writing,
/// this costs nothing at all. If a transcript root does not exist yet, an
/// ancestor vnode watch waits for it to appear instead of retrying on a timer.
///
/// Only files modified inside `activeWindow` are tracked, and each is read
/// incrementally from a saved byte offset.
class TranscriptSource<Tracker: AnyObject>: StatusSource {
    struct Entry {
        let tailer: LineTailer
        let tracker: Tracker
        var lastModified: Date
    }

    let store: SessionStore
    let onChange: () -> Void
    let activeWindow: TimeInterval
    let queue: DispatchQueue

    private var watchers: [DirectoryWatcher] = []
    private var fileWatchers: [String: TranscriptFileWatcher] = [:]
    /// Keyed by the FSEvents path that has not started yet.
    private var ancestors: [String: AncestorWatcher] = [:]
    private var gcTimer: DispatchSourceTimer?
    var entries: [String: Entry] = [:]

    init(
        store: SessionStore,
        label: String,
        activeWindow: TimeInterval = 15 * 60,
        onChange: @escaping () -> Void
    ) {
        self.store = store
        self.onChange = onChange
        self.activeWindow = activeWindow
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.watchers.isEmpty else { return }
            self.attachWatchers()
            self.tick()
        }
    }

    private func attachWatchers() {
        if watchers.isEmpty {
            watchers = watchedRoots().map { root in
                DirectoryWatcher(path: root.path, queue: queue) { [weak self] in
                    self?.handleWatchEvent()
                }
            }
        }
        for watcher in watchers where !watcher.isRunning {
            if watcher.start() {
                ancestors[watcher.path]?.stop()
                ancestors[watcher.path] = nil
            } else {
                ensureAncestor(for: watcher)
            }
        }
    }

    private func handleWatchEvent() {
        attachWatchers()
        tick()
    }

    private func ensureAncestor(for watcher: DirectoryWatcher) {
        guard let ancestorPath = nearestExistingAncestor(of: watcher.path) else { return }
        if let existing = ancestors[watcher.path], existing.path == ancestorPath, existing.isRunning {
            return
        }
        ancestors[watcher.path]?.stop()
        let ancestor = AncestorWatcher(path: ancestorPath, queue: queue) { [weak self] in
            self?.handleWatchEvent()
        }
        _ = ancestor.start()
        ancestors[watcher.path] = ancestor
    }

    func stop() {
        queue.sync {
            gcTimer?.cancel()
            gcTimer = nil
            watchers.forEach { $0.stop() }
            watchers.removeAll()
            fileWatchers.values.forEach { $0.stop() }
            fileWatchers.removeAll()
            ancestors.values.forEach { $0.stop() }
            ancestors.removeAll()
            entries.removeAll()
        }
    }

    /// Directory trees to watch. FSEvents is recursive, so the root of each
    /// agent's transcript tree is enough even though new subdirectories appear.
    func watchedRoots() -> [URL] { [] }

    private func tick() {
        let now = Date()
        let files = candidateFiles(now: now)
        var seen = Set<String>()
        var updates: [SessionUpdate] = []

        for file in files {
            seen.insert(file.path)
            ensureFileWatcher(for: file)
            var entry: Entry
            if let existing = entries[file.path] {
                entry = existing
            } else {
                entry = Entry(
                    tailer: LineTailer(url: file.url),
                    tracker: makeTracker(for: file),
                    lastModified: file.modified
                )
            }
            entry.lastModified = file.modified
            entries[file.path] = entry

            let lines = entry.tailer.readNewLines()
            guard !lines.isEmpty else { continue }
            for line in lines {
                consume(line: line, tracker: entry.tracker, now: now)
            }
            if let update = makeUpdate(tracker: entry.tracker, modified: file.modified, now: now) {
                updates.append(update)
            }
        }

        // Forget files that fell out of the active window so memory stays flat.
        for key in Array(entries.keys) where !seen.contains(key) {
            entries[key] = nil
        }
        for key in Array(fileWatchers.keys) where !seen.contains(key) {
            fileWatchers.removeValue(forKey: key)?.stop()
        }

        scheduleGC()

        if entries.values.contains(where: { $0.tailer.hasMore }) {
            queue.async { [weak self] in self?.tick() }
        }

        guard !updates.isEmpty else { return }
        if store.apply(updates) {
            onChange()
        }
    }

    private func ensureFileWatcher(for file: CandidateFile) {
        guard fileWatchers[file.path] == nil else { return }
        let watcher = TranscriptFileWatcher(path: file.path, queue: queue) { [weak self] in
            self?.handleWatchEvent()
        }
        if watcher.start() {
            fileWatchers[file.path] = watcher
        }
    }

    /// Drops aged-out tailers even if the file never writes again, which would
    /// otherwise produce no FSEvents and leak the handle until the next change.
    private func scheduleGC() {
        gcTimer?.cancel()
        gcTimer = nil
        guard !entries.isEmpty else { return }
        let now = Date()
        let next = entries.values
            .map { $0.lastModified.addingTimeInterval(activeWindow) }
            .min() ?? now.addingTimeInterval(activeWindow)
        let delay = max(1, next.timeIntervalSince(now))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.gcTimer = nil
            self?.tick()
        }
        timer.schedule(deadline: .now() + delay, leeway: .seconds(5))
        gcTimer = timer
        timer.resume()
    }

    // MARK: - Subclass hooks

    struct CandidateFile {
        let url: URL
        let path: String
        let modified: Date
    }

    func candidateFiles(now: Date) -> [CandidateFile] { [] }
    func makeTracker(for file: CandidateFile) -> Tracker { fatalError("subclass must override") }
    func consume(line: String, tracker: Tracker, now: Date) {}
    func makeUpdate(tracker: Tracker, modified: Date, now: Date) -> SessionUpdate? { nil }

    /// Lists `.jsonl` files directly inside `directory` modified within the window.
    func recentJSONL(in directory: URL, now: Date) -> [CandidateFile] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) <= activeWindow
            else { return nil }
            return CandidateFile(url: url, path: url.path, modified: modified)
        }
    }
}

/// Tails `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
final class CodexFileSource: TranscriptSource<CodexSessionTracker> {
    /// `Calendar.current` rebuilds a calendar on every access; the date maths
    /// below runs on every FSEvents tick, so hold one.
    private let calendar = Calendar.current
    private var cachedDayKey = ""
    private var cachedDirectories: [URL] = []
    private var livenessTimer: DispatchSourceTimer?
    private var missingProcessChecks: [String: Int] = [:]
    private let processProbe: ([String]) -> Set<String>?

    init(
        store: SessionStore,
        processProbe: @escaping ([String]) -> Set<String>? = CodexProcessProbe.openRolloutPaths,
        onChange: @escaping () -> Void
    ) {
        self.processProbe = processProbe
        super.init(store: store, label: "com.wanquanlin.notch.codex", onChange: onChange)
    }

    override func stop() {
        queue.sync {
            livenessTimer?.cancel()
            livenessTimer = nil
            missingProcessChecks.removeAll()
        }
        super.stop()
    }

    /// Watching the tree root rather than today's directory means a session
    /// that starts after midnight, in a directory that does not exist yet, is
    /// still noticed immediately.
    override func watchedRoots() -> [URL] { [NotchPaths.codexSessions] }

    override func candidateFiles(now: Date) -> [CandidateFile] {
        directories(now: now).flatMap { recentJSONL(in: $0, now: now) }
    }

    /// Codex buckets transcripts by local date, so a session running across
    /// midnight stays in yesterday's directory while still active. The pair of
    /// paths only changes once a day, so build them once per day.
    private func directories(now: Date) -> [URL] {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year, let month = today.month, let day = today.day else { return [] }
        let key = "\(year)-\(month)-\(day)"
        guard key != cachedDayKey else { return cachedDirectories }

        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        cachedDirectories = [now, yesterday].compactMap { date in
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { return nil }
            return NotchPaths.codexSessions
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))
        }
        cachedDayKey = key
        return cachedDirectories
    }

    override func makeTracker(for file: CandidateFile) -> CodexSessionTracker {
        Log.debug("codex: tracking \(file.url.lastPathComponent)")
        return CodexSessionTracker(fallbackID: file.url.deletingPathExtension().lastPathComponent)
    }

    override func consume(line: String, tracker: CodexSessionTracker, now: Date) {
        tracker.consume(line: line, now: now)
    }

    override func makeUpdate(tracker: CodexSessionTracker, modified: Date, now: Date) -> SessionUpdate? {
        let update = tracker.update(fileModifiedAt: modified, now: now)
        if let update { Log.debug("codex: \(update.sessionID.prefix(8)) -> \(update.state) \(update.detail ?? "")") }
        scheduleLivenessCheck()
        return update
    }

    /// A killed TUI leaves its final rollout state at `working`. While any
    /// tracker is busy, check whether Codex still owns the corresponding file.
    /// Two consecutive misses avoid removing a live session on a transient lsof
    /// failure or during descriptor setup.
    private func checkLiveness() {
        let busyEntries = entries.filter { $0.value.tracker.state.isBusy }
        guard !busyEntries.isEmpty else {
            missingProcessChecks.removeAll()
            return
        }

        let paths = Array(busyEntries.keys)
        guard let openPaths = processProbe(paths) else {
            scheduleLivenessCheck()
            return
        }

        let now = Date()
        var removals: [SessionUpdate] = []
        for (path, entry) in busyEntries {
            if openPaths.contains(path) {
                missingProcessChecks[path] = nil
                continue
            }

            let misses = (missingProcessChecks[path] ?? 0) + 1
            missingProcessChecks[path] = misses
            guard misses >= 2, let removal = entry.tracker.processExited(now: now) else { continue }
            Log.debug("codex: \(removal.sessionID.prefix(8)) process exited")
            removals.append(removal)
            missingProcessChecks[path] = nil
        }

        missingProcessChecks = missingProcessChecks.filter { busyEntries[$0.key] != nil }
        if !removals.isEmpty, store.apply(removals) {
            onChange()
        }
        scheduleLivenessCheck()
    }

    private func scheduleLivenessCheck() {
        guard livenessTimer == nil else { return }
        guard entries.values.contains(where: { $0.tracker.state.isBusy }) else {
            missingProcessChecks.removeAll()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.livenessTimer = nil
            self.checkLiveness()
        }
        timer.schedule(deadline: .now() + 1, leeway: .milliseconds(150))
        livenessTimer = timer
        timer.resume()
    }
}

/// Tails `~/.claude/projects/<slug>/<session>.jsonl`.
final class ClaudeFileSource: TranscriptSource<ClaudeSessionTracker> {
    init(store: SessionStore, onChange: @escaping () -> Void) {
        super.init(store: store, label: "com.wanquanlin.notch.claude", onChange: onChange)
    }

    override func watchedRoots() -> [URL] { [NotchPaths.claudeProjects] }

    override func candidateFiles(now: Date) -> [CandidateFile] {
        let fm = FileManager.default
        let root = NotchPaths.claudeProjects
        guard fm.fileExists(atPath: root.path) else { return [] }

        guard let projects = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [CandidateFile] = []
        for project in projects {
            guard let values = try? project.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true
            else { continue }
            // A project directory's mtime changes whenever a transcript inside
            // it is created; a stale directory cannot hold an active session,
            // but its own mtime lags file appends, so allow a generous margin.
            if let modified = values.contentModificationDate,
               now.timeIntervalSince(modified) > activeWindow * 8 {
                continue
            }
            result.append(contentsOf: recentJSONL(in: project, now: now))
        }
        return result
    }

    override func makeTracker(for file: CandidateFile) -> ClaudeSessionTracker {
        Log.debug("claude: tracking \(file.url.lastPathComponent)")
        return ClaudeSessionTracker(fallbackID: file.url.deletingPathExtension().lastPathComponent)
    }

    override func consume(line: String, tracker: ClaudeSessionTracker, now: Date) {
        tracker.consume(line: line, now: now)
    }

    override func makeUpdate(tracker: ClaudeSessionTracker, modified: Date, now: Date) -> SessionUpdate? {
        let update = tracker.update(fileModifiedAt: modified, now: now)
        if let update { Log.debug("claude: \(update.sessionID.prefix(8)) -> \(update.state) \(update.detail ?? "")") }
        return update
    }

}

/// One-shot handoff slot. The semaphore orders the write before the read, so no
/// additional locking is needed.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Receives high-fidelity events from agent hooks over the Unix socket.
final class IPCSource: StatusSource {
    private let store: SessionStore
    private let onChange: () -> Void
    private var server: SocketServer?

    /// Renders the overlay to a PNG. Must run on the main actor; returns a
    /// human-readable result.
    var snapshotHandler: (@MainActor (_ path: String) -> String)?

    init(store: SessionStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
    }

    func start() {
        NotchPaths.ensureStateDirectory()
        let path = NotchPaths.socket.path
        let server = SocketServer(path: path) { [weak self] line in
            self?.handle(line: line)
        }
        do {
            try server.start()
            self.server = server
            Log.debug("ipc: listening on \(path)")
        } catch {
            Log.error("IPC disabled: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func handle(line: String) -> Data? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let event = try? JSONDecoder().decode(StatusEvent.self, from: data) else {
            Log.debug("ipc: dropped malformed line")
            return nil
        }

        switch event.op {
        case "status":
            return statusReply()
        case "ping":
            return Data("{\"ok\":true}\n".utf8)
        case "inspect":
            return jsonLine(OverlayDebugState.shared.asJSON)
        case "snapshot":
            let path = event.detail ?? "/tmp/notch-snapshot.png"
            let message = runOnMain { self.snapshotHandler?(path) ?? "snapshot unavailable" }
            return jsonLine(["ok": message != nil, "message": message ?? "timed out"])
        default:
            break
        }

        let update = event.asUpdate()
        Log.debug("ipc: \(update.agent.rawValue)/\(update.sessionID) -> \(update.state)")
        if store.apply(update) {
            onChange()
        }
        return nil
    }

    private func statusReply() -> Data {
        let snapshot = store.snapshot()
        let now = Date()
        let rows: [[String: Any]] = snapshot.sessions.map { session in
            var row: [String: Any] = [
                "agent": session.agent.rawValue,
                "session": session.sessionID,
                "state": session.state.rawValue,
                "title": session.title,
                "source": session.source == .ipc ? "ipc" : "file",
                "elapsed": Int(session.elapsed(now: now)),
            ]
            if let detail = session.detail { row["detail"] = detail }
            if let cwd = session.cwd { row["cwd"] = cwd }
            return row
        }
        return jsonLine([
            "globalState": snapshot.globalState.rawValue,
            "busyCount": snapshot.busyCount,
            "sessions": rows,
        ])
    }

    private func jsonLine(_ payload: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// Hops to the main actor and waits for a result.
    ///
    /// Bounded by a timeout rather than blocking forever: `SocketServer.stop()`
    /// runs `queue.sync` from the main thread during termination, so a hop that
    /// waited indefinitely could deadlock against a quit that lands mid-request.
    private func runOnMain<T>(
        timeout: TimeInterval = 5,
        _ body: @escaping @MainActor @Sendable () -> T
    ) -> T? {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { box.value = body() }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }
}
