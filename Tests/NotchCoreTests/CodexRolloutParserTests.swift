import Foundation
import Testing
@testable import NotchCore

/// Fixtures below are trimmed copies of lines from a real
/// `~/.codex/sessions/**/rollout-*.jsonl` written by codex-cli 0.147.0.
private enum Fixture {
    static let meta = """
    {"timestamp":"2026-08-13T07:15:03.442Z","ordinal":0,"type":"session_meta","payload":{"session_id":"019ff9f9-0b4e-7880-aae2-ba91d0065df0","timestamp":"2026-08-13T07:14:35.985Z","cwd":"/Users/me/New project","originator":"codex-tui"}}
    """

    static let taskStarted = """
    {"timestamp":"2026-08-13T07:15:03.443Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":1786605303}}
    """

    static let taskComplete = """
    {"timestamp":"2026-08-13T07:15:45.668Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"done"}}
    """

    static let commandItem = """
    {"timestamp":"2026-08-13T07:15:18.113Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","command":["/bin/zsh","-lc","swift build"],"cwd":"file:///Users/me/New%20project","parsed_cmd":[{"type":"unknown","cmd":"swift build"}],"status":"success"}}}
    """
}

@Suite("CodexRolloutParser")
struct CodexRolloutParserTests {
    @Test("parses session metadata")
    func sessionMeta() throws {
        let event = try #require(CodexRolloutParser.parse(line: Fixture.meta))
        guard case let .meta(sessionID, cwd, startedAt) = event else {
            Issue.record("expected meta, got \(event)")
            return
        }
        #expect(sessionID == "019ff9f9-0b4e-7880-aae2-ba91d0065df0")
        #expect(cwd == "/Users/me/New project")
        #expect(startedAt != nil)
    }

