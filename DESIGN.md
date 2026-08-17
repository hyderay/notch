# Notch — Agent Status in the MacBook Notch

A background macOS app that shows what your AI coding agents (Codex CLI, Claude Code) are doing right now, rendered into the MacBook notch.

---

## 1. Goals

| Goal | Detail |
| --- | --- |
| Live status | Show when an agent starts thinking, runs a tool, finishes, errors, or needs your input |
| Zero-config | Works with no hooks installed, by reading the transcript files agents already write |
| High fidelity when opted in | With hooks installed, surface tool names, precise turn boundaries, and prompts awaiting approval |
| Multi-session | Aggregate several concurrent agents; expand to see the full list |
| Hardware-native | Render only into a MacBook display with a physical camera notch |
| Lightweight | No Dock icon, near-zero CPU when idle |

### Non-goals
- Not a control panel for agents (never sends commands or edits agent configs beyond opt-in hook installation)
- No cloud sync, no telemetry
- No Intel-specific work (arm64 first, but the code is architecture-neutral)

---

## 2. Environment and constraints

Measured on this machine:

```
macOS 27.0 (26A5406e)   hw.model = Mac15,6  (MacBook Pro 14", has a notch)
Swift 6.4               Command Line Tools only — no full Xcode
codex-cli 0.147.0       ~/.local/bin/codex
claude                  not installed (must tolerate present/absent)
Active display          external AOC Q24G51F only, safeAreaInsets.top == 0
```

Consequences:

1. **No Xcode** means no `xcodebuild` and no `.xcodeproj`. Build with **SwiftPM, then assemble the `.app` bundle from a script** (hand-written `Info.plist`, ad-hoc `codesign --sign -`).
2. **The notched display must be attached for visual verification.** With only an external display active, the app continues tracking sessions but does not draw an overlay.
3. **No provisioning profile** means ad-hoc signing only, so no capabilities that require entitlements (no App Sandbox, no App Groups).

Two further constraints surfaced only once building started, and each one shaped the code:

4. **`@State` cannot be used.** In the macOS 27 SDK, `State` is a macro (`SwiftUIMacros.StateMacro`), and Command Line Tools ships no SwiftUI macro plugin — only `libObservationMacros` and `libSwiftMacros`. `@ObservedObject`, `@StateObject`, `@Environment`, and `@Binding` are still plain property wrappers and work fine. So every piece of view state, including the one-second clock and the hovered row, lives in `NotchViewModel`.
5. **Screen recording is not permitted** for the shell, so visual verification is impossible. `notchctl inspect` exists to report the overlay's geometry, presentation, window frame, and hover state numerically instead.

---

## 3. How status is obtained

This is the core design problem. Three sources are fused, ranked by fidelity; when the same session is reported by several sources, the higher-priority one wins.

### 3.1 Source A — IPC (highest fidelity, requires hooks)

The app hosts a Unix domain socket server:

```
~/.notch/notch.sock       newline-delimited JSON, client -> server
```

A companion CLI, `notchctl`, writes to it. Agent hooks invoke `notchctl`.

**Claude Code** — installed into `~/.claude/settings.json`:

| Hook | Mapped state |
| --- | --- |
| `UserPromptSubmit` | `thinking` |
| `PreToolUse` | `working`, `detail = <tool name>` |
| `PostToolUse` | `thinking` |
| `Notification` | `waiting` (agent is asking for approval) |
| `Stop` | `done` |
| `SessionEnd` | remove the session |

**Codex CLI** — its `notify` config only fires at turn end, which is too coarse, so Codex relies mainly on Source B. `notify` is optionally used to supply one precise `done` event.

> This machine already has `notify` pointed at `SkyComputerUseClient`. The installer must **detect an existing value and refuse to overwrite it**, printing manual merge instructions instead of clobbering the user's setup.

**Event schema** (`notchctl` -> socket; also the contract between hooks):

