# Changelog

All notable user-visible changes are recorded here.

## [Unreleased]

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

[Unreleased]: https://github.com/Nexus-Global-Partners/MyMachine/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.2.0
[1.1.1]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.1.1
[1.1.0]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.1.0
[1.0.1]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.0.1
[1.0.0]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.0.0
