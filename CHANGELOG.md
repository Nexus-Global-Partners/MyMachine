# Changelog

All notable user-visible changes are recorded here.

## [Unreleased]

### Added

- A rebuilt two-column native popover: four selectable CPU, GPU, memory, and fan instruments; a quiet thermal-pressure scale; observed app CPU contributors; and a large unobstructed history graph.
- A Live / Period selector separates current readings from duration-weighted averages for the selected graph period. Historical-day navigation switches the instruments to Period automatically.
- Best-effort fan-speed history, saved alongside system readings. Existing records keep their fan fields unknown. The graph uses measured RPM relative to the hardware maximum, never estimated fan power or temperature.
- Settings now previews the live menu-bar icon, explains what each physical, compute, and state bar measures, and lets you reorder or hide the three instruments. Your existing arrangement remains the one-click original preset; an optional open style removes only the outlines.
- A source-first install handoff that a friend can paste to their own coding agent, including local validation, safe replacement, and the one-time ad-hoc-signature approval boundary.

### Changed

- Memory is now a distinct yellow signal. Fan and memory traces use centered measured buckets instead of artificial stair-step edges, with restrained translucent area fills that stop at every data gap. App rows are lighter at rest and gently brighten on hover.
- Time guides now use larger clock-aligned labels, with quiet duration annotations distinguishing observed absence, confirmed sleep, and missing readings. Native menus and card selection use cohesive glass controls and shared menu-bar CPU/GPU colors.
- The minimal instrument panel now uses desktop-backed native frost, quiet glass app rows, and brighter bordered selected metric cards. Graph strokes are slightly thicker; Reduce Transparency keeps the interface opaque.
- A single activity pill pairs **You** with recorded awake **Mac** time above the graph. Card colors identify selected signals without extra selection icons or duplicate legends. Supporting sensor explanations are available on hover and to assistive technology.
- Refresh and diagnosis remain in the overflow menu, leaving the time-range controls close to the chart.
- The menu-bar instrument and popover share the same blue CPU/GPU signals and pressure semantics. Auto shows its current elapsed span, while one-click arrows remain adjacent to the time-range menu.
- Menu-bar, popover, and history collection share a short-lived, synchronized AppleSMC read cache. Stale readings drop to unavailable instead of looking live.
- The popover reuses Auto's already-loaded system history and skips battery computations it never draws. Background-pressure interval lookup is indexed instead of scanning every interval for every app row.

### Fixed

- Today's You/Mac totals update on each saved reading rather than waiting for the two-minute daily report; overlapping samples are counted once and midnight boundaries are clipped.
- System-only sampling cycles no longer clear the most recent app-resource readings. The app list still withholds readings after they become stale.
- Settings now accurately explains measured fan speed separately from unavailable physical temperatures.
- Quitting macOS applications with an invalid or repeated PID no longer crash the monitor and make its menu-bar icon disappear.
- The menu-bar's two-minute CPU/GPU average and sustained memory signal now use every recently saved sample, not just the last report refresh plus one live reading.
- MY MACHINE's own CPU and disk-write counters are measured on every system sample even when a broader process scan is skipped, so a missing measurement no longer masquerades as zero CPU use or resets sustained-overhead detection.
- Network and physical-disk counters now baseline each interface or device independently. Newly connected, reset, or reappearing devices no longer contribute old lifetime bytes as a fresh activity spike.
- Live and cached states age out after roughly two missed sample intervals, and status text no longer promises the Mac will remain responsive based only on resource readings.
- Report limitations distinguish the new best-effort live fan RPM readout from stored history and unavailable exact temperature measurements.

### Earlier changes

