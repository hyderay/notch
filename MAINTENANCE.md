# Notch maintenance

Is runtime cost reasonable? **Yes.** Idle CPU should be 0%. Real memory sits around 20–25 MB. That is the SwiftUI + AppKit menu-bar floor, not a leak.

Architecture: [DESIGN.md](DESIGN.md). Day-to-day commands: [README.md](README.md).

---

## 1. Budgets

Release, ad-hoc signed, no `NOTCH_DEBUG`, measured on a 14" MacBook Pro (M3-class):

| State | CPU (one core) | Physical (`footprint`) | RSS (do not quote) |
| --- | --- | --- | --- |
| Just launched, no sessions | **0.00%** | ~19 MB | ~60 MB |
| Idle for a few minutes | **0.00%** | plateaus ~24 MB | plateaus ~75 MB |
| Session visible, compact + spinner | ~0.6–1.6% | +1–2 MB | barely moves |
| Panel expanded | brief ~2–3% during the animation, then the row above | same | same |
| Session gone, overlay hidden | **back to 0.00%** | back to the idle plateau, ±2 MB | back to the idle plateau |

Pass / fail:

- **Healthy:** idle 0% CPU; physical memory stable under 30 MB; creating and removing a session returns memory to the plateau.
- **Unhealthy:** idle CPU stuck above 1%; RSS/footprint climbing without bound while idle; `leaks` stacks that land in `Notch` / `NotchCore`.

RSS is inflated by the dyld shared cache. Activity Monitor’s Memory column tracks `Physical footprint` more closely. A multi-hundred-GB VSZ is normal arm64 ASLR — ignore it.

`leaks` on an ad-hoc GUI process reports ~417 cycles (~20 KB) in NSXPC / AppIntents. Those are system false positives. Fail only when a stack frame belongs to this app.

---

## 2. Required on every acceptance

```bash
# The app must already be running
make check-resources
```

The script:

1. Samples idle CPU / RSS for 6 seconds
2. Creates a session with `notchctl`, then removes it
3. Samples idle again
4. Runs `leaks`, ignoring system XPC, failing only on Notch code

Hard limits (override with env vars):

| Variable | Default | Meaning |
| --- | --- | --- |
| `IDLE_CPU_MAX` | `1.0` | Max idle average CPU % |
| `IDLE_RSS_GROWTH_KB` | `4096` | Allowed RSS span in one idle sample |
| `EXERCISE_RSS_GROWTH_KB` | `16384` | Allowed RSS growth vs baseline after one session cycle |

Manual check:

```bash
PID=$(pgrep -x Notch)
ps -o pid,pcpu,rss,comm -p $PID
footprint -p $PID
leaks $PID | rg "Physical footprint|leaks for|MacOS/Notch|NotchCore"
```

After changing the overlay, file watchers, timers, or SwiftUI clocks: do not ship on behavior alone. Run this section.

---

## 3. Why idle can be 0%

These paths must sleep when nothing is showing:

| Mechanism | Idle behavior |
| --- | --- |
| Transcript watch | FSEvents; vnode on an ancestor if the directory is missing — **no poll** |
| Codex exit detection | One-shot process probe, re-armed only while a Codex session is busy |
| Expiry | One-shot timer, armed only while sessions exist |
| Hover | Mouse monitors uninstalled while hidden; `contains` skipped when the cursor is far from the strip |
| Elapsed text | Compact AppKit label at 1 Hz without root invalidation; expanded `TimelineView` at 1 Hz |
| Status ring | Discrete 4 Hz/2 Hz layer updates; no display-rate Core Animation |
| Debug log | Off unless `NOTCH_DEBUG=1` |

Do not reintroduce:

- A repeating source/file-scanning timer that runs while idle
- `@Published now = Date()` ticking the whole overlay every second
- 12.5 Hz mouse polling
- Infinite Core Animation in the status-bar-level panel
- Recursive FSEvents on `$HOME`

---

## 4. Daily commands

```bash
make test              # 76 unit tests; Command Line Tools is enough
make install           # Release → /Applications/Notch.app + ~/.local/bin/notchctl
make check-resources
make uninstall

open -a Notch
notchctl ping
notchctl status
notchctl inspect
notchctl working --agent codex --session t --title notch --detail "swift build"
notchctl remove --agent codex --session t
```

Icon: after editing `scripts/render-icon.swift`:

```bash
swift scripts/render-icon.swift Resources
rm -rf Resources/AppIcon.iconset
make install
```

LaunchServices caches the environment `open -a` passes. To test `CODEX_HOME` overrides, launch `Notch.app/Contents/MacOS/Notch` directly.

---

## 5. Footguns

1. **`@State` is unavailable.** Command Line Tools ships no SwiftUI macro plugin. Put view state on `NotchViewModel`.
2. **Do not hover with `NSTrackingArea`.** Resizing the panel emits spurious enter/exit pairs. Use global/local `mouseMoved` plus a hysteretic hit rect (tight enter, loose leave).
3. **`leaks` needs a debuggable process.** Release ad-hoc builds print `not debuggable` and the report is incomplete. Trust footprint plateau + stacks in our binary.
4. **Idle memory rises once, then stops.** The first overlay presentation loads fonts / CoreUI and footprint walks ~19 MB → ~24 MB. That is warmup, not a leak. It must then stay flat.
5. **Test macros.** `make test` already wires `libTestingMacros.dylib` and copies `Testing.framework` into the `.xctest` bundle. Do not copy that framework into `PackageFrameworks`.

---

## 6. Where to look when cost regresses

```
NotchApp          overlay, FSEvents, hover, SwiftUI
NotchCore         session merge, parsers, socket, paths
notchctl          hooks / debug CLI
```

The files that most easily wake the idle process: `StatusSources.swift`, `DirectoryWatcher.swift`, `NotchViewModel.setHovering`, `HoverMonitor`, and the `TimelineView` in `ElapsedLabel` / `ExpandedView`.