```jsonc
{
  "v": 1,
  "agent": "codex" | "claude" | "<custom>",
  "session": "<stable session id>",
  "state": "idle|thinking|working|waiting|done|error",
  "title": "project or task label",   // optional
  "detail": "Bash: npm test",         // optional, current action
  "cwd": "/path/to/project",          // optional
  "ts": 1765000000.0                  // optional, defaults to receive time
}
```

### 3.2 Source B — Codex rollout files (zero-config)

Codex streams the whole session to:

```
~/.codex/sessions/YYYY/MM/DD/rollout-<ISO timestamp>-<uuid>.jsonl
```

One JSON object per line. The events that matter, confirmed against a real transcript:

```jsonc
{"type":"session_meta","payload":{"session_id":"...","cwd":"/Users/x/proj",...}}
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"event_msg","payload":{"type":"item_completed","item":{...}}}
{"type":"event_msg","payload":{"type":"token_count","info":{...}}}
{"type":"event_msg","payload":{"type":"task_complete"}}
```

State machine: `task_started` implies working, `task_complete` implies done, and `item_completed` refreshes `detail` plus the activity timestamp. If Codex is killed before writing a terminal event, Notch removes the unfinished session after two checks confirm that no Codex process still holds its rollout file open.

Watching the whole `~/.codex/sessions` tree with a polling scan is expensive, so instead:

- FSEvents wakes the source only when the Codex transcript tree changes; candidate discovery scans only today's and yesterday's date directories (safe across midnight).
- **Tail incrementally**: remember the byte offset already consumed and parse only the new bytes, line by line.
- While a transcript reports busy work, a one-second `lsof` probe verifies that Codex still owns the file; it stops as soon as no busy Codex session remains.
- Drop a file from the active set after 15 minutes of silence; fade a session out of the UI 8 seconds after it reports `done`.

Even with a 280 MB `logs_2.sqlite` sitting in the same directory, this only ever touches a handful of small JSONL files.

### 3.3 Source C — Claude Code transcripts (zero-config fallback)

```
~/.claude/projects/<path-slug>/<session-uuid>.jsonl
```

There are no explicit turn boundaries, so the state machine is heuristic:

- Last entry is `type:"user"` without `tool_result` → the user just asked something → `thinking`
- Last entry is `type:"assistant"` containing `tool_use` → `working`
- Last entry is `type:"user"` containing `tool_result` → `working`
- Last entry is `type:"assistant"` with plain text only → `done`
- No writes for longer than `idleTimeout` (90s) → forced to `idle`

Same incremental tailing. Once hooks are installed, Source A overrides this.

### 3.4 Fusion rules (`SessionStore`)

- Key is `(agent, sessionID)`.
- Each session records its `source` priority: `ipc(2) > file(1)`.
- A lower-priority source may **not** overwrite a session that a higher-priority source touched within the last 60 seconds.
- Global state is the most urgent state across live sessions: `error > waiting > working > thinking > done > idle`.
- `done` sessions linger for `doneLingerSeconds` (8s) before eviction; `error` lingers 30s.

---

## 4. Interface design

### 4.1 Window layer

`NotchPanel: NSPanel`

| Property | Value | Reason |
| --- | --- | --- |
| `styleMask` | `.borderless, .nonactivatingPanel` | never steals focus |
| `level` | above `.statusBar` | must paint over the menu bar strip |
| `collectionBehavior` | `.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle` | survives Space switches and can appear in full screen when that preference is disabled |
| `isOpaque` | `false`, clear background | rounded corners and transparency |
| `hasShadow` | `false` | a shadow would break the seam against a real notch |
| `isMovable` | `false` | |

Sizing strategy: the window is created at the **maximum expanded size and never resized**; the SwiftUI content decides how much of it to paint. This avoids the flicker and dropped frames that come from repeatedly calling `setFrame`. Non-content regions disable hit testing so the mouse passes through.

### 4.2 Notch geometry

