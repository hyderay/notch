import Foundation
import Testing
@testable import NotchCore

private enum Fixture {
    static let userPrompt = """
    {"type":"user","sessionId":"abc-123","cwd":"/Users/me/api","timestamp":"2026-08-13T07:15:03.442Z","message":{"role":"user","content":[{"type":"text","text":"fix the bug"}]}}
    """

    static let assistantTool = """
    {"type":"assistant","sessionId":"abc-123","cwd":"/Users/me/api","timestamp":"2026-08-13T07:15:05.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
    """

    static let toolResult = """
    {"type":"user","sessionId":"abc-123","cwd":"/Users/me/api","timestamp":"2026-08-13T07:15:09.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
    """

    static let assistantText = """
    {"type":"assistant","sessionId":"abc-123","cwd":"/Users/me/api","timestamp":"2026-08-13T07:15:12.000Z","message":{"role":"assistant","content":[{"type":"text","text":"All done."}]}}
    """
}

@Suite("ClaudeTranscriptParser")
struct ClaudeTranscriptParserTests {
    @Test("classifies the four entry shapes that matter")
    func entryShapes() throws {
        guard case .userPrompt = try #require(ClaudeTranscriptParser.parse(line: Fixture.userPrompt)) else {
            Issue.record("expected userPrompt")
            return
        }
        guard case let .assistantTool(detail, _) =
            try #require(ClaudeTranscriptParser.parse(line: Fixture.assistantTool))
        else {
            Issue.record("expected assistantTool")
            return
        }
        #expect(detail == "Bash: npm test")
        guard case .toolResult = try #require(ClaudeTranscriptParser.parse(line: Fixture.toolResult)) else {
            Issue.record("expected toolResult")
            return
        }
        guard case .assistantText = try #require(ClaudeTranscriptParser.parse(line: Fixture.assistantText)) else {
            Issue.record("expected assistantText")
            return
        }
    }

    @Test("sub-agent sidechains are ignored so turns are not double counted")
    func sidechains() {
        let line = """
        {"type":"assistant","isSidechain":true,"sessionId":"abc","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        """
        #expect(ClaudeTranscriptParser.parse(line: line) == nil)
    }

    @Test("synthetic meta entries are ignored")
    func metaEntries() {
        let line = """
        {"type":"user","isMeta":true,"sessionId":"abc","message":{"role":"user","content":[{"type":"text","text":"<system>"}]}}
        """
        #expect(ClaudeTranscriptParser.parse(line: line) == nil)
    }

    @Test("string message content is accepted alongside block arrays")
    func stringContent() throws {
        let line = """
        {"type":"user","sessionId":"abc","message":{"role":"user","content":"plain string"}}
        """
        guard case .userPrompt = try #require(ClaudeTranscriptParser.parse(line: line)) else {
            Issue.record("expected userPrompt")
            return
        }
    }

    @Test("tool descriptions pick the most useful argument")
    func toolDescriptions() {
        #expect(
            ClaudeTranscriptParser.describe(toolUse: ["name": "Read", "input": ["file_path": "/a/b/main.swift"]])
                == "Read: main.swift"
        )
        #expect(
            ClaudeTranscriptParser.describe(toolUse: ["name": "Grep", "input": ["pattern": "TODO"]])
                == "Grep: TODO"
        )
        #expect(
            ClaudeTranscriptParser.describe(toolUse: ["name": "WebFetch", "input": ["url": "https://example.com/a"]])
                == "WebFetch: example.com"
        )
        #expect(ClaudeTranscriptParser.describe(toolUse: ["name": "UnknownTool"]) == "UnknownTool")
        #expect(ClaudeTranscriptParser.describe(toolUse: [:]) == nil)
    }

    @Test("long arguments are truncated with an ellipsis")
    func truncation() {
        let long = String(repeating: "a", count: 100)
        let detail = ClaudeTranscriptParser.describe(toolUse: ["name": "Bash", "input": ["command": long]])
        #expect(detail?.count == "Bash: ".count + 34)
        #expect(detail?.hasSuffix("\u{2026}") == true)
    }

    @Test("tracker walks a full prompt-tool-answer turn")
    func trackerTurn() throws {
        let tracker = ClaudeSessionTracker(fallbackID: "file-id")
        let now = Date()

        tracker.consume(line: Fixture.userPrompt, now: now)
        var update = try #require(tracker.update(fileModifiedAt: now, now: now))
        #expect(update.state == .thinking)
        #expect(update.sessionID == "abc-123")
        #expect(update.title == "api")

        tracker.consume(line: Fixture.assistantTool, now: now)
        update = try #require(tracker.update(fileModifiedAt: now, now: now))
        #expect(update.state == .working)
        #expect(update.detail == "Bash: npm test")

        tracker.consume(line: Fixture.toolResult, now: now)
        #expect(tracker.state == .working)

        tracker.consume(line: Fixture.assistantText, now: now)
        update = try #require(tracker.update(fileModifiedAt: now, now: now))
        #expect(update.state == .done)
        #expect(update.detail == nil)
    }

    @Test("no update is produced before any entry is seen")
    func emptyTracker() {
        let tracker = ClaudeSessionTracker(fallbackID: "file-id")
        #expect(tracker.update(fileModifiedAt: Date(), now: Date()) == nil)
    }

    @Test("the session start time comes from the first entry")
    func startTime() {
        let tracker = ClaudeSessionTracker(fallbackID: "file-id")
        tracker.consume(line: Fixture.userPrompt)
        #expect(tracker.startedAt == ISO8601DateFormatter.notchParse("2026-08-13T07:15:03.442Z"))
    }
}
