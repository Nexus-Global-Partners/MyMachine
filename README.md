# MY MACHINE

MY MACHINE is a native, local-first macOS background monitor that connects foreground and background application activity with whole-machine performance, then turns the result into practical, plain-language understanding.

Repository: [Nexus-Global-Partners/MyMachine](https://github.com/Nexus-Global-Partners/MyMachine) · [MIT license](LICENSE) · [Older binary releases](https://github.com/Nexus-Global-Partners/MyMachine/releases)

## Install from source with your own agent

This is the current way to try the latest version on another Mac. Paste this into a coding agent running on that Mac:

> Install the open-source MY MACHINE menu-bar app from https://github.com/Nexus-Global-Partners/MyMachine on my Mac. First check that I have macOS 15 or later, Apple Command Line Tools, and Swift 6. Clone the public repository into a new folder without overwriting my files. Inspect its README and packaging script, then run `swift run DailyMacValidation` and `./scripts/package.sh`. Verify the packaged app's code signature. If `/Applications/MY MACHINE.app` already exists, quit it and make a recoverable backup before replacing only that app bundle; do not delete its data or preferences. Install `outputs/MY MACHINE.app` into Applications and open it. If macOS requires a one-time approval because it is ad-hoc signed and not notarized, tell me the normal Finder or System Settings step; do not disable Gatekeeper. Report the installed version and test results.

You can also run the commands yourself under **Build from source** below. The source build is compiled for the host Mac, including supported Intel and Apple-silicon machines. It is ad-hoc signed, not Apple-notarized; Finder may require Control-click → **Open** once.

The menu-bar item shows physical fan speed and macOS thermal pressure at left when available, CPU/GPU demand in blue at center, and machine health/effort at right. Open it for four selectable instruments beside a large usage-history graph. Live shows current readings; Period summarizes the graph's selected dates. Calm smooths the trend; Precise preserves more interval detail. The range control includes Auto, 1h, 4h, 6h, 12h, 24h, and 48h with one-click arrows. Past-day browsing, graph detail, and diagnosis are in the overflow menu. All telemetry stays on the Mac; diagnosis never sends anything automatically.

Documentation: [maintainer handoff](HANDOFF.md) · [contributing](CONTRIBUTING.md) · [security](SECURITY.md) · [privacy boundary](PRIVACY.md) · [changelog](CHANGELOG.md)

It deliberately avoids surveillance. It never captures what you type, individual keys, pointer coordinates or targets, screen pixels, screenshots, window titles, URLs, workspace or project names, prompts, document or file contents, messages, clipboard data, file paths, command-line arguments, environment variables, network destinations, credentials, or audio. It stores only interval totals for keyboard actions, pointer movement, clicks, and scrolling so it can show hands-on intensity without reconstructing activity. Significant app and process names, their parent/owner relationship, and aggregate resource readings can be retained briefly for interpretation. Collected telemetry stays on the Mac; MY MACHINE does not upload it. An explicit **Diagnose My Machine** click can prepare and copy a minimized 24-hour brief, after which the user decides whether to paste it into an external assistant. It requires no Accessibility, Screen Recording, Input Monitoring, Full Disk Access, Network Extension, administrator, or root permission.

## Build from source

Requirements: macOS 15 or later and the Apple Command Line Tools with Swift 6.

```sh
git clone https://github.com/Nexus-Global-Partners/MyMachine.git
cd MyMachine
swift build
swift run DailyMacValidation
./scripts/package.sh
```

The package script builds an optimized app for the host architecture, constructs a standard `.app` bundle, applies an ad-hoc Hardened Runtime signature, and writes one clean set of versioned artifacts to `outputs/`. Older downloads on the Releases page do not contain the latest source changes.

Move `outputs/MY MACHINE.app` into `/Applications`, then use the same one-time Finder **Open** step described above. See [HANDOFF.md](HANDOFF.md) for isolated development, architecture, known follow-ups, and release checks.

## Architecture

- SwiftUI/AppKit application and native menu-bar presence
- Permission-free core collector for foreground app identity, idle duration, aggregate hands-on activity counts, CPU, load, VM/memory, swap, physical disk bytes, interface network bytes, battery/charging, thermal state, app lifecycle, sleep/wake, and an optional whole-device GPU activity estimate when the current graphics driver exposes a usable value
- Isolated best-effort process extension for significant process CPU, memory footprint, and observed file/disk activity; related helpers and workers are combined under their owning app using local parent relationships, and incomplete coverage never breaks the core
- Actor-confined SQLite database with WAL transactions, owner-only permissions, bounded raw retention, crash-safe commits, integrity checking, and non-destructive corruption recovery. Private recovery copies follow raw-data retention and are removed by **Delete All Data**.
- Deterministic insight engine with duration/evidence gates and no AI or network dependency
- Optional day/twilight/night shading, calculated offline for a manually selected city and date. Settings → Day & night in history performs an explicit Apple city lookup; no location tracking. Solar estimates use [NOAA's approximation](https://gml.noaa.gov/grad/solcalc/solareqns.PDF), not weather observations, and the selected city applies to all history.
- Clicking the menu-bar icon opens one native AppKit popover anchored to the actual status item. Cached history appears immediately, then refreshes silently every 30 seconds while open. Closing it stops presentation refreshes. App reopening and notifications use this same panel; there is no separate dashboard window.
- System, Light, and Dark appearances apply consistently to the monitoring panel and settings.
- The menu-bar icon can be rearranged in Settings: its fan/thermal, CPU/GPU, and health/effort instruments have live explanations, visibility controls, and a restore-original preset. These controls change presentation only, not what the app measures.
- The popover has four selectable CPU/GPU/memory/fan cards and app CPU contributors beside a large graph. A single header pill shows today's observed human use and recorded awake machine time; neither is a focus or productivity score. Secondary controls stay in the overflow menu.
- **Diagnose My Machine** builds a deterministic, privacy-bounded brief from the latest 24 elapsed hours, copies it only after the user clicks, and can open ChatGPT or Claude as a convenience. Copy only is the default. MY MACHINE never reads the clipboard, calls an AI service, inserts the brief into a website, or sends it. Application names can be anonymized in Settings.
- CPU and GPU retain distinct blue signals. Memory is measured physical-memory use, with a pressure indicator separate from fullness. Fan is measured RPM relative to the hardware maximum; the card's hover exposes RPM. Thermal pressure has four categorical steps, never a fabricated percentage. Cards receive a restrained warning outline only for pressure evidence, not simply high processor usage.
- All ranges use the same time-aligned graph, including 48 hours. Precise preserves interval detail; Calm uses longer averages. Missing readings remain gaps; old fan data is never synthesized. A quiet neutral rail distinguishes recorded awake time from recent hands-on use. Presence never proves who caused CPU load.
- The 48-hour timeline uses day-and-clock labels and recorded CPU/GPU history, not daily-summary bars or invented curves from saved averages. Today and week are no longer picker choices. Existing daily summaries remain stored without changing personal history.
- Retained app-family evidence distinguishes observed foreground and background CPU capacity from human presence. Capacity is per-process core time divided by the Mac's logical-core count; worker counts are never converted into CPU estimates. GPU has no per-app attribution. Exact app, memory, swap, thermal, and available performance/efficiency-core readings remain available through inspection and diagnosis rather than crowding the first-glance graph.
- Hover or drag over the graph to inspect a recorded moment. Move away or double-click to clear inspection. Values remain unavailable in gaps. The left-hand Live readings are independent of graph inspection; Period uses the graph's interval.
- App attribution stays contextual rather than becoming separate per-app mini graphs. Presence never proves that the human caused the CPU or GPU demand.
- Progressive disclosure: practical meaning is shown first, while exact readings, attribution limits, and metric provenance stay available under Details & privacy
- Privacy-safe local notifications when a reliable briefing is ready; notification text never contains app names, process names, metrics, or report excerpts
- Daily summaries remain available for retained reports and evidence, independently of the graph's time-scale choices

The diagnosis brief is capped at 32 KiB and contains selected aggregates, coverage and gap context, confirmed sleep, a representative timeline, and top application-family summaries. It excludes raw samples, PIDs, bundle identifiers, worker names, raw input counts, paths, destinations, and stored event prose. Application labels are sanitized and treated as untrusted data. Clipboard content is limited to the current Mac; while MY MACHINE remains running, it is cleared after roughly ten minutes only if it has not been replaced.

Data is stored in `~/Library/Application Support/MY MACHINE/` unless `DAILYMAC_DATA_DIR` is set for an isolated test run. A tiny preferences record for pause, notification, and launch choices is stored by macOS under `~/Library/Preferences/local.mymachine.app.plist` so an immediate quit cannot accidentally undo a privacy choice.

App-family memory is a best-effort footprint and can include pages shared with other processes. Per-process read/write counters describe observed file or disk activity; they do not measure storage consumed, identify files, or estimate SSD wear.

The optional GPU line is an aggregate hardware-activity estimate reported by the current graphics driver. It is not guaranteed to be available, is not per-app attribution, and never reads or derives anything from screen pixels or displayed content.

Confirmed sleep is intentionally shown as a quiet labeled band rather than invented telemetry. During true macOS sleep, normal applications and agents are suspended, so MY MACHINE records the sleep and wake boundaries but does not claim that work happened inside them. If the lid is closed while the Mac remains awake in clamshell mode, monitoring continues normally. Occasional system maintenance wakes are not treated as evidence that an app or agent kept working.

The battery subtitle reports the observed time required to lose the latest ten percentage points when one continuous run proves it. With at least twenty minutes and three points of uninterrupted discharge, it can instead show a clearly marked ten-point equivalent pace. Charging, sleep, restarts, gaps, and rebounds split or invalidate the claim; this is backward-looking pace, not predicted remaining runtime.