```
targetScreen = the NSScreen with safeAreaInsets.top > 0

Real notch:
  notchHeight = safeAreaInsets.top                     (~32pt on M3 Pro 14")
  notchWidth  = frame.width - auxLeft.width - auxRight.width
                fall back to screenW * 0.1565 clamped to 180...230 when
                auxiliaryTopLeftArea is nil
Origin:
  x = screen.frame.midX - notchWidth / 2
  y = screen.frame.maxY - notchHeight
```

`NSApplication.didChangeScreenParametersNotification` triggers a full recompute and repositions the window.

### 4.3 Visual states

```
Idle
    fully hidden (window alpha 0, not clickable)

Compact (at least one agent running)
            /----------------------\
    (o)    |        [notch]         |   1  2:07
     ^ left ear                          ^ right ear
     agent glyph + spinning ring         session count + elapsed

Expanded (hover, or auto-expand on a state change that needs attention)
    /--------------------------------------------\
   |  [notch]                                     |
   |  o codex   notch          working  2:07      |
   |    ^ Bash: swift build                       |
   |  * claude  my-api         waiting  0:12      |
   |    ^ needs permission                        |
    \--------------------------------------------/
```

State palette:

| State | Color | Motion |
| --- | --- | --- |
| thinking | violet `#7C6CFF` | low-rate sweeping ring |
| working | teal `#2ED3A6` | low-rate sweeping ring |
| waiting | amber `#FFB020` | low-rate pulse |
| error | red `#FF4D4F` | solid |
| done | green `#34C759` | checkmark, then fade out |

**Color appears only in the spinner.** An earlier revision also drew a tinted, travelling progress bar along the bottom edge of the overlay. In practice it read as a flickering colored line against the notch and drew the eye away from the content, so it was removed, and the overlay's outline is a neutral white hairline rather than a state tint. The spinner alone carries the state color.

In virtual-notch mode the app also paints the black rounded body itself; with a real notch the hardware cutout *is* the body, so only the ears are drawn.

### 4.4 Animation

- Everything is drawn with SwiftUI `Shape`/`Canvas`; no image assets.
- The status ring advances in discrete low-rate steps. A persistent Core Animation above the menu bar forces WindowServer to composite unrelated status items at the display refresh rate, which is especially costly on 120 Hz panels.
- Expand/collapse uses `.spring(response: 0.34, dampingFraction: 0.78)`.

### 4.5 Interaction

- Hovering either ear or the notch body expands it (120ms delay to avoid accidental triggers).
- Moving away collapses it (400ms delay).

- Expanding and collapsing under the pointer fire a Force Touch haptic tap (`.alignment` out, `.generic` back), rate-limited to one every 250ms. Auto-expansion deliberately does **not** tap: the user did not ask for it and a tap under a resting hand is startling. `NSHapticFeedbackManager` no-ops on hardware without a Force Touch trackpad and honors the system haptics setting, so no capability check is needed.
- Clicking a row reveals that session's `cwd` in Finder.
- Transitioning to `waiting` or `error` auto-expands for 4 seconds (can be disabled).
- An `NSStatusItem` provides settings, hook installation, and quit. The persistent **Hide overlay in full screen** preference is enabled by default; active-Space and frontmost-application changes update overlay visibility without discarding session state. Once the destination is confirmed as full screen, the panel holds for 280ms and then fades over 340ms with an ease-in-out curve; the deliberate cadence reads as a transition instead of a late window-server flash. Detection checks `AXFullScreen` across the frontmost application's windows on the notched display because Chromium apps can update the focused window before the actual full-screen window. Delayed checks span the Space animation, with Quartz coverage retained as a fallback when the attribute is unavailable.

Hover is detected from global and local mouse-movement events, not with an `NSTrackingArea`. The obvious approach fails here: expanding resizes the panel, which makes AppKit call `updateTrackingAreas`, tear the area down, and emit a spurious exit/enter pair, so the overlay oscillates between compact and expanded several times a second. Evaluating the current pointer against a hysteretic hit region produces one enter and one exit without an idle polling timer. A separate precise-scroll monitor recognizes a two-finger vertical sweep in the island's top-center region. Physical motion toward the notch hides the entire island, while motion away restores it; normalizing `isDirectionInvertedFromDevice` makes this independent of the user's natural-scrolling preference. The monitor stays active after the panel is ordered out, and the menu preference can disable it.

