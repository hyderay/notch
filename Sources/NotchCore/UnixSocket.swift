import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(Int)
    case createFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case connectFailed(Int32)
    case writeFailed(Int32)
    case addressInUse

    public var description: String {
        switch self {
        case let .pathTooLong(n): return "socket path too long (\(n) bytes, max 103)"
        case let .createFailed(e): return "socket() failed: \(String(cString: strerror(e)))"
        case let .bindFailed(e): return "bind() failed: \(String(cString: strerror(e)))"
        case let .listenFailed(e): return "listen() failed: \(String(cString: strerror(e)))"
        case let .connectFailed(e): return "connect() failed: \(String(cString: strerror(e)))"
        case let .writeFailed(e): return "write() failed: \(String(cString: strerror(e)))"
        case .addressInUse: return "another Notch instance already owns the socket"
        }
    }
}

/// Fills a `sockaddr_un` for `path`, or throws if it will not fit.
private func makeAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw SocketError.pathTooLong(bytes.count) }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
            for (index, byte) in bytes.enumerated() { dest[index] = CChar(bitPattern: byte) }
            dest[bytes.count] = 0
        }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

/// A line-oriented Unix domain socket server.
///
/// Each accepted connection is read until EOF; every complete line is handed to
/// `onLine`, whose return value (if any) is written back to the client. That is
/// enough for both fire-and-forget status pushes and the `status` query.
public final class SocketServer: @unchecked Sendable {
    public typealias LineHandler = @Sendable (String) -> Data?

    private let path: String
    private let queue = DispatchQueue(label: "com.wanquanlin.notch.socket", qos: .utility)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: DispatchSourceRead] = [:]
    private let onLine: LineHandler

    public init(path: String, onLine: @escaping LineHandler) {
        self.path = path
        self.onLine = onLine
    }

    deinit { stop() }

    /// Binds and starts accepting. Throws `.addressInUse` when another live
    /// instance already answers on this path.
    public func start() throws {
        if SocketClient.isListening(atPath: path) {
            throw SocketError.addressInUse
        }
        // Nothing answered, so any file here is a leftover from a crash.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        var address = try makeAddress(path: path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                Darwin.bind(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw SocketError.bindFailed(err)
        }

        chmod(path, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw SocketError.listenFailed(err)
        }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
    }

    /// Tears everything down on `queue`, which is the only thread that touches
    /// `listenFD`, `acceptSource`, and `clients` — doing part of this on the
    /// caller's thread would race with an in-flight accept or read.
    public func stop() {
        queue.sync {
            for source in clients.values { source.cancel() }
            clients.removeAll()
            acceptSource?.cancel()
            acceptSource = nil
            guard listenFD >= 0 else { return }
            listenFD = -1
            unlink(path)
        }
    }

    private func acceptPending() {
        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                // EAGAIN just means the backlog is drained.
                return
            }
            _ = fcntl(clientFD, F_SETFL, fcntl(clientFD, F_GETFL, 0) | O_NONBLOCK)
            attach(clientFD: clientFD)
        }
    }

    private func attach(clientFD: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        // Per-connection buffer for a line split across reads.
        let buffer = LineBuffer()

        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(clientFD, &chunk, chunk.count)
            if count > 0 {
                for line in buffer.append(bytes: chunk, count: count) {
                    if let reply = self.onLine(line) {
                        _ = reply.withUnsafeBytes { raw -> Int in
                            guard let base = raw.baseAddress else { return 0 }
                            return write(clientFD, base, raw.count)
                        }
                    }
                }
                if buffer.overflowed { self.detach(clientFD: clientFD) }
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                // Flush a trailing line that arrived without a newline.
                if let line = buffer.flush(), let reply = self.onLine(line) {
                    _ = reply.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return write(clientFD, base, raw.count)
                    }
                }
                self.detach(clientFD: clientFD)
            }
        }
        source.setCancelHandler { close(clientFD) }
        clients[clientFD] = source
        source.resume()
    }

    private func detach(clientFD: Int32) {
        guard let source = clients.removeValue(forKey: clientFD) else { return }
        source.cancel()
    }
}

/// Accumulates bytes and yields complete lines.
final class LineBuffer {
    private var storage: [UInt8] = []
    private let limit: Int
    private(set) var overflowed = false

    init(limit: Int = 1 << 20) {
        self.limit = limit
    }

    func append(bytes: [UInt8], count: Int) -> [String] {
        guard count > 0 else { return [] }
        storage.append(contentsOf: bytes[0..<count])
        if storage.count > limit {
            overflowed = true
            storage.removeAll(keepingCapacity: false)
            return []
        }

        var lines: [String] = []
        var start = 0
        for index in storage.indices where storage[index] == 0x0A {
            if index > start, let line = String(bytes: storage[start..<index], encoding: .utf8) {
                lines.append(line)
            }
            start = index + 1
        }
        if start > 0 { storage.removeFirst(start) }
        return lines
    }

    func flush() -> String? {
        defer { storage.removeAll(keepingCapacity: false) }
        guard !storage.isEmpty else { return nil }
        return String(bytes: storage, encoding: .utf8)
    }
}

/// Blocking client used by `notchctl`.
public enum SocketClient {
    /// Sends one line and optionally waits for a single-line reply.
    @discardableResult
    public static func send(
        line: Data,
        toPath path: String,
        expectReply: Bool = false,
        timeout: TimeInterval = 2.0
    ) throws -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }
        defer { close(fd) }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = try makeAddress(path: path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                Darwin.connect(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SocketError.connectFailed(errno) }

        var payload = line
        if payload.last != 0x0A { payload.append(0x0A) }
        try payload.withUnsafeBytes { raw in
            var offset = 0
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    throw SocketError.writeFailed(errno)
                }
                offset += written
            }
        }

        guard expectReply else { return nil }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                response.append(contentsOf: chunk[0..<count])
                if response.last == 0x0A { break }
            } else {
                break
            }
        }
        return String(data: response, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when something is actively accepting connections on `path`.
    public static func isListening(atPath path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var address = try? makeAddress(path: path) else { return false }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                Darwin.connect(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}
