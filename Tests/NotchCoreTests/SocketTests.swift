import Darwin
import Foundation
import Testing
@testable import NotchCore

/// Minimal mutex wrapper so tests can capture values written on the socket queue.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}

@Suite("Unix socket", .serialized)
final class SocketTests {
    // sockaddr_un.sun_path caps out at 103 bytes, so keep this short rather
    // than using the deeply nested per-process temporary directory.
    private let path = "/tmp/notch-t-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
    private var server: SocketServer?

    deinit {
        server?.stop()
        unlink(path)
    }

    /// Polls instead of sleeping a fixed amount, so the suite stays fast.
    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    @Test("delivers each line to the handler")
    func deliversLines() throws {
        let received = Locked<[String]>([])
        let server = SocketServer(path: path) { line in
            received.mutate { $0.append(line) }
            return nil
        }
        try server.start()
        self.server = server

        try SocketClient.send(line: Data("first\n".utf8), toPath: path)
        try SocketClient.send(line: Data("second\n".utf8), toPath: path)

        #expect(waitUntil { received.value.count == 2 })
        #expect(received.value.sorted() == ["first", "second"])
    }

    @Test("a payload without a trailing newline still arrives")
    func missingNewline() throws {
        let received = Locked<String?>(nil)
        let server = SocketServer(path: path) { line in
            received.mutate { $0 = line }
            return nil
        }
        try server.start()
        self.server = server

        try SocketClient.send(line: Data("no-newline".utf8), toPath: path)
        #expect(waitUntil { received.value != nil })
        #expect(received.value == "no-newline")
    }

    @Test("supports request and response")
    func requestResponse() throws {
        let server = SocketServer(path: path) { line in
            line == "ping" ? Data("pong\n".utf8) : nil
        }
        try server.start()
        self.server = server

        #expect(try SocketClient.send(line: Data("ping\n".utf8), toPath: path, expectReply: true) == "pong")
    }

    @Test("status events survive the wire intact")
    func statusEvents() throws {
        let received = Locked<StatusEvent?>(nil)
        let server = SocketServer(path: path) { line in
            received.mutate { $0 = try? JSONDecoder().decode(StatusEvent.self, from: Data(line.utf8)) }
            return nil
        }
        try server.start()
        self.server = server

        let event = StatusEvent(agent: "codex", session: "s1", state: "working", detail: "unicode \u{2026} ok")
        try SocketClient.send(line: event.encodedLine(), toPath: path)

        #expect(waitUntil { received.value != nil })
        #expect(received.value?.detail == "unicode \u{2026} ok")
    }

    @Test("a second instance refuses to steal a live socket")
    func addressInUse() throws {
        let first = SocketServer(path: path) { _ in nil }
        try first.start()
        server = first

        let second = SocketServer(path: path) { _ in nil }
        #expect(throws: SocketError.self) { try second.start() }
    }

    @Test("a stale socket file left by a crash is reclaimed")
    func staleSocket() throws {
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = SocketServer(path: path) { _ in nil }
        try server.start()
        self.server = server
        #expect(SocketClient.isListening(atPath: path))
    }

    @Test("stopping removes the socket file")
    func stopCleansUp() throws {
        let server = SocketServer(path: path) { _ in nil }
        try server.start()
        #expect(FileManager.default.fileExists(atPath: path))

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!SocketClient.isListening(atPath: path))
    }

    @Test("sending to a dead socket throws")
    func deadSocket() {
        #expect(throws: SocketError.self) {
            try SocketClient.send(line: Data("x\n".utf8), toPath: path)
        }
    }

    @Test("an overlong socket path is rejected before syscalls")
    func overlongPath() {
        let long = "/tmp/" + String(repeating: "p", count: 120) + ".sock"
        #expect(throws: SocketError.self) {
            try SocketClient.send(line: Data("x\n".utf8), toPath: long)
        }
    }
}

@Suite("LineBuffer")
struct LineBufferTests {
    @Test("reassembles a line split across reads")
    func splitLine() {
        let buffer = LineBuffer()
        #expect(buffer.append(bytes: Array("par".utf8), count: 3) == [])
        #expect(buffer.append(bytes: Array("tial\nnext\n".utf8), count: 10) == ["partial", "next"])
        #expect(buffer.flush() == nil)
    }

    @Test("flushes trailing bytes at EOF")
    func flushTrailing() {
        let buffer = LineBuffer()
        _ = buffer.append(bytes: Array("dangling".utf8), count: 8)
        #expect(buffer.flush() == "dangling")
    }

    @Test("drops input that exceeds the limit instead of growing without bound")
    func overflow() {
        let buffer = LineBuffer(limit: 16)
        let bytes = Array(String(repeating: "x", count: 32).utf8)
        #expect(buffer.append(bytes: bytes, count: bytes.count) == [])
        #expect(buffer.overflowed)
    }
}
