# MY MACHINE maintainer handoff

This is the continuation point for MY MACHINE 1.4.0. The repository is the complete source of truth. Local recordings, build caches, old app copies, and private QA screenshots are deliberately excluded.

## Current state

- Native SwiftUI/AppKit macOS menu-bar application
- Public product name: **MY MACHINE**
- Internal Swift package/executable names: `MY-MACHINE` and `DailyMac`
- Bundle identifier: `local.mymachine.app`
- Minimum system: macOS 15
- Current source build: 1.4.0, build 17
- No third-party packages, server, account, analytics SDK, updater, or network client
- Latest verification: 92/92 checks passed in the release configuration (2026-09-27), including live icon averaging between report refreshes, continuous calibrated monitor CPU readings, menu range semantics, presence regressions, live permission-free telemetry and independent POSIX CPU calibration
- Installed production copy on the original Mac: `/Applications/MY MACHINE.app`

Local QA (2026-09-07): release 76/76 and debug deterministic 74/74 passed; packaged and installed binaries match. Daily comparisons, day inspection, selected-time accessibility, Settings, and stable mode switching were exercised on the Mac. The final CPU-calibration/appearance revision is installed and collecting calibrated samples, but its final visual recheck is pending because the Mac was locked. Do not treat the appearance source-contract test as a substitute for that recheck.

Build 10 follow-up: presence regression failed with the old any-session-event policy, then the full release suite passed 79/79 with hardware-event inference. Installed binary and package hashes match. New recorded samples remained idle with zero input while automated Calm/Precise switches occurred, and the one-hour view showed the latest interval neutral. Calm and the user's one-hour range were restored. Earlier disputed presence records were not modified. A full Dark → System live-transition check is still separate from this presence verification.

Build 12 follow-up: Today runs from local midnight to now, adapts graph averaging to the elapsed day, and uses clock labels. Quiet previous/next arrows follow the menu order (Today, 1h, 6h, 12h, 24h, 48h, 7d), stopping at either end; stepping from Automatic starts from the displayed range. Today was visually verified in Calm on build 11, including the menu and midnight clock axis. The Mac locked before the final Precise/arrow click-through check, which remains pending; 84/84 release checks passed.

Build 13 follow-up (2026-09-23): supersedes build 12's time-scale choices. The picker and arrows offer exactly Auto / 1h / 4h / 6h / 12h / 24h / 48h. Auto is included in arrow navigation. Every selectable scale uses the full-width line graph in Calm and Precise, including 48h; the menu no longer routes to daily-summary bars. Today/week model cases and retained reports remain compatible, but are not offered in the UI. Personal recordings are not deleted or rewritten. Installed UI checks confirmed the exact menu, one-click Auto ↔ 1h ↔ 4h navigation, and the 48h graph in both modes. Wake-label spacing now scales with the visible window to avoid crowding clock ticks.

Build 14 follow-up (2026-09-23): removed the full-width Precise status banner. Health and live CPU/GPU remain in a compact graph pill, with Precise evidence beneath it; selected-time readings retain a return-to-current control. Calm and Precise now have identical panel height. Release validation passed 84/84, the installed binary matches the packaged app, and side-by-side native screenshots confirmed equal sizing and visible Precise details. No GitHub publication was requested.

Build 15 follow-up (2026-09-25): the menu bar can navigate previous local calendar days within detailed-data retention and return to the previous live range. Past days use fixed midnight-to-midnight intervals and historical labels; loading clears the old graph so it cannot masquerade as the newly selected day. Missing detail is identified as unrecorded, not sleep or zero demand. Release validation passed 84/84. Native UI checks showed full-day graphs on 22, 23, and 24 September and a one-click return to the live Auto graph. The installed binary matches the packaged app.

Build 16 follow-up (2026-09-25): the menu-bar laptop outline now contains two rounded indicators. The upper bar is machine health (green comfortable, yellow watch, orange pressure, red alert). The lower four-step bar is current CPU/GPU demand using the same rising scale; it measures machine load, not user focus. Both go neutral without a fresh sample, and accessibility/tooltip text explains the values. Deterministic state tests and the full release suite passed 87/87. The local package was signed and checksum-verified; the installed build 16 binary matched and launched. A direct visual screenshot of the transient menu-bar item was unavailable to the native UI automation, so that specific appearance should still be checked by a human on the live menu bar.

Build 17 source follow-up (2026-09-27): the popover's compact live readout now mirrors the icon, Auto names its observed span, and the fan and thermal readout shares the icon's single AppleSMC poll. The icon uses a bounded in-memory ring of every saved sample for its two-minute average and sustained-memory state. Monitor CPU/disk counters are measured independently on skipped broad-process scans. Network and disk byte deltas are tracked per interface or device so hot-plug, resets, and reappearance cannot turn old lifetime counters into new activity. Popover history reuses Auto's sample query, background-pressure overlap uses binary search, and unsupported responsiveness predictions were removed. Release validation passed 93/93 before packaging. This source update is intended for agent-assisted builds from the public repository; no new downloadable GitHub release is implied.

