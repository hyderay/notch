import Foundation
import NotchCore

/// Pushes a scripted sequence of sessions into the store so the UI can be
/// exercised without a real agent running.
enum DemoDriver {
    private struct Step {
        let delay: TimeInterval
        let updates: [SessionUpdate]
    }

    static func run(store: SessionStore, onChange: @escaping () -> Void) {
        let codex = "demo-codex"
        let claude = "demo-claude"

        func update(
            _ agent: AgentKind,
            _ id: String,
            _ state: SessionState,
            _ title: String,
            _ detail: String?,
            remove: Bool = false
        ) -> SessionUpdate {
            SessionUpdate(
                agent: agent,
                sessionID: id,
                state: state,
                title: title,
                detail: detail,
                cwd: NotchPaths.home.path,
                source: .ipc,
                timestamp: Date(),
                remove: remove
            )
        }

        let script: [Step] = [
            Step(delay: 0.0, updates: [update(.codex, codex, .thinking, "notch", "Thinking")]),
            Step(delay: 1.8, updates: [update(.codex, codex, .working, "notch", "Run swift build")]),
            Step(delay: 3.6, updates: [
                update(.codex, codex, .working, "notch", "Editing NotchPanel.swift"),
                update(.claude, claude, .thinking, "my-api", "Thinking"),
            ]),
            Step(delay: 5.4, updates: [update(.claude, claude, .working, "my-api", "Bash: npm test")]),
            Step(delay: 7.2, updates: [{
                var request = update(.claude, claude, .waiting, "my-api", "Needs permission to write")
                request.permissionRequestID = "demo-permission"
                return request
            }()]),
            Step(delay: 9.5, updates: [update(.claude, claude, .working, "my-api", "Edit: server.ts")]),
            Step(delay: 11.0, updates: [update(.codex, codex, .done, "notch", nil)]),
            Step(delay: 13.0, updates: [update(.claude, claude, .error, "my-api", "Command failed: exit 1")]),
            Step(delay: 18.0, updates: [
                update(.codex, codex, .idle, "notch", nil, remove: true),
                update(.claude, claude, .idle, "my-api", nil, remove: true),
            ]),
        ]

        for step in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
                // Timestamps must be stamped at delivery, not when scripted,
                // or the store's stickiness window sees them all as simultaneous.
                let stamped = step.updates.map { original -> SessionUpdate in
                    var copy = original
                    copy.timestamp = Date()
                    return copy
                }
                if store.apply(stamped) { onChange() }
            }
        }
    }
}
