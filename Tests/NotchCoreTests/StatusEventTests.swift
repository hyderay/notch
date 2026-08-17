import Foundation
import Testing
@testable import NotchCore

@Suite("StatusEvent")
struct StatusEventTests {
    private func decode(_ json: String) throws -> StatusEvent {
        try JSONDecoder().decode(StatusEvent.self, from: Data(json.utf8))
    }

    @Test("survives a JSON round trip")
    func roundTrip() throws {
        let event = StatusEvent(
            agent: "codex",
            session: "s1",
            state: "working",
            title: "notch",
            detail: "swift build",
            cwd: "/tmp",
            permissionRequestID: "request-1"
        )
        let line = try event.encodedLine()
        #expect(line.last == 0x0A)
        #expect(try JSONDecoder().decode(StatusEvent.self, from: line) == event)
    }

    @Test("missing fields fall back instead of throwing")
    func missingFields() throws {
        let event = try decode("{}")
        #expect(event.agent == "other")
        #expect(event.session == "")
        #expect(event.state == "working")
        #expect(event.v == StatusEvent.currentVersion)
    }

    @Test("wrongly typed fields degrade to defaults")
    func wrongTypes() throws {
        let event = try decode(#"{"agent":42,"session":true,"state":null}"#)
        #expect(event.agent == "other")
        #expect(event.state == "working")
    }

    @Test("agent and state names are normalized")
    func normalization() throws {
        let update = try decode(#"{"agent":"Claude-Code","session":"x","state":"WAITING"}"#).asUpdate()
        #expect(update.agent == .claude)
        #expect(update.state == .waiting)
    }

    @Test("an unknown state becomes idle rather than failing")
    func unknownState() throws {
        #expect(try decode(#"{"state":"exploding"}"#).asUpdate().state == .idle)
    }

    @Test("an empty session id gets a default identity")
    func defaultSession() throws {
        #expect(try decode(#"{"agent":"codex"}"#).asUpdate().sessionID == "default")
    }

    @Test("timestamps in seconds and milliseconds both work")
    func timestampUnits() throws {
        let millis = try decode(#"{"agent":"codex","session":"x","state":"done","ts":1786605303000}"#)
        let seconds = try decode(#"{"agent":"codex","session":"x","state":"done","ts":1786605303}"#)
        #expect(abs(millis.asUpdate().timestamp.timeIntervalSince1970 - 1_786_605_303) < 0.001)
        #expect(abs(seconds.asUpdate().timestamp.timeIntervalSince1970 - 1_786_605_303) < 0.001)
    }

    @Test("a missing timestamp uses the receive time")
    func receiveTime() throws {
        let received = Date(timeIntervalSince1970: 1_000)
        let event = try decode(#"{"agent":"codex","session":"x","state":"done"}"#)
        #expect(event.asUpdate(receivedAt: received).timestamp == received)
    }

    @Test("the title defaults to the project directory")
    func titleDefault() throws {
        let event = try decode(#"{"agent":"codex","session":"x","state":"working","cwd":"/Users/me/my-api"}"#)
        #expect(event.asUpdate().title == "my-api")
    }

    @Test("events from the socket carry IPC priority")
    func sourcePriority() throws {
        #expect(try decode(#"{"agent":"codex"}"#).asUpdate().source == .ipc)
    }
}

@Suite("Formatting helpers")
struct FormattingTests {
    @Test("project labels handle edge cases")
    func projectLabels() {
        #expect(projectLabel(forPath: nil) == nil)
        #expect(projectLabel(forPath: "") == nil)
        #expect(projectLabel(forPath: "/") == nil)
        #expect(projectLabel(forPath: "/Users/me/proj/") == "proj")
    }

    @Test(
        "elapsed times render as M:SS or H:MM:SS",
        arguments: [
            (TimeInterval(0), "0:00"),
            (TimeInterval(9), "0:09"),
            (TimeInterval(127), "2:07"),
            (TimeInterval(3_725), "1:02:05"),
            (TimeInterval(-5), "0:00"),
        ]
    )
    func elapsedFormatting(input: TimeInterval, expected: String) {
        #expect(formatElapsed(input) == expected)
    }

    @Test(
        "the compact timer never exceeds five characters",
        arguments: [
            (TimeInterval(0), "0:00"),
            (TimeInterval(127), "2:07"),
            (TimeInterval(3_599), "59:59"),
            (TimeInterval(3_725), "1h02"),
            (TimeInterval(86_400), "24h00"),
            (TimeInterval(360_000), "99h+"),
        ]
    )
    func compactElapsedFormatting(input: TimeInterval, expected: String) {
        let formatted = formatElapsedCompact(input)
        #expect(formatted == expected)
        #expect(formatted.count <= 5)
    }

    @Test("state urgency defines the aggregation order")
    func urgencyOrder() {
        let ordered = SessionState.allCases.sorted { $0.urgency < $1.urgency }
        #expect(ordered == [.idle, .done, .thinking, .working, .waiting, .error])
    }

    @Test("only thinking and working count as busy")
    func busyStates() {
        #expect(SessionState.allCases.filter(\.isBusy) == [.thinking, .working])
        #expect(SessionState.allCases.filter(\.isTerminal) == [.done, .error])
    }
}
