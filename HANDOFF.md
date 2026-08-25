# MY MACHINE maintainer handoff

This is the continuation point for MY MACHINE 1.0. The repository is the complete source of truth. Local recordings, build caches, old app copies, and private QA screenshots are deliberately excluded.

## Current state

- Native SwiftUI/AppKit macOS menu-bar application
- Public product name: **MY MACHINE**
- Internal Swift package/executable names: `MY-MACHINE` and `DailyMac`
- Bundle identifier: `local.mymachine.app`
- Minimum system: macOS 15
- Current release: 1.0, build 1
- No third-party packages, server, account, analytics SDK, updater, or network client
- Latest verification: 36/36 checks passed in debug and release configurations
- Installed production copy on the original Mac: `/Applications/MY MACHINE.app`

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

The packaged app and archives appear in `outputs/`. Move `outputs/MY MACHINE.app` into `/Applications`, then open it once. Installing under `/Applications` matters for the complete Launch at Login and notification lifecycle.

The packaging script applies an ad-hoc Hardened Runtime signature. It is not Developer ID signed or notarized, so a copied app may require **Open** from Finder or approval in **System Settings → Privacy & Security**.

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
5. Prefer one well-scaled timeline over many small charts. CPU and GPU remain superposed; memory pressure, hands-on input, battery, and confirmed sleep share the same clock.
6. Use semantic green, neutral black, and red for machine state. Reserve red for genuinely urgent evidence; manageable states remain neutral. Data-series colors may remain stable identifiers.
7. Keep performance/efficiency-core detail subtle inside the CPU fill. Reveal exact P-core/E-core values only when the user inspects a point. Never guess a split for incomplete history.
8. The menu panel must appear centered under its menu-bar item, load cached history immediately, refresh on opening, and remain smooth while scrolling.
9. The app remains menu-bar-only. It should not appear in the Dock.
10. Monitoring overhead must stay negligible relative to ordinary work.

## Architecture map

```text
DailyMacApp.swift
  └─ AppModel.swift
      ├─ TelemetrySampler.swift
      ├─ SQLiteStore.swift
      ├─ InsightEngine.swift / EventDetector.swift
      ├─ TimelineSemantics.swift
      ├─ NotificationCoordinator.swift
      └─ SwiftUI monitoring, history, activity, and settings views
```

- `DailyMacApp.swift`: app entry point and menu-bar lifecycle
- `AppModel.swift`: orchestration, adaptive sampling, sleep/wake handling, refreshes, and report lifecycle
- `TelemetrySampler.swift`: permission-free AppKit/CoreGraphics/IOKit/Darwin readings and best-effort process attribution
- `SQLiteStore.swift`: actor-confined SQLite, schema migrations, WAL transactions, retention, and recovery
- `InsightEngine.swift`, `EventDetector.swift`, `TimelineSemantics.swift`: deterministic interpretation and evidence gates
- `MonitoringTimelineView.swift`: graph-first current interpretation, unified timeline, selection inspector, semantic urgency, scale rules, and progressive disclosure
- `DailyMacValidation/main.swift`: the project’s bespoke verification runner

## Validation and packaging

This project does not currently use `swift test`; `Tests/` is empty and `Package.swift` defines no test target. Use:

```sh
swift run DailyMacValidation
swift run -c release DailyMacValidation
./scripts/package.sh
codesign --verify --deep --strict --verbose=2 "outputs/MY MACHINE.app"
unzip -t "outputs/MY-MACHINE-1.0.zip"
unzip -t "outputs/MY-MACHINE-Source-1.0.zip"
```

The final validation check reads live hardware and timing, so it is not fully hermetic. The release build is host-architecture only; the original packaged artifact is arm64. Version numbers currently appear in `Resources/Info.plist` and archive names in `scripts/package.sh`, so update both together.

## Privacy and data behavior

Read [PRIVACY.md](PRIVACY.md) before changing collection. The core rule is simple: capture enough context to explain the Mac, never enough to reconstruct the person’s work.

Default retention:

- Detailed samples and exact app events: 3 days
- Notable aggregate events: 90 days
- Compact daily reports: 365 days

GPU data is optional and driver-dependent. Process coverage is best effort. Memory footprint may include shared pages. Disk counters never identify files. Network totals never identify destinations.

## Known follow-ups

These are the most useful next engineering tasks, in priority order:

1. Serialize **Delete All Data** against an in-flight report refresh, or add a deletion epoch. Today an already-running refresh can retain pre-delete samples and write a report or notification after deletion begins.
2. Replace a scheduled notification without removing the valid existing request first. A transient add failure should not lose the day’s alert.
3. Persist the first-use notification sentinel atomically with acceptance, so quitting in the narrow post-delivery window cannot produce a duplicate first-use alert.
4. Add a real XCTest target and CI while keeping the live hardware check as a separate smoke test.
5. Decide whether distribution builds should be universal, Developer ID signed, and notarized.
6. Centralize versioning so the plist, archive names, and future GitHub releases cannot drift.
7. Run a full overnight sleep/wake, login, notification, and resource-endurance cycle on hardware.

## Repository hygiene

Never commit `.build/`, `work/`, `outputs/`, SQLite/WAL/SHM files, app backups, full-screen QA captures, or local telemetry. The original development workspace contained private app history and identifiable screenshots in `work/`; those artifacts are intentionally absent from GitHub and the handoff ZIP.

Before publishing a release, verify the repository is clean, run both validation configurations, package from the tagged commit, and attach the generated source ZIP to the GitHub release.