Gesture restoration prelays out the ordered-out panel at its final compact frame, forces one offscreen render, and then fades it in over 240ms. Hidden-to-compact does not use the SwiftUI size spring; keeping that spring only for compact-to-expanded avoids competing with AppKit's parked 1pt window frame on the first visible frame.

The compact spinner and elapsed-time label observe window ordering as well as view attachment. An ordered-out panel retains its SwiftUI tree and session state, but its UI timers stop until the window is visible again; checking only `view.window` is insufficient because AppKit keeps ordered-out views attached to their window.

---

## 5. Module layout

```
notch/
├── Package.swift
├── DESIGN.md
├── README.md
├── Makefile
├── scripts/
│   └── build-app.sh              # SPM product -> Notch.app + ad-hoc signature
└── Sources/
    ├── NotchCore/                # pure logic, unit-testable, no AppKit
    │   ├── AgentSession.swift        # AgentKind / SessionState / AgentSession
    │   ├── StatusEvent.swift         # IPC event schema and coding
    │   ├── SessionStore.swift        # fusion, expiry, aggregation
    │   ├── LineTailer.swift          # offset-tracking incremental line reader
    │   ├── CodexRolloutParser.swift  # rollout jsonl -> events
    │   ├── ClaudeTranscriptParser.swift
    │   ├── SocketServer.swift        # Unix domain socket server
    │   ├── SocketClient.swift        # client used by notchctl
    │   └── Paths.swift               # path constants
    ├── NotchApp/                 # UI, depends on NotchCore
    │   ├── main.swift                # AppKit lifecycle entry point
    │   ├── AppDelegate.swift
    │   ├── NotchGeometry.swift
    │   ├── NotchPanel.swift
    │   ├── NotchViewModel.swift
    │   ├── Views/…
    │   ├── Sources/…                 # IPCSource, CodexFileSource, ClaudeFileSource
    │   ├── Settings.swift
    │   └── HookInstaller.swift
    └── notchctl/
        └── main.swift
```

**Why AppKit `main.swift` instead of a SwiftUI `@main App`**: the app needs `.accessory` activation policy, a fully custom `NSPanel`, and predictable startup behavior without Xcode. SwiftUI is used only as the content layer inside an `NSHostingView`.

---

## 6. Build and install

```bash
make build     # swift build -c release
make app       # assemble .build/Notch.app (Info.plist + ad-hoc codesign)
make install   # copy to /Applications, symlink notchctl into ~/.local/bin
make run       # run in the foreground with logs on stderr
```

`Info.plist` essentials: `LSUIElement = true` (no Dock icon), `LSMinimumSystemVersion = 14.0`, `NSPrincipalClass = NSApplication`, `CFBundleIdentifier = com.wanquanlin.notch`.

---

## 7. Debugging affordances

Without a notched display attached and without a live agent, verification needs help:

1. `notchctl demo` — synthesizes a session sequence (thinking → working → waiting → done → error) to exercise the full UI.
2. `notchctl status` — prints every session the app currently holds, via a socket request/response.
3. `notchctl inspect` — prints the overlay's presentation, geometry, window frame, hover state, and visibility.
4. `notchctl snapshot [path]` — renders the SwiftUI tree to a PNG with `ImageRenderer` over a flat grey backdrop. `screencapture` needs Screen Recording permission, which a terminal-hosted tool usually lacks; rendering from inside the process needs no permission at all, and the backdrop makes any content escaping the black silhouette immediately visible.
5. `notchctl doctor` — socket liveness, which agents are installed, and whether hooks are in place.
6. `NOTCH_DEBUG=1` plus `NOTCH_LOG_FILE` — log every source event. A bundled app has no terminal, and `open` does not forward the shell environment, so these are set with `launchctl setenv`.