The internal `DailyMac` names are legacy implementation names. Renaming them is possible, but treat the bundle identifier, preferences domain, launch-at-login registration, data paths, and database migration behavior as one coordinated migration.

## Start on another Mac

Requirements: macOS 15 or later and Apple Command Line Tools with Swift 6.

```sh
xcode-select --install
git clone https://github.com/Nexus-Global-Partners/MyMachine.git
cd MyMachine
swift build
swift run DailyMacValidation
./scripts/package.sh
```

The packaged app, archives, and SHA-256 file appear in `outputs/`. Move `outputs/MY MACHINE.app` into `/Applications`, then open it once. Installing under `/Applications` matters for the complete Launch at Login and notification lifecycle.

The packaging script applies an ad-hoc Hardened Runtime signature. It is not Developer ID signed or notarized, so a copied app may require a one-time Control-click → **Open** in Finder or approval in **System Settings → Privacy & Security**.

## Safe development mode

Avoid mixing development samples with personal history:

```sh
export DAILYMAC_DATA_DIR="$(mktemp -d)"
export DAILYMAC_DISABLE_NOTIFICATIONS=1
export DAILYMAC_DISABLE_LOGIN_REGISTRATION=1
swift run DailyMac
```

The default production database is `~/Library/Application Support/MY MACHINE/DailyMac.sqlite`. Preferences live at `~/Library/Preferences/local.mymachine.app.plist`.

## Product rules that should survive redesigns

1. Interpret first. Every metric should explain what happened, whether it was normal, why it mattered, the likely cause, the practical effect, and whether action is useful.
2. Keep the default view calm and plain-language. Put exact readings, collection limits, and provenance behind inspection or disclosure.
3. Never imply productivity, attention, intent, or causation from correlation.
4. Preserve the local-only privacy boundary. Do not capture content, destinations, file paths, window titles, screen pixels, keystrokes, prompts, or messages.
5. Keep one well-scaled full-width timeline for every selectable range through 48h. Do not replace it with daily-summary bars. Never draw fictitious history from daily averages.
6. Use semantic green, yellow, and red for health, with quiet neutral surfaces around them. Reserve red for genuinely urgent evidence. Keep CPU blue, GPU cyan, human presence electric pink, and background/sleep neutral; presence is not a health warning.
7. Keep performance/efficiency-core detail subtle inside the CPU fill. Reveal exact P-core/E-core values only when the user inspects a point. Never guess a split for incomplete history.
8. The menu panel must appear centered under its menu-bar item, load cached history immediately, refresh on opening, and remain smooth while scrolling.
9. The product is menu-bar-only: one native NSStatusItem/NSPopover, two display modes, no full-dashboard window. Settings & Privacy remain available from the overflow menu. Never reposition a visible window around the mouse or conceal/reveal it during mode changes.
10. Monitoring overhead must stay negligible relative to ordinary work.
11. Diagnosis remains a user-controlled handoff: fixed 24-hour bounded evidence, current-Mac-only clipboard, no auto-paste/upload/send, and no provider API or account coupling.

## Architecture map

```text
DailyMacApp.swift
  └─ AppModel.swift
      ├─ TelemetrySampler.swift
      ├─ SQLiteStore.swift
      ├─ InsightEngine.swift / EventDetector.swift
      ├─ TimelineSemantics.swift
      ├─ DiagnosisBriefRenderer.swift
      ├─ NotificationCoordinator.swift
      └─ SwiftUI monitoring, history, activity, and settings views
```

- `DailyMacApp.swift`: app entry point and menu-bar lifecycle
- `AppAppearance.swift`: app-wide System, Light, and Dark appearance choice
- `AppModel.swift`: orchestration, adaptive sampling, sleep/wake handling, refreshes, and report lifecycle
- `TelemetrySampler.swift`: permission-free AppKit/CoreGraphics/IOKit/Darwin readings and best-effort process attribution
- `SQLiteStore.swift`: actor-confined SQLite, schema migrations, WAL transactions, retention, and recovery; recovery archives share the raw-data retention boundary and are included in explicit data deletion
- `InsightEngine.swift`, `EventDetector.swift`, `TimelineSemantics.swift`, `NetworkThroughputSemantics.swift`: deterministic interpretation, evidence gates, and measured-window preparation
- `DiagnosisBriefRenderer.swift`: typed, deterministic, 32 KiB-capped external-assistant handoff with explicit untrusted-data boundaries
- `MonitoringTimelineView.swift`: graph-first current interpretation, unified timeline, selection inspector, semantic urgency, scale rules, and progressive disclosure
- `MenuBarMonitoringView.swift`: cached menu surface, Calm/Precise switching, Automatic/manual history, diagnosis, Settings & Privacy
- `LongRangeMonitoringView.swift`, `MonitoringDaySummary.swift`: daily comparisons, calendar bounds, retained-summary fallback and day inspection; legacy GPU stays unavailable
- `LiveMachineContextPill.swift`, `TimelineWorkAttribution.swift`: measured app-family CPU capacity, human/background context and hardware details; app-family activity is never labeled as agents-only CPU
- `DiagnosisControls.swift`: compact glass controls plus active-today and current-session summaries
- `DailyMacValidation/ValidationMain.swift`, `HistoryValidation.swift`, `WorkAttributionValidation.swift`, `ProcessCPUValidation.swift`, `AppCPUCalibrationValidation.swift`, `StorageMaintenanceValidation.swift`: the project’s bespoke verification runner