- The menu-bar icon now has two small live signals inside the Mac outline: a health bar for pressure or alerts and four load steps for current CPU/GPU demand. Green, yellow, orange and red follow rising severity; gray means monitoring is paused, asleep or missing fresh data. Machine load is never presented as a measure of human focus.
- Added compact calendar-day browsing to the menu bar: step through recent recorded days, inspect their full local-day graphs in either mode, and return to the live range in one click. Historical gaps remain gaps, not invented zero activity.
- Removed the full-width status banner from Precise; its health, CPU and GPU readings now sit in a compact graph pill, with detailed evidence directly below.
- Simplified time scales to Auto / 1h / 4h / 6h / 12h / 24h / 48h. Previous/next arrows follow this exact order, including a return to Auto.
- Restored the full-width CPU/GPU line graph for 48h in both Calm and Precise. Today and week are no longer picker options; stored history and daily summaries are preserved.

## [1.4.0] - 2026-09-07

### Added

- Today: a live local-midnight-to-now timeline in Calm and Precise, with clock labels and averaging that adapts to the elapsed day.
- Quiet previous/next range arrows beside the history menu allow single-click changes without opening the menu.
- Daily overviews for 48 hours and the last seven calendar days: compare observed CPU/GPU means and peaks, human-use time, and open individual days for detail.
- Retained daily resource summaries preserve GPU measurements and pressure durations after detailed readings expire. Older CPU/activity summaries remain usable; unavailable GPU history is explicitly missing.
- A compact live workload inspector separates observed foreground, background, and agent-app CPU contribution from human presence, with leading apps, physical memory, swap and thermal context.
- Accessible previous/next-reading actions expose graph inspection without requiring pointer input.

### Changed

- A single native menu-bar popover replaces the window repositioning workaround and the remaining full-dashboard route. Settings and privacy controls stay accessible from the overflow menu.
- Automatic time-range selection remains live, with manual ranges available from one compact control.
- Live updates refresh silently every 30 seconds while the panel is open. Closed panels stop UI refresh work, and report aggregation runs off the main thread.

### Fixed

- Human-use detection now queries specific hardware keyboard/pointer event ages and counters instead of the combined session's any-event timer. Software-only session events cannot renew the pink rail; the configured quiet-reading grace period remains. Earlier presence records are not retrospectively rewritten, and virtual HID devices remain an inference limitation.
- App/process CPU counters now use the Mac's actual timebase; Apple Silicon readings previously under-reported CPU use. Older uncalibrated app readings are excluded from new CPU claims rather than silently mixed with corrected measurements. Whole-machine CPU history is unaffected.
- Switching from Dark or Light back to System clears the native appearance override.
- Short recorded sessions no longer vanish when smoothing produces a single point.
- Live health is calculated from recent readings independently of the selected history range.
- Quiet reading follows the existing idle classification instead of being marked away solely because no input events occurred.
- Unknown intervals are distinguished from confirmed sleep, and a brief sleep inside a data gap no longer turns the entire gap into a zero-load curve.
- Retention can now reclaim materially unused database space, with a weekly limit and non-fatal maintenance safeguards.

## [1.3.1] - 2026-08-30

### Changed

- The menu subtitle now gives the useful active-today and current-session context directly beneath **Monitoring**, instead of repeating the selected range and refresh time.
- Removed the redundant open-window shortcut and overflow chevron so the compact header keeps only meaningful controls.

### Fixed

- Active-use context no longer collapses into unreadable truncated labels beside the six-option range picker.

## [1.3.0] - 2026-08-30

### Added

- The menu and Monitoring window now include 48-hour and 7-day ranges with range-aware smoothing and calendar labels.
- The header shows both active time today and the current natural session, allowing brief pauses without resetting the session.

### Changed

- Diagnosis is now a compact icon in the menu header and the redundant bottom control strip is gone.
- Precise mode follows Calm mode's graph-first, full-width hierarchy while keeping its detailed context available through compact overlays and selection.
- Removed the separate full-screen dashboard and its network-only lane so MY MACHINE remains a focused two-mode menu-bar product.

## [1.2.0] - 2026-08-29

### Added

