import Foundation
import NotchCore

let usage = """
notchctl — push agent status into the Notch overlay

Usage:
  notchctl <state> [options]          Set a session's state
  notchctl remove [options]           Drop a session from the overlay
  notchctl status                     Print what the app is currently showing
  notchctl inspect                    Print the overlay's geometry and layout
  notchctl snapshot [path]            Render the overlay to a PNG
  notchctl ping                       Check whether the app is running
  notchctl demo                       Play a scripted sequence for testing
  notchctl permission [options]       Wait for an Allow/Deny choice in Notch
  notchctl install-hooks              Wire Claude Code / Codex up to notchctl
  notchctl uninstall-hooks            Undo install-hooks
  notchctl doctor                     Report on the local setup
  notchctl hook <kind> [args]         Entry point invoked by agent hooks

States:
  idle  thinking  working  waiting  done  error

Options:
  --agent <name>      codex | claude | cursor | other   (default: other)
  --session <id>      Stable session id                 (default: default)
  --title <text>      Label shown in the overlay
  --detail <text>     Current action, e.g. "Bash: npm test"
  --cwd <path>        Working directory
  --permission-request <id>           Make a waiting event actionable

Environment:
  NOTCH_SOCKET        Override the socket path (default ~/.notch/notch.sock)

Examples:
  notchctl working --agent codex --session build --detail "swift build"
  notchctl done --agent codex --session build
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if let equals = key.firstIndex(of: "=") {
                    options[String(key[key.startIndex..<equals])] = String(key[key.index(after: equals)...])
                } else if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    options[key] = raw[index + 1]
                    index += 1
                } else {
                    options[key] = "true"
                }
            } else {
                positional.append(token)
            }
            index += 1
        }
    }

    subscript(_ key: String) -> String? { options[key] }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("notchctl: \(message)\n".utf8))
    exit(code)
}

/// Sends an event. `quiet` is used by hooks so a stopped app never turns into a
/// visible error inside the agent's own output.
@discardableResult
func send(_ event: StatusEvent, expectReply: Bool = false, quiet: Bool = false) -> String? {
    do {
        let line = try event.encodedLine()
        return try SocketClient.send(line: line, toPath: NotchPaths.socket.path, expectReply: expectReply)
    } catch {
        if quiet { exit(0) }
        fail("\(error)")
    }
}

func makeEvent(state: String, args: Arguments, remove: Bool = false) -> StatusEvent {
    StatusEvent(
        agent: args["agent"] ?? "other",
        session: args["session"] ?? "default",
        state: state,
        title: args["title"],
        detail: args["detail"],
        cwd: args["cwd"],
        ts: Date().timeIntervalSince1970,
        remove: remove ? true : nil,
        permissionRequestID: args["permission-request"]
    )
}

// MARK: - Hook entry points

/// Claude Code hooks deliver a JSON payload on stdin.
func runClaudeHook(state: String) -> Never {
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]

    let sessionID = (payload["session_id"] as? String) ?? "default"
    let cwd = payload["cwd"] as? String
    let toolName = payload["tool_name"] as? String

    if state == "end" {
        send(StatusEvent(agent: "claude", session: sessionID, state: "done", remove: true), quiet: true)
        exit(0)
    }

    if state == "permission" {
        let requestID = UUID().uuidString
        let detail = toolName.map { "Permission: \($0)" }
            ?? (payload["message"] as? String)
            ?? "Permission required"
        PermissionBridge.prepare(requestID: requestID)
        send(
            StatusEvent(
                agent: "claude",
                session: sessionID,
                state: "waiting",
                title: cwd.flatMap { projectLabel(forPath: $0) },
                detail: detail,
                cwd: cwd,
                ts: Date().timeIntervalSince1970,
                permissionRequestID: requestID
            ),
            quiet: true
        )
        let decision = PermissionBridge.wait(for: requestID) ?? .reject
        let behavior = decision == .approve ? "allow" : "deny"
        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": behavior],
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: response),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit(0)
    }

    var detail: String?
    switch state {
    case "working":
        detail = toolName
    case "thinking":
        detail = "Thinking"
    case "waiting":
        detail = (payload["message"] as? String) ?? "Waiting for you"
    default:
        detail = nil
    }

    send(
        StatusEvent(
            agent: "claude",
            session: sessionID,
            state: state,
            title: cwd.flatMap { projectLabel(forPath: $0) },
            detail: detail,
            cwd: cwd,
            ts: Date().timeIntervalSince1970
        ),
        quiet: true
    )
    exit(0)
}

/// Codex's `notify` program receives one JSON argument and no session identity,
/// so the session is recovered by matching the working directory.
func runCodexNotifyHook(arguments: [String]) -> Never {
    let blob = arguments.last.flatMap { $0.data(using: .utf8) }
    let payload = blob.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    let type = (payload["type"] as? String) ?? ""

    let cwd = FileManager.default.currentDirectoryPath
    guard let match = CodexSessionLocator.mostRecentSession(matchingCwd: cwd) else { exit(0) }

    let state: String
    switch type {
    case "agent-turn-complete", "turn-ended", "turn-complete":
        state = "done"
    case "agent-turn-failed", "error":
        state = "error"
    default:
        state = "done"
    }

    send(
        StatusEvent(
            agent: "codex",
            session: match.sessionID,
            state: state,
            title: projectLabel(forPath: match.cwd ?? cwd),
            detail: nil,
            cwd: match.cwd ?? cwd,
            ts: Date().timeIntervalSince1970
        ),
        quiet: true
    )
    exit(0)
}

// MARK: - Commands

func runStatus() -> Never {
    let request = StatusEvent(agent: "cli", session: "-", state: "idle", op: "status")
    guard let reply = send(request, expectReply: true),
          let data = reply.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        fail("no response from Notch (is the app running?)")
    }

    let global = (root["globalState"] as? String) ?? "idle"
    let sessions = (root["sessions"] as? [[String: Any]]) ?? []
    print("global: \(global)  sessions: \(sessions.count)")
    for session in sessions {
        let agent = (session["agent"] as? String) ?? "?"
        let state = (session["state"] as? String) ?? "?"
        let title = (session["title"] as? String) ?? "?"
        let elapsed = (session["elapsed"] as? Int) ?? 0
        let source = (session["source"] as? String) ?? "?"
        let detail = (session["detail"] as? String).map { "  \u{2014} \($0)" } ?? ""
        print(String(
            format: "  %-7@ %-8@ %-18@ %6@  [%@]%@",
            agent as NSString,
            state as NSString,
            title as NSString,
            formatElapsed(TimeInterval(elapsed)) as NSString,
            source as NSString,
            detail as NSString
        ))
    }
    exit(0)
}

func runInspect() -> Never {
    let request = StatusEvent(agent: "cli", session: "-", state: "idle", op: "inspect")
    guard let reply = send(request, expectReply: true),
          let data = reply.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        fail("no response from Notch (is the app running?)")
    }

    func rect(_ key: String) -> String {
        guard let r = root[key] as? [String: Double] else { return "?" }
        return String(
            format: "x=%.0f y=%.0f w=%.0f h=%.0f",
            r["x"] ?? 0, r["y"] ?? 0, r["w"] ?? 0, r["h"] ?? 0
        )
    }

    let size = root["contentSize"] as? [String: Double] ?? [:]
    print("Overlay")
    print("  presentation      \((root["presentation"] as? String) ?? "?")")
    print("  visible           \((root["visible"] as? Bool) == true ? "yes" : "no")")
    print("  notch             \((root["hasRealNotch"] as? Bool) == true ? "hardware" : "virtual")")
    print("  screen            \(rect("screenFrame"))")
    print("  cutout width      \((root["voidWidth"] as? Double) ?? 0)")
    print("  strip height      \((root["notchHeight"] as? Double) ?? 0)")
    print("  side width        \((root["sideWidth"] as? Double) ?? 0)")
    print(String(format: "  content size      w=%.0f h=%.0f", size["w"] ?? 0, size["h"] ?? 0))
    print("  window            \(rect("windowFrame"))")
    print("  full screen       \((root["fullScreenActive"] as? Bool) == true ? "yes" : "no")")
    print("  hide full screen  \((root["hideInFullScreen"] as? Bool) == true ? "on" : "off")")
    print("  gesture hidden    \((root["gestureHidden"] as? Bool) == true ? "yes" : "no")")
    print("  two-finger swipe  \((root["swipeGestures"] as? Bool) == true ? "on" : "off")")
    print("  hovering          \((root["hovering"] as? Bool) == true ? "yes" : "no")")
    print("  auto-expanding    \((root["autoExpanding"] as? Bool) == true ? "yes" : "no")")
    print("  sessions          \((root["sessionCount"] as? Int) ?? 0) (\((root["globalState"] as? String) ?? "?"))")
    exit(0)
}

func runDemo() -> Never {
    struct Step {
        let delay: TimeInterval
        let event: StatusEvent
    }

    func event(
        _ agent: String,
        _ session: String,
        _ state: String,
        _ title: String,
        _ detail: String?,
        remove: Bool = false
    ) -> StatusEvent {
        StatusEvent(
            agent: agent,
            session: session,
            state: state,
            title: title,
            detail: detail,
            cwd: FileManager.default.currentDirectoryPath,
            remove: remove ? true : nil
        )
    }

    let script: [Step] = [
        Step(delay: 0.0, event: event("codex", "demo-1", "thinking", "notch", "Thinking")),
        Step(delay: 1.8, event: event("codex", "demo-1", "working", "notch", "Run swift build")),
        Step(delay: 1.8, event: event("claude", "demo-2", "thinking", "my-api", "Thinking")),
        Step(delay: 1.6, event: event("codex", "demo-1", "working", "notch", "Editing NotchPanel.swift")),
        Step(delay: 1.6, event: event("claude", "demo-2", "working", "my-api", "Bash: npm test")),
        Step(delay: 2.0, event: event("claude", "demo-2", "waiting", "my-api", "Needs permission to write")),
        Step(delay: 2.6, event: event("claude", "demo-2", "working", "my-api", "Edit: server.ts")),
        Step(delay: 1.6, event: event("codex", "demo-1", "done", "notch", nil)),
        Step(delay: 2.0, event: event("claude", "demo-2", "error", "my-api", "Command failed: exit 1")),
        Step(delay: 5.0, event: event("claude", "demo-2", "idle", "my-api", nil, remove: true)),
    ]

    guard send(StatusEvent(agent: "cli", session: "-", state: "idle", op: "ping"), expectReply: true) != nil else {
        fail("no response from Notch (is the app running?)")
    }

    for step in script {
        Thread.sleep(forTimeInterval: step.delay)
        var stamped = step.event
        stamped.ts = Date().timeIntervalSince1970
        send(stamped)
        let label = stamped.remove == true ? "remove" : stamped.state
        print("\(stamped.agent)/\(stamped.session) -> \(label)")
    }
    print("demo finished")
    exit(0)
}

func runPermission(args: Arguments) -> Never {
    let requestID = args["permission-request"] ?? UUID().uuidString
    PermissionBridge.prepare(requestID: requestID)
    var event = makeEvent(state: "waiting", args: args)
    event.permissionRequestID = requestID
    send(event)
    let timeout = Double(args["timeout"] ?? "900") ?? 900
    guard let decision = PermissionBridge.wait(for: requestID, timeout: timeout) else {
        fail("permission request timed out", code: 2)
    }
    print(decision.rawValue)
    exit(decision == .approve ? 0 : 3)
}

func runInstallHooks(uninstall: Bool) -> Never {
    let report = uninstall ? HookInstaller.uninstallAll() : HookInstaller.installAll()
    for message in report.messages { print(message) }
    if report.didChange {
        print("\nRestart any running agent sessions for the hooks to take effect.")
    }
    exit(report.needsManualStep ? 2 : 0)
}

func runDoctor() -> Never {
    let fm = FileManager.default
    let socketPath = NotchPaths.socket.path
    let running = SocketClient.isListening(atPath: socketPath)

    print("Notch doctor")
    print("  socket            \(socketPath)")
    print("  app running       \(running ? "yes" : "no")")
    print("  notchctl path     \(HookInstaller.notchctlPath())")
    print("  codex home        \(fm.fileExists(atPath: NotchPaths.codexHome.path) ? NotchPaths.codexHome.path : "not found")")
    print("  codex sessions    \(fm.fileExists(atPath: NotchPaths.codexSessions.path) ? "present" : "not found")")
    print("  claude home       \(fm.fileExists(atPath: NotchPaths.claudeHome.path) ? NotchPaths.claudeHome.path : "not found")")

    let claudeHooked = (try? String(contentsOf: NotchPaths.claudeSettings, encoding: .utf8))?
        .contains("notchctl hook claude") ?? false
    let codexHooked = (try? String(contentsOf: NotchPaths.codexConfig, encoding: .utf8))?
        .contains("notchctl") ?? false
    print("  claude hooks      \(claudeHooked ? "installed" : "not installed")")
    print("  codex notify      \(codexHooked ? "installed" : "not installed")")

    if let match = CodexSessionLocator.mostRecentSession(matchingCwd: nil) {
        print("  latest codex      \(match.sessionID) (\(match.cwd ?? "unknown cwd"))")
    }
    exit(running ? 0 : 1)
}

// MARK: - Dispatch

let rawArguments = Array(CommandLine.arguments.dropFirst())
guard let command = rawArguments.first else {
    print(usage)
    exit(0)
}
let args = Arguments(Array(rawArguments.dropFirst()))

switch command {
case "-h", "--help", "help":
    print(usage)
    exit(0)

case "hook":
    guard let kind = args.positional.first else { fail("hook requires a kind") }
    switch kind {
    case "claude":
        guard let state = args.positional.dropFirst().first else { fail("hook claude requires a state") }
        runClaudeHook(state: state)
    case "codex-notify":
        runCodexNotifyHook(arguments: rawArguments)
    default:
        fail("unknown hook kind: \(kind)")
    }

case "status":
    runStatus()

case "inspect":
    runInspect()

case "snapshot":
    let requested = args.positional.first ?? "/tmp/notch-snapshot.png"
    let path = URL(fileURLWithPath: requested, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
    guard let reply = send(
        StatusEvent(agent: "cli", session: "-", state: "idle", detail: path, op: "snapshot"),
        expectReply: true
    ),
        let data = reply.data(using: .utf8),
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        fail("no response from Notch (is the app running?)")
    }
    print((root["message"] as? String) ?? "unknown result")
    exit((root["ok"] as? Bool) == true ? 0 : 1)

case "ping":
    if send(StatusEvent(agent: "cli", session: "-", state: "idle", op: "ping"), expectReply: true) != nil {
        print("ok")
        exit(0)
    }
    fail("no response")

case "demo":
    runDemo()

case "permission":
    runPermission(args: args)

case "install-hooks":
    runInstallHooks(uninstall: false)

case "uninstall-hooks":
    runInstallHooks(uninstall: true)

case "doctor":
    runDoctor()

case "remove":
    send(makeEvent(state: "idle", args: args, remove: true))
    exit(0)

case "idle", "thinking", "working", "waiting", "done", "error":
    send(makeEvent(state: command, args: args))
    exit(0)

default:
    fail("unknown command: \(command)\n\n\(usage)")
}
