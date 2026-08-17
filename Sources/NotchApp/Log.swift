import Foundation

/// Diagnostic logging, off unless `NOTCH_DEBUG=1`.
///
/// A bundled LSUIElement app has no terminal attached, so `NOTCH_LOG_FILE`
/// redirects output somewhere readable. Both are settable for GUI launches with
/// `launchctl setenv`.
enum Log {
    static let isEnabled = ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let sink: FileHandle = {
        guard let path = ProcessInfo.processInfo.environment["NOTCH_LOG_FILE"], !path.isEmpty else {
            return FileHandle.standardError
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return FileHandle.standardError }
        _ = try? handle.seekToEnd()
        return handle
    }()

    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        write("[\(formatter.string(from: Date()))] \(message())")
    }

    /// Always emitted; used for failures the user needs to see.
    static func error(_ message: String) {
        write("[notch] \(message)")
    }

    private static func write(_ line: String) {
        try? sink.write(contentsOf: Data((line + "\n").utf8))
    }
}
