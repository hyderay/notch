import Foundation
import Testing
@testable import NotchCore

@Suite("LineTailer")
final class LineTailerTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-tailer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String = "log.jsonl") -> URL {
        directory.appendingPathComponent(name)
    }

    private func append(_ text: String, to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try Data(text.utf8).write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test("reads only newly appended lines")
    func readsOnlyNewLines() throws {
        let url = file()
        try append("a\nb\n", to: url)
        let tailer = LineTailer(url: url)

        #expect(tailer.readNewLines() == ["a", "b"])
        #expect(tailer.readNewLines() == [])

        try append("c\n", to: url)
        #expect(tailer.readNewLines() == ["c"])
    }

    @Test("holds a partial line until its newline arrives")
    func holdsPartialLine() throws {
        let url = file()
        try append("comp", to: url)
        let tailer = LineTailer(url: url)

        #expect(tailer.readNewLines() == [])

        try append("lete\n", to: url)
        #expect(tailer.readNewLines() == ["complete"])
    }

    @Test("a missing file yields nothing instead of throwing")
    func missingFile() {
        #expect(LineTailer(url: file("absent.jsonl")).readNewLines() == [])
    }

    @Test("truncation restarts from the beginning")
    func truncation() throws {
        let url = file()
        try append("one\ntwo\n", to: url)
        let tailer = LineTailer(url: url)
        #expect(tailer.readNewLines() == ["one", "two"])

        try Data("fresh\n".utf8).write(to: url)
        #expect(tailer.readNewLines() == ["fresh"])
    }

    @Test("rotation is detected by inode, not just by size")
    func rotation() throws {
        let url = file()
        try append("old\n", to: url)
        let tailer = LineTailer(url: url)
        #expect(tailer.readNewLines() == ["old"])

        // The replacement is longer than the consumed offset, so a size-only
        // check would silently skip its first bytes.
        let replacement = directory.appendingPathComponent("replacement")
        try Data("brand new content\n".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)

        #expect(tailer.readNewLines() == ["brand new content"])
    }

    @Test("the chunk limit defers the remainder to the next read")
    func chunkLimit() throws {
        let url = file()
        let line = String(repeating: "x", count: 3000)
        try append("\(line)\n\(line)\n", to: url)

        let tailer = LineTailer(url: url, chunkLimit: 4096)
        #expect(tailer.readNewLines() == [line])
        #expect(tailer.hasMore)

        #expect(tailer.readNewLines() == [line])
        #expect(!tailer.hasMore)
    }

    @Test("skipToEnd ignores existing content")
    func skipToEnd() throws {
        let url = file()
        try append("history\n", to: url)
        let tailer = LineTailer(url: url)
        tailer.skipToEnd()
        #expect(tailer.readNewLines() == [])

        try append("live\n", to: url)
        #expect(tailer.readNewLines() == ["live"])
    }

    @Test("carriage returns are stripped")
    func carriageReturns() throws {
        let url = file()
        try append("windows\r\n", to: url)
        #expect(LineTailer(url: url).readNewLines() == ["windows"])
    }

    @Test("blank lines are skipped")
    func blankLines() throws {
        let url = file()
        try append("a\n\n\nb\n", to: url)
        #expect(LineTailer(url: url).readNewLines() == ["a", "b"])
    }
}