Pointing `CODEX_HOME` and `CLAUDE_CONFIG_DIR` at temporary directories makes it possible to drive the file sources with synthetic transcripts and to exercise the hook installer without touching real agent configuration.

---

## 8. Performance

An app that runs all day has to be invisible in Activity Monitor. Measured on the machine described in §2 (M3 Pro, 120Hz internal display); CPU is a percentage of one core.

| State | CPU | RSS |
| --- | --- | --- |
| Idle, overlay hidden | 0.0–0.2% | 56 MB |
| Compact overlay, spinner running | 0.6–0.8% | 61 MB |
| Expanded panel, hovering | 0.8–1.0% | 62 MB |

Three fixes got it there, each found by measuring rather than by reading the code.

**Path constants rebuilt the process environment.** `NotchPaths` used computed properties that read `ProcessInfo.processInfo.environment`, which materializes a dictionary of the whole environment on every access. The watchers touch those paths several times a second, and that alone was most of an idle 0.8%. They are now `static let`, resolved once, since the environment cannot change mid-process. Idle fell to ~0%.

**Polling ran at a fixed rate.** Transcript discovery now runs from FSEvents and per-file vnode notifications, so an idle machine has no transcript scan timer. The only lifecycle probe is armed while a Codex transcript reports busy work, and it stops immediately when that work finishes or the process disappears.

**The spinner cost 10% of a core.** This was the large one. A SwiftUI rotation re-rasterizes the stroked arc on every frame, and this display runs at 120Hz. A 60Hz `TimelineView`, a once-per-second target with a linear animation, and both of those wrapped in `.drawingGroup()` all measured 9–13%, against 0.6% for the same overlay sitting still — so it was the animation, not window compositing. The moving arc is now a `CAShapeLayer` driven by a `CABasicAnimation`, handed to the render server once (`Views/SpinnerArc.swift`); the static track, centre dot, and glyph stay in SwiftUI. Roughly a 17x reduction, and the reason the one continuously animating element in the app is also the only one written in AppKit.

Memory is flat under load. Across 8,000 rapid session events the resident set reached a working-set plateau near 75 MB and then moved 160 KB over the final 6,000. `leaks` reports a fixed 20 KB inside `NSXPCConnection`/AppIntents system machinery, byte-identical before and after a further 1,600 events plus repeated hover cycles, with nothing attributed to this code.

Timers only run when they have something to do: the one-second clock and the 12.5Hz hover poll both start when the overlay becomes visible and stop when it hides.

---

## 9. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Codex rollout format changes between versions | Parsers are fully lenient: missing fields degrade rather than crash, unrecognized lines are skipped |
| Clobbering an existing codex `notify` or claude hook | The installer writes idempotently and additively; on conflict it prints manual merge instructions and exits |
| Transcript monitoring drains battery | FSEvents and vnode notifications sleep at rest; Codex process probes run only while a session reports busy work |
| Socket permissions | `~/.notch` is `0700` and the socket `0600`; local connections only; stale sockets are cleaned at startup |
| Geometry breaks when displays change or the lid closes | Full recompute on `didChangeScreenParameters`; hide unless the notched display is active |
| Two instances running at once | At startup, connecting to the existing socket proves another instance is alive, and the new one exits |
| Gatekeeper blocks the ad-hoc signature | README documents right-click-open or `xattr -dr com.apple.quarantine` |

---

## 10. Acceptance criteria

- [x] `swift build -c release` passes
- [x] `make app && open .build/Notch.app` launches with no Dock icon
- [x] `notchctl demo` drives the full state-transition sequence
- [x] A synthetic Codex rollout written into `~/.codex/sessions` moves the overlay through working → done with no configuration
- [x] The overlay stays hidden when no notched display is active
- [x] Idle CPU below 1% (measured 0.0–0.2%)
- [x] Resident memory flat across 8,000 session events
- [x] The socket file is removed on quit, and a stale one left by a crash is reclaimed on the next launch
