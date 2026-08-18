<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Notch app icon">
</p>

<p align="center">
  English | <a href="README.zh-CN.md">简体中文</a>
</p>

# Notch

[![CI](https://github.com/hyderay/notch/actions/workflows/ci.yml/badge.svg)](https://github.com/hyderay/notch/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/hyderay/notch?display_name=tag)](https://github.com/hyderay/notch/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://github.com/hyderay/notch)

Shows what your AI coding agents are doing, in the MacBook notch.

<p align="center">
  <img src="Resources/NotchExpanded.png" width="760" alt="Notch showing Codex CLI and Claude Code sessions">
</p>

When Codex CLI or Claude Code is working, the notch has three levels: hidden (0), compact status (1), and the full session panel (2). Swipe two fingers toward the notch to step down `2 -> 1 -> 0`, or away from it to step up `0 -> 1 -> 2`. Click toggles levels 1 and 2, and moving the pointer outside level 2 returns it to level 1. When nothing is running, gestures do nothing.

```
        /--------------------\
  (o)  |       [notch]        |  2  2:07          compact
                                                  
    /----------------------------------\
   |             [notch]                |
   |  o codex   notch     working  2:07 |          expanded
   |    Run swift build                 |
   |  * claude  my-api    waiting  0:12 |
   |    Needs permission to write       |
    \----------------------------------/
```

Every successful two-finger level change gives a Force Touch haptic tap, in both directions. Boundary gestures, clicks, pointer-exit collapse, and auto-expansion stay silent. The gesture can be disabled from the menu bar.

---

## Highlights

- Tracks Codex CLI and Claude Code automatically from their local transcripts
- Shows concurrent sessions, current activity, elapsed time, and approval prompts
- Integrates directly with the hardware notch on supported MacBooks
- Provides optional agent hooks for more precise status updates
- Exposes a local `notchctl` interface for scripts and other agents
- Keeps agent data local: no accounts or analytics; update checks only request public GitHub release metadata

---

## Requirements

- macOS 14 or later (built and tested on macOS 27)
- A MacBook display with a hardware camera notch
- Xcode Command Line Tools — **a full Xcode install is not required**
- Optional: [Codex CLI](https://github.com/openai/codex) and/or [Claude Code](https://claude.com/claude-code)

## Install

### Homebrew

```bash
brew install --cask hyderay/tap/notch
xattr -dr com.apple.quarantine /Applications/Notch.app
```

The second command is currently required because release builds are ad-hoc signed.

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

A menu bar item offers hook installation, update checking, the auto-expand, swipe, and haptic preferences, the demo, and quit. Notch checks GitHub Releases once at launch and only presents automatic checks when a newer version exists; **Check for Updates...** always reports the result. **Hide overlay in full screen** is enabled by default and can be toggled from this menu; the preference persists across restarts.

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
| `scripts` | App bundle assembly, icon rendering, and resource checks |

There is no `.xcodeproj`. The project builds with SwiftPM and the app bundle is assembled by `scripts/build-app.sh`, which writes `Info.plist` and applies an ad-hoc signature. This is deliberate: it keeps the whole thing buildable with only Command Line Tools installed.

One consequence of that constraint shows up in the source:

- **`@State` is unavailable.** In the macOS 27 SDK it is a macro, and Command Line Tools does not ship the SwiftUI macro plugin. All view state lives in `NotchViewModel` instead.

See [DESIGN.md](DESIGN.md) for the architecture, the transcript formats, and the reasoning behind the trade-offs.

## Resource use

Measured on an M3 Pro on August 18, 2026, using the installed Release build with no debug logging. CPU is a percentage of one core.

| State | Average CPU | RSS | RSS span during sample |
| --- | --- | --- | --- |
| Idle, overlay hidden | 0.70% | 55.6 MB | 48 KB |
| Agent working, compact | 0.17% | 61.0 MB | 192 KB |
| After the session ends | 0.00% | 60.9 MB | 144 KB |

The post-exercise physical footprint was 16.0 MB. RSS is higher because it includes shared mappings and is not the same as physical footprint. `leaks` reported a fixed 20,016 bytes in system NSXPC/AppIntents cycles and no stack attributed to `Notch` or `NotchCore`.

Watchers are event-driven (FSEvents), not polling, and the compact status indicator has no display-rate animation. Run `make check-resources` to verify the CPU and memory budgets after runtime changes. The gate requires idle CPU at or below 1%, working CPU at or below 5%, bounded RSS growth, and no leaks attributed to project code.

## Privacy

Agent data stays local. Notch reads transcript files that already exist on your disk and keeps session state in memory only. Update detection makes one metadata request to the public GitHub Releases API at launch or when **Check for Updates...** is selected; it sends no session, path, or usage data. The IPC socket lives in a `0700` directory with `0600` permissions and accepts only local connections.

## Contributing

Bug reports and focused pull requests are welcome. Before opening a pull request, run `make app` on macOS 14 or later. For architecture and performance constraints, read [DESIGN.md](DESIGN.md).