- Calm and Precise graph modes provide a quiet long-average overview or detailed interval readings without changing the panel anchor.
- Monitoring now supports 1-hour, 6-hour, 12-hour, and 24-hour ranges in the menu, main window, and full-screen dashboard.
- The unified graph distinguishes direct human use, autonomous/background work, confirmed sleep, thermal management, and memory pressure while keeping CPU and GPU visually primary.
- Current activity, observed app contribution, live values, and selected-time context remain available through progressive disclosure.

### Changed

- Reworked the graph palette, smoothing, status pills, gap transitions, and severity rules so ordinary activity stays calm and red is reserved for genuine pressure.
- The app now appears in the Dock when opened as a normal macOS application while retaining its menu-bar experience.
- Packaging replaces the generated output directory on every run, preventing old app bundles and archives from accumulating locally.
- Release workflows pin third-party GitHub Actions to reviewed commits while retaining automated signature, checksum, and source-boundary checks.

### Fixed

- Menu opening and Calm/Precise switching no longer reveal a provisional off-anchor panel before the final centered position is known.
- Timeline selections clear automatically, show their selected clock time, and remain stable while fresh samples arrive.
- Retention and **Delete All Data** now include private database recovery archives; a cleanup error no longer leaves monitoring stopped.

## [1.1.1] - 2026-08-26

### Fixed

- The newest timestamp now drives current status even when stored samples arrive out of order; selected history and whole-window summaries are labeled distinctly.
- Full-screen monitoring reliably fills the active display when macOS declines the native full-screen transition instead of leaving a floating dashboard window.
- Timeline selection now has an explicit **Show current** action, while Escape, the rail, and time axis remain quick ways back to live status.
- The 24-hour network graph uses readable relative endpoints and keeps its scale labels inside the visible plot.
- Application contributor rows exclude unattributed helper processes and stay framed as recognizable apps.
- Plugged-in and stable-swap states use concise practical wording rather than presenting stale discharge pace or an unexplained raw swap total.

## [1.1.0] - 2026-08-25

### Added

- Shows a few top observed application CPU contributors for the selected window with honest coverage-aware shares and cached native icons.
- **Active today** gives immediate non-idle time context without claiming focus or productivity.
- **Diagnose My Machine** prepares a deterministic, privacy-bounded 24-hour brief that the user can copy into an external assistant. Copy only remains the default; MY MACHINE never uploads, pastes, or sends the brief.
- The expanded timeline supports native macOS full screen and 1-hour, 6-hour, and 24-hour views.
- Actual whole-Mac download and upload activity can be reviewed over time without inspecting destinations.
- Releases now include SHA-256 hashes and a complete, privacy-audited source archive.

### Changed

- The graph remains the primary status surface. CPU and GPU keep stable identities, while red is reserved for evidence of a genuinely urgent interval; any red CPU, GPU, or memory segment turns its matching left-hand KPI red for the same measured duration.
- Timeline selection can be cleared with **Now**, Escape, a second marker click, the label rail, or the time axis.
- Diagnosis rendering and ordering remain bounded and deterministic so opening the interface stays responsive.

### Privacy

- Diagnosis excludes bundle identifiers, PIDs, worker names, paths, destinations, raw input counts, exact samples, and stored prose. Application names can be anonymized.

## [1.0.1] - 2026-08-25

- Made the unified timeline the primary status surface.
- Kept CPU and GPU superposed with soft fills and removed the large status banner.
- Reserved red for urgent processor intervals and integrated constrained memory as subtle duration bands.
- Simplified the compact panel to the essential graph, physical-input correlation, and readable relative-time landmarks.

## [1.0.0] - 2026-08-25

- Published the initial local-first macOS monitoring app, source handoff, privacy contract, and menu-bar experience.

[Unreleased]: https://github.com/Nexus-Global-Partners/MyMachine/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/Nexus-Global-Partners/MyMachine/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/Nexus-Global-Partners/MyMachine/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.2.0
[1.1.1]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.1.1
[1.1.0]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.1.0
[1.0.1]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.0.1
[1.0.0]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.0.0
