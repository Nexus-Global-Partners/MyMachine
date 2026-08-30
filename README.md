# MY MACHINE

MY MACHINE is a native, local-first macOS background monitor that connects foreground and background application activity with whole-machine performance, then turns the result into practical, plain-language understanding.

Repository: [Nexus-Global-Partners/MyMachine](https://github.com/Nexus-Global-Partners/MyMachine) · [Download MY MACHINE 1.3.1](https://github.com/Nexus-Global-Partners/MyMachine/releases/download/v1.3.1/MY-MACHINE-1.3.1.zip) · [All releases](https://github.com/Nexus-Global-Partners/MyMachine/releases)

## Install and see your first useful view

1. Download [MY-MACHINE-1.3.1.zip](https://github.com/Nexus-Global-Partners/MyMachine/releases/download/v1.3.1/MY-MACHINE-1.3.1.zip), unzip it, and move **MY MACHINE.app** into **Applications**.
2. In Finder, Control-click **MY MACHINE.app** and choose **Open**. Confirm **Open** once more if macOS asks. The public build is ad-hoc signed and is not Apple-notarized; this one-time Finder step is expected. If macOS still blocks it, approve it under **System Settings → Privacy & Security** and open it again.
3. Look for the simple Mac outline in the menu bar or MY MACHINE in the Dock. Click the menu-bar icon to see the last hour immediately; the view fills in as local history is recorded.
4. Use the Calm/Precise switch and 1h–7d history picker directly in the menu. The small diagnosis icon prepares a private, minimized context brief only when you click it. Nothing is uploaded or sent for you.

The download above is an Apple-silicon build for macOS 15 or later. Intel users and anyone who prefers to inspect the build can compile from source below.

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

The package script builds an optimized app for the host architecture, constructs a standard `.app` bundle, applies an ad-hoc Hardened Runtime signature, and writes one clean set of versioned artifacts to `outputs/`. The downloadable v1.3.1 app is for Apple-silicon Macs; the public source can be built on any supported Mac.

Move `outputs/MY MACHINE.app` into `/Applications`, then use the same one-time Finder **Open** step described above. See [HANDOFF.md](HANDOFF.md) for isolated development, architecture, known follow-ups, and release checks.

## Architecture

- SwiftUI/AppKit application and native menu-bar presence
- Permission-free core collector for foreground app identity, idle duration, aggregate hands-on activity counts, CPU, load, VM/memory, swap, physical disk bytes, interface network bytes, battery/charging, thermal state, app lifecycle, sleep/wake, and an optional whole-device GPU activity estimate when the current graphics driver exposes a usable value
- Isolated best-effort process extension for significant process CPU, memory footprint, and observed file/disk activity; related helpers and workers are combined under their owning app using local parent relationships, and incomplete coverage never breaks the core
- Actor-confined SQLite database with WAL transactions, owner-only permissions, bounded raw retention, crash-safe commits, integrity checking, and non-destructive corruption recovery. Private recovery copies follow raw-data retention and are removed by **Delete All Data**.
- Deterministic insight engine with duration/evidence gates and no AI or network dependency
- Clicking the menu-bar icon opens a centered, cached view immediately and refreshes it from the local database each time it opens. The complete product stays in that compact Calm/Precise surface; a regular Monitoring window remains available for deeper history and settings.
- System, Light, and Dark appearances apply consistently to the menu and main app.
- The header states both how much non-idle use was observed since the start of today and the length of the current natural session. Brief pauses do not split one session. This is practical time context, never a focus, attention, effort, or productivity score.
- **Diagnose My Machine** builds a deterministic, privacy-bounded brief from the latest 24 elapsed hours, copies it only after the user clicks, and can open ChatGPT or Claude as a convenience. Copy only is the default. MY MACHINE never reads the clipboard, calls an AI service, inserts the brief into a website, or sends it. Application names can be anonymized in Settings.
- A graph-first status view keeps whole-Mac CPU demand and the clearly labeled GPU activity estimate as separate lines. The label rail pairs each series identity and percentage with short, evidence-bounded window meaning: demanding duration and practical impact for the machine, plus recorded hands-on share and the longest physical-input stretch. Only genuinely urgent line sections turn red; manageable load keeps the original series color. CPU and GPU are never combined into an invented universal utilization percentage, and hands-on input is never presented as focus or productivity.
- Rolling Monitoring view for the last 1, 6, 12, 24, or 48 elapsed hours, or the last 7 days, led by one unified time-aligned timeline. Precise mode preserves interval detail; Calm mode uses longer rolling averages for a quieter overview. Both keep CPU and GPU distinct, bridge unrecorded gaps honestly, mark memory and thermal pressure below the core lines, and show whether the Mac was used directly, working in the background, or asleep. Exact power, memory, and network context remains available through selection and diagnosis.
- A selected timeline moment has a visible **Now** control and an Escape shortcut; clicking its marker again, the label rail, or the time axis also returns to the current status.
- App attribution stays contextual: select an exact time to see which foreground and background apps were observed then, or open the full details. The timeline does not use separate per-app mini graphs.
- Progressive disclosure: practical meaning is shown first, while exact readings, attribution limits, and metric provenance stay available under Details & privacy
- Privacy-safe local notifications when a reliable briefing is ready; notification text never contains app names, process names, metrics, or report excerpts
- Daily summaries remain available in History for longer-term review and export

The diagnosis brief is capped at 32 KiB and contains selected aggregates, coverage and gap context, confirmed sleep, a representative timeline, and top application-family summaries. It excludes raw samples, PIDs, bundle identifiers, worker names, raw input counts, paths, destinations, and stored event prose. Application labels are sanitized and treated as untrusted data. Clipboard content is limited to the current Mac; while MY MACHINE remains running, it is cleared after roughly ten minutes only if it has not been replaced.

Data is stored in `~/Library/Application Support/MY MACHINE/` unless `DAILYMAC_DATA_DIR` is set for an isolated test run. A tiny preferences record for pause, notification, and launch choices is stored by macOS under `~/Library/Preferences/local.mymachine.app.plist` so an immediate quit cannot accidentally undo a privacy choice.

App-family memory is a best-effort footprint and can include pages shared with other processes. Per-process read/write counters describe observed file or disk activity; they do not measure storage consumed, identify files, or estimate SSD wear.

The optional GPU line is an aggregate hardware-activity estimate reported by the current graphics driver. It is not guaranteed to be available, is not per-app attribution, and never reads or derives anything from screen pixels or displayed content.

Confirmed sleep is intentionally shown as a quiet labeled band rather than invented telemetry. During true macOS sleep, normal applications and agents are suspended, so MY MACHINE records the sleep and wake boundaries but does not claim that work happened inside them. If the lid is closed while the Mac remains awake in clamshell mode, monitoring continues normally. Occasional system maintenance wakes are not treated as evidence that an app or agent kept working.

The battery subtitle reports the observed time required to lose the latest ten percentage points when one continuous run proves it. With at least twenty minutes and three points of uninterrupted discharge, it can instead show a clearly marked ten-point equivalent pace. Charging, sleep, restarts, gaps, and rebounds split or invalidate the claim; this is backward-looking pace, not predicted remaining runtime.
