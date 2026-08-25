# Changelog

All notable user-visible changes are recorded here.

## [Unreleased]

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

[Unreleased]: https://github.com/Nexus-Global-Partners/MyMachine/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.1.0
[1.0.1]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.0.1
[1.0.0]: https://github.com/Nexus-Global-Partners/MyMachine/releases/tag/v1.0.0