    @Test("parses turn boundaries")
    func taskBoundaries() {
        #expect(CodexRolloutParser.parse(line: Fixture.taskStarted) == .taskStarted(
            at: ISO8601DateFormatter.notchParse("2026-08-13T07:15:03.443Z")
        ))
        #expect(CodexRolloutParser.parse(line: Fixture.taskComplete) == .taskComplete(
            at: ISO8601DateFormatter.notchParse("2026-08-13T07:15:45.668Z")
        ))
    }

    @Test("describes a command execution item")
    func commandDescription() throws {
        let event = try #require(CodexRolloutParser.parse(line: Fixture.commandItem))
        guard case let .item(detail, _) = event else {
            Issue.record("expected item, got \(event)")
            return
        }
        #expect(detail == "Run swift build")
    }

    @Test("describes the item types codex actually emits")
    func itemDescriptions() {
        #expect(CodexRolloutParser.describe(item: ["type": "Reasoning"]) == "Thinking")
        #expect(CodexRolloutParser.describe(item: ["type": "AgentMessage"]) == "Writing a response")
        #expect(CodexRolloutParser.describe(item: ["type": "ContextCompaction"]) == "Compacting context")
        #expect(CodexRolloutParser.describe(item: ["type": "UserMessage"]) == nil)
        #expect(
            CodexRolloutParser.describe(item: [
                "type": "FileChange",
                "changes": [["path": "/a/b/Server.swift"], ["path": "/a/b/Client.swift"]],
            ]) == "Editing Server.swift +1"
        )
    }

    @Test("unwraps the shell wrapper around commands")
    func shellUnwrapping() {
        #expect(
            CodexRolloutParser.describe(item: [
                "type": "CommandExecution",
                "command": ["/bin/zsh", "-lc", "npm run test"],
            ]) == "Run npm run test"
        )
    }

    @Test("prefers the parsed command summary when codex supplies one")
    func parsedCommandSummary() {
        #expect(
            CodexRolloutParser.describe(item: [
                "type": "CommandExecution",
                "command": ["/bin/zsh", "-lc", "rg TODO"],
                "parsed_cmd": [["type": "search", "query": "TODO"]],
            ]) == "Searching TODO"
        )
    }

    @Test("unknown and malformed lines are skipped")
    func lenientParsing() {
        #expect(CodexRolloutParser.parse(line: "not json") == nil)
        #expect(CodexRolloutParser.parse(line: "{}") == nil)
        #expect(CodexRolloutParser.parse(line: #"{"type":"response_item","payload":{}}"#) == nil)
        #expect(CodexRolloutParser.parse(line: #"{"type":"event_msg","payload":{"type":"token_count"}}"#) == nil)
        #expect(CodexRolloutParser.parse(line: #"{"type":"session_meta","payload":{"cwd":"/tmp"}}"#) == nil)
    }

    @Test("tracker follows a turn from start to completion")
    func trackerTurn() throws {
        let tracker = CodexSessionTracker(fallbackID: "fallback")
        let now = Date()

        tracker.consume(line: Fixture.meta, now: now)
        #expect(tracker.sessionID == "019ff9f9-0b4e-7880-aae2-ba91d0065df0")
        #expect(tracker.update(fileModifiedAt: now, now: now) == nil, "metadata alone is not activity")

        tracker.consume(line: Fixture.taskStarted, now: now)
        let working = try #require(tracker.update(fileModifiedAt: now, now: now))
        #expect(working.state == .working)
        #expect(working.agent == .codex)
        #expect(working.title == "New project")
        #expect(working.source == .file)

        tracker.consume(line: Fixture.commandItem, now: now)
        #expect(tracker.detail == "Run swift build")

        tracker.consume(line: Fixture.taskComplete, now: now)
        let done = try #require(tracker.update(fileModifiedAt: now, now: now))
        #expect(done.state == .done)
        #expect(done.detail == nil)
    }

    @Test("items arriving after completion do not resurrect the turn")
    func noResurrection() {
        let tracker = CodexSessionTracker(fallbackID: "fallback")
        let now = Date()
        tracker.consume(line: Fixture.meta, now: now)
        tracker.consume(line: Fixture.taskStarted, now: now)
        tracker.consume(line: Fixture.taskComplete, now: now)
        tracker.consume(line: Fixture.commandItem, now: now)

        #expect(tracker.state == .done)
        #expect(tracker.detail == nil)
    }

    @Test("the filename identifies the session until metadata arrives")
    func fallbackIdentity() throws {
        let tracker = CodexSessionTracker(fallbackID: "rollout-abc")
        let now = Date()
        tracker.consume(line: Fixture.taskStarted, now: now)
        let update = try #require(tracker.update(fileModifiedAt: now, now: now))
        #expect(update.sessionID == "rollout-abc")
    }

    @Test("a vanished process removes an unfinished turn")
    func vanishedProcess() throws {
        let tracker = CodexSessionTracker(fallbackID: "rollout-abc")
        let now = Date()
        tracker.consume(line: Fixture.meta, now: now)
        tracker.consume(line: Fixture.taskStarted, now: now)

        let removal = try #require(tracker.processExited(now: now.addingTimeInterval(2)))
        #expect(removal.sessionID == "019ff9f9-0b4e-7880-aae2-ba91d0065df0")
        #expect(removal.remove)
        #expect(removal.state == .idle)
        #expect(tracker.state == .idle)
        #expect(tracker.detail == nil)
        #expect(tracker.processExited(now: now.addingTimeInterval(3)) == nil)
    }

    @Test("lsof field output yields only open rollout paths")
    func lsofOutputParsing() {
        let data = Data("p123\nf41\nn/tmp/rollout-a.jsonl\np456\nf9\nn/tmp/rollout-b.jsonl\n".utf8)
        #expect(CodexProcessProbe.parsePaths(from: data) == [
            "/tmp/rollout-a.jsonl",
            "/tmp/rollout-b.jsonl",
        ])
    }

    @Test("file URL working directories are normalized")
    func cwdNormalization() {
        #expect(normalizeCwd("file:///Users/me/New%20project") == "/Users/me/New project")
        #expect(normalizeCwd("/Users/me/plain") == "/Users/me/plain")
    }
}
