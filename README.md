<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Notch app icon">
</p>

# Notch

[![CI](https://github.com/hyderay/notch/actions/workflows/ci.yml/badge.svg)](https://github.com/hyderay/notch/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/hyderay/notch?display_name=tag)](https://github.com/hyderay/notch/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://github.com/hyderay/notch)

Shows what your AI coding agents are doing, in the MacBook notch.

<p align="center">
  <img src="Resources/NotchExpanded.png" width="760" alt="Notch showing Codex CLI and Claude Code sessions">
</p>

When Codex CLI or Claude Code is working, the notch quietly grows a little wider and shows a spinner plus a timer. Hover it and it drops down into a panel listing every live session, what each one is doing right now, and how long it has been at it. When nothing is running, it disappears completely.

```
        /--------------------\
  (o)  |       [notch]        |  2  2:07          compact
                                                  
    /----------------------------------\
   |             [notch]                |
   |  o codex   notch     working  2:07 |          expanded (on hover)
   |    Run swift build                 |
   |  * claude  my-api    waiting  0:12 |
   |    Needs permission to write       |
    \----------------------------------/
```

Expanding and collapsing under the pointer give a Force Touch haptic tap, so the notch feels like a physical control rather than a hover tooltip. Auto-expansion (when an agent needs your attention) stays silent on purpose.

Push two fingers toward the island to hide it completely, even from compact mode. Pull two fingers away from the same top-center area to bring it back. The gesture can be disabled from the menu bar.

---

## Highlights

- Tracks Codex CLI and Claude Code automatically from their local transcripts
- Shows concurrent sessions, current activity, elapsed time, and approval prompts
- Integrates directly with the hardware notch on supported MacBooks
- Provides optional agent hooks for more precise status updates
- Exposes a local `notchctl` interface for scripts and other agents
- Stays local: no accounts, analytics, or network requests

---

## Requirements

- macOS 14 or later (built and tested on macOS 27)
- A MacBook display with a hardware camera notch
- Xcode Command Line Tools — **a full Xcode install is not required**
- Optional: [Codex CLI](https://github.com/openai/codex) and/or [Claude Code](https://claude.com/claude-code)

## Install

### Homebrew

```bash
brew install --cask --no-quarantine hyderay/tap/notch
```

Release builds are ad-hoc signed, so the `--no-quarantine` flag is required until notarized builds are available.

### Download a release

1. Download `Notch-v*-macOS.zip` from the [latest release](https://github.com/hyderay/notch/releases/latest).
2. Unzip it and move `Notch.app` to `/Applications`.
3. Launch Notch from Finder or run `open -a Notch`.

Release builds are ad-hoc signed rather than Apple-notarized. If Gatekeeper blocks the first launch, right-click the app and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Notch.app
```

### Build from source

```bash
git clone https://github.com/hyderay/notch.git
cd notch
make install
open -a Notch
```

`make install` puts `Notch.app` in `/Applications` and symlinks `notchctl` into `~/.local/bin`.

To have it start at login, add `/Applications/Notch.app` under System Settings → General → Login Items.

## How it knows what your agents are doing

Two mechanisms, and you get the first one for free.

### Zero configuration (default)

Both agents already stream their sessions to disk. Notch tails those transcripts and reads the turn boundaries out of them:

| Agent | Watched | Signal |
| --- | --- | --- |
| Codex CLI | `~/.codex/sessions/**/rollout-*.jsonl` | explicit `task_started` / `task_complete` events |
| Claude Code | `~/.claude/projects/**/*.jsonl` | inferred from the shape of the last entry |

Only files touched in the last 15 minutes are considered, and each is read incrementally from a saved byte offset. FSEvents keeps transcript discovery asleep when nothing changes; while Codex reports active work, a lightweight process check also clears sessions whose terminal was closed or killed before a completion event could be written.

### Hooks (optional, more precise)

```bash
notchctl install-hooks
```

This adds hooks to `~/.claude/settings.json` and a `notify` entry to `~/.codex/config.toml`. With them in place you get exact turn boundaries, tool names, and a distinct "waiting for your approval" state instead of an inference.

The installer is additive and idempotent. If you already have a `notify` program configured for Codex it will refuse to overwrite it and print instructions instead. Every file it edits is backed up alongside the original with a `.notch-backup` suffix. Undo everything with `notchctl uninstall-hooks`.

## Using notchctl

Any tool can push status, not just the two supported agents:

```bash
notchctl working --agent codex --session build-42 --title my-app --detail "cargo test"
notchctl waiting --agent codex --session build-42 --detail "confirm deploy?"
notchctl done    --agent codex --session build-42
notchctl remove  --agent codex --session build-42
```

Other commands:

| Command | Purpose |
| --- | --- |
| `notchctl status` | What the overlay is showing right now |
| `notchctl inspect` | Overlay geometry and layout, for debugging placement |
| `notchctl snapshot [path]` | Render the overlay to a PNG |
| `notchctl doctor` | Socket, detected agents, and hook installation state |
| `notchctl demo` | Play a scripted sequence through every visual state |
| `notchctl ping` | Is the app running? |

States are `idle`, `thinking`, `working`, `waiting`, `done`, and `error`. When several sessions are live, the notch shows the most urgent one: `error > waiting > working > thinking > done > idle`.

## Menu bar

A menu bar item offers hook installation, the auto-expand, swipe, and haptic preferences, the demo, and quit. **Hide overlay in full screen** is enabled by default and can be toggled from this menu; the preference persists across restarts.

## Environment variables

| Variable | Effect |
| --- | --- |
| `NOTCH_SOCKET` | Override the IPC socket path (default `~/.notch/notch.sock`) |
| `NOTCH_DEBUG=1` | Log every source event |
| `NOTCH_LOG_FILE` | Send logs to a file instead of stderr |
| `CODEX_HOME`, `CLAUDE_CONFIG_DIR` | Point at non-default agent config directories |

A bundled app launched from Finder does not inherit your shell environment. Use `launchctl setenv` for those:

```bash
launchctl setenv NOTCH_DEBUG 1
launchctl setenv NOTCH_LOG_FILE /tmp/notch.log
open -a Notch
```

## Development

```bash
make build     # debug build
make test      # 82 tests via swift-testing
make run       # foreground, with logging on stderr
make app       # assemble .build/Notch.app
make install   # install to /Applications
make uninstall # remove everything, including the socket
```

Project layout:

| Path | Contents |
| --- | --- |
| `Sources/NotchApp` | AppKit/SwiftUI overlay, menu bar UI, and status sources |
| `Sources/NotchCore` | Session model, transcript parsers, hooks, and local IPC |
| `Sources/notchctl` | Command-line client and hook entry points |
| `Tests/NotchCoreTests` | Parser, store, socket, and utility tests |
| `scripts` | App bundle assembly, icon rendering, and resource checks |

There is no `.xcodeproj`. The project builds with SwiftPM and the app bundle is assembled by `scripts/build-app.sh`, which writes `Info.plist` and applies an ad-hoc signature. This is deliberate: it keeps the whole thing buildable with only Command Line Tools installed.

Two consequences of that constraint show up in the source:

- **`@State` is unavailable.** In the macOS 27 SDK it is a macro, and Command Line Tools does not ship the SwiftUI macro plugin. All view state lives in `NotchViewModel` instead.
- **`XCTest` is unavailable**, so tests use swift-testing. `scripts/prepare-testing.sh` stages `Testing.framework` into the test bundle because dyld cannot otherwise find it; `make test` runs it for you.

See [DESIGN.md](DESIGN.md) for the architecture, the transcript formats, and the reasoning behind the trade-offs.

## Resource use

Measured on an M3 Pro, Release build, no debug logging. Prefer Activity Monitor "Memory" / `footprint` over RSS.

| State | CPU (one core) | Physical memory |
| --- | --- | --- |
| Idle, overlay hidden | 0.00% | ~19–24 MB |
| Agent working, compact | ~0.6–1.6% | +1–2 MB |
| After the session ends | back to 0.00% | back to the idle plateau |

RSS looks higher (~60–75 MB) because it counts the dyld shared cache; that is not leak. `leaks` on an ad-hoc GUI app also reports ~20 KB of system NSXPC cycles — ignore those unless a stack lands in `Notch` / `NotchCore`.

Watchers are event-driven (FSEvents), not polling. The spinner is a Core Animation layer. Run `make check-resources` to verify the CPU and memory budgets after runtime changes.

## Privacy

Everything is local. Notch reads transcript files that already exist on your disk, keeps session state in memory only, and makes no network connections. The IPC socket lives in a `0700` directory with `0600` permissions and accepts only local connections.

## Contributing

Bug reports and focused pull requests are welcome. Before opening a pull request, run `make test` and `make app` on macOS 14 or later. For architecture and performance constraints, read [DESIGN.md](DESIGN.md).
