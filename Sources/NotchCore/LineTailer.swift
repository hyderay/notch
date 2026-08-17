import Foundation

/// Incrementally reads newly appended lines from a growing file.
///
/// Remembers a byte offset so each poll only touches new bytes, and detects
/// truncation and file replacement (rotation) by comparing device/inode.
public final class LineTailer {
    /// Upper bound on bytes consumed per `readNewLines()` call. Anything beyond
    /// this is picked up on the next poll, which keeps a single tick cheap even
    /// when first attaching to a large transcript.
    public static let defaultChunkLimit = 4 * 1024 * 1024

    public let url: URL
    public private(set) var offset: UInt64 = 0
    private var partial = Data()
    private var identity: FileIdentity?
    private let chunkLimit: Int

    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
    }

    public init(url: URL, chunkLimit: Int = LineTailer.defaultChunkLimit) {
        self.url = url
        self.chunkLimit = max(4096, chunkLimit)
    }

    /// True when the tailer still has buffered bytes it could not consume in the
    /// last call, so the caller may want to poll again promptly.
    public private(set) var hasMore = false

    /// Reads whatever has been appended since the last call.
    ///
    /// Never throws: a transcript can be deleted or rotated at any moment and a
    /// failed poll should just yield nothing.
    public func readNewLines() -> [String] {
        hasMore = false

        var st = stat()
        guard stat(url.path, &st) == 0 else {
            reset()
            return []
        }

        let currentIdentity = FileIdentity(device: st.st_dev, inode: UInt64(st.st_ino))
        if let identity, identity != currentIdentity {
            reset()
        }
        identity = currentIdentity

        let size = UInt64(max(0, st.st_size))
        if size < offset {
            // Truncated or rewritten in place; start over.
            offset = 0
            partial.removeAll(keepingCapacity: true)
        }
        guard size > offset else { return [] }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let available = size - offset
        let toRead = min(UInt64(chunkLimit), available)
        hasMore = toRead < available

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return []
        }
        guard let chunk = try? handle.read(upToCount: Int(toRead)), !chunk.isEmpty else {
            return []
        }
        offset += UInt64(chunk.count)

        var buffer = partial
        buffer.append(chunk)
        partial.removeAll(keepingCapacity: true)

        var lines: [String] = []
        var lineStart = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            if buffer[index] == 0x0A {
                if index > lineStart, let line = String(data: buffer[lineStart..<index], encoding: .utf8) {
                    let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
                    if !trimmed.isEmpty { lines.append(trimmed) }
                }
                lineStart = buffer.index(after: index)
            }
            index = buffer.index(after: index)
        }

        if lineStart < buffer.endIndex {
            let tail = buffer[lineStart..<buffer.endIndex]
            // Guard against a pathological single line with no newline.
            if tail.count <= chunkLimit {
                partial = Data(tail)
            } else {
                partial.removeAll(keepingCapacity: true)
            }
        }

        return lines
    }

    /// Positions the tailer at the current end of file without emitting lines.
    public func skipToEnd() {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return }
        identity = FileIdentity(device: st.st_dev, inode: UInt64(st.st_ino))
        offset = UInt64(max(0, st.st_size))
        partial.removeAll(keepingCapacity: true)
    }

    private func reset() {
        offset = 0
        partial.removeAll(keepingCapacity: true)
        identity = nil
    }
}
