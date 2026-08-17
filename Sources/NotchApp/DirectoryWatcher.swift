import CoreServices
import Darwin
import Foundation

/// Watches a directory tree with FSEvents and reports that something changed.
///
/// Replaces polling for transcript changes. Polling meant a timer wakeup every
/// second or two forever, whether or not any agent was running; FSEvents costs
/// nothing while the tree is quiet and reports within its latency window when
/// it is not, so the app is both cheaper at rest and more responsive in use.
///
/// The callback carries no payload on purpose: the source still has to stat and
/// tail the files it cares about, so knowing *that* something changed is enough.
final class DirectoryWatcher {
    let path: String
    private let queue: DispatchQueue
    private let latency: CFTimeInterval
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(path: String, queue: DispatchQueue, latency: CFTimeInterval = 0.15, onChange: @escaping () -> Void) {
        // FSEvents reports the real path. Watching a symlink such as `/tmp`
        // can silently miss events that arrive as `/private/tmp/...`.
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.queue = queue
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    var isRunning: Bool { stream != nil }

    /// Returns false when the directory does not exist yet or the stream could
    /// not be scheduled; the caller should watch an ancestor until it appears.
    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            Log.debug("watcher: change under \(watcher.path)")
            watcher.onChange()
        }

        // FileEvents reports individual files rather than just directories, so
        // an append to an existing transcript wakes us, not only file creation.
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return false }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }

        stream = created
        Log.debug("watcher: watching \(path)")
        return true
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// Watches appends to one transcript file.
///
/// FSEvents remains responsible for discovering new files. Once discovered,
/// this vnode source provides reliable per-file append notifications even when
/// a long-lived recursive FSEvents stream coalesces or misses an update.
final class TranscriptFileWatcher {
    let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(path: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard source == nil else { return true }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.onChange() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        return true
    }

    func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
    }
}

/// Non-recursive watch on a single existing directory.
///
/// Used when a transcript root (for example `~/.claude/projects`) does not
/// exist yet. Polling for it would wake the process forever on machines that
/// never install that agent; a vnode watch on the nearest ancestor sleeps
/// until a direct child is created, then the real FSEvents stream can start.
final class AncestorWatcher {
    let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(path: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.queue = queue
        self.onChange = onChange
    }

    deinit { stop() }

    var isRunning: Bool { source != nil }

    @discardableResult
    func start() -> Bool {
        guard source == nil else { return true }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.onChange()
        }
        src.setCancelHandler {
            close(fd)
        }
        source = src
        src.resume()
        Log.debug("watcher: waiting on ancestor \(path)")
        return true
    }

    func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
    }
}

/// Walks toward the filesystem root and returns the nearest directory that
/// already exists. Returns nil at `/` so we never watch the whole volume.
func nearestExistingAncestor(of path: String) -> String? {
    var url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    url = url.deletingLastPathComponent()
    let fm = FileManager.default
    while url.path != "/", !url.path.isEmpty {
        if fm.fileExists(atPath: url.path) { return url.path }
        url = url.deletingLastPathComponent()
    }
    return nil
}