## Validation and packaging

This project does not currently use `swift test`; `Tests/` is empty and `Package.swift` defines no test target. Use:

```sh
swift run DailyMacValidation
swift run -c release DailyMacValidation
./scripts/package.sh
codesign --verify --deep --strict --verbose=2 "outputs/MY MACHINE.app"
unzip -t "outputs/MY-MACHINE-1.4.0.zip"
unzip -t "outputs/MY-MACHINE-Source-1.4.0.zip"
(cd outputs && shasum -a 256 -c "SHA256SUMS-1.4.0.txt")
```

The final validation check reads live hardware and timing, so it remains a local release gate. GitHub CI runs the deterministic portion in both debug and release configurations, then performs packaging, signature, archive, checksum, and source-boundary checks on a clean macOS runner. The release build is host-architecture only; the current packaged artifact is arm64. `scripts/package.sh` reads the archive version from `Resources/Info.plist`, so bump the short version and build number there before a release.

## Privacy and data behavior

Read [PRIVACY.md](PRIVACY.md) before changing collection. The core rule is simple: capture enough context to explain the Mac, never enough to reconstruct the person’s work.

Default retention:

- Detailed samples and exact app events: 3 days
- Notable aggregate events: 90 days
- Compact daily reports: 365 days (including optional aggregate GPU/pressure summary in 1.4+; older reports remain decodable)

GPU data is optional and driver-dependent. Process coverage is best effort. Memory footprint may include shared pages. Disk counters never identify files. Network totals never identify destinations.

App/process CPU and the monitor's own CPU carry measurement version 1 after the Mach-timebase correction. Legacy or mixed-version collections are excluded from new CPU claims, not rescaled using the current Mac's timebase. Whole-machine CPU/GPU history uses independent counters and remains valid. System ticks without a fresh own-process observation leave monitor CPU unavailable rather than recording a measured zero.

From build 10, recent human use is inferred from specific `.hidSystemState` keyboard/pointer event classes with nonzero counters and finite valid ages. Never restore `.combinedSessionState` plus the any-event timer: it can reset without human input. The idle preference still allows quiet reading after input. No additional permission or event payload is collected. Old presence bits have insufficient source provenance to repair reliably; virtual HID devices can still impersonate hardware, so this is not proof of a person's identity or attention.

Corruption recovery archives contain the same private telemetry as the active database. They use owner-only permissions, expire with detailed raw history, and are removed by **Delete All Data**.

Diagnosis handoff is intentionally not an integration layer. `AppModel` queries one fixed 24-hour window, `DiagnosisBriefRenderer` creates an allowlisted prompt/evidence bundle, and AppKit writes it to a current-host-only pasteboard. The optional destination choice only opens an official HTTPS page. The app cannot know whether the user later pasted or sent the brief and must never claim that it did.

## Known follow-ups

These are the most useful next engineering tasks, in priority order:

1. Move the deterministic validation executable into XCTest over time for richer CI diagnostics; keep the live hardware check as a separate local smoke test.
2. Decide whether distribution builds should be universal, Developer ID signed, and notarized.
3. Run a full overnight sleep/wake, login, notification, and resource-endurance cycle on hardware.

## Repository hygiene

Never commit `.build/`, `work/`, `outputs/`, SQLite/WAL/SHM files, app backups, QA captures, or local telemetry. The original development workspace contained private app history and identifiable screenshots in `work/`; those artifacts are intentionally absent from GitHub and the handoff ZIP.

Before publishing a release, verify the repository is clean, run both validation configurations, create the immutable release tag, package from that tagged commit, and attach the app ZIP, source ZIP, and generated SHA-256 file to the GitHub release. The manual release-assets workflow checks out that exact tag, verifies the draft and release metadata, repeats the source-boundary audit, and can replace those three assets without publishing the draft.
