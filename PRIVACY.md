# MY MACHINE privacy boundary

MY MACHINE is a personal, single-user, local machine journal—not an employee-monitoring, attention-scoring, security-detection, or productivity-scoring tool.

Stored by default:

- UTC timestamps and local report-day identity
- Foreground application display name and bundle identifier
- Elapsed idle state, app launch/quit/activation, sleep/wake
- Aggregate system CPU, load, memory/VM, swap, thermal, battery/charging, disk-byte, and network-interface-byte readings
- An optional aggregate GPU activity estimate when the current graphics driver exposes a usable whole-device hardware value; it is not guaranteed and is never per-app attribution
- Interval totals for keyboard actions, pointer movement/dragging, clicks, and scrolling, used only to show hands-on intensity
- A short-retention set of significant process resource readings when macOS exposes them
- Parent-process and owning-app relationships used to combine related helpers and workers into local app-family resource rollups
- Deterministic events, daily reports, settings, and provenance explanations

Pause and launch-at-login choices are also mirrored through macOS preferences so they remain authoritative across an immediate quit or restart.

Optional local notifications say only that a private briefing is ready. App names, process names, work categories, metrics, report excerpts, and recommendations remain inside MY MACHINE and are never placed in notification payloads. These alerts use standard macOS notification permission and do not use push notifications or a server.

Never stored:

- What you type, individual keys, pointer coordinates or targets, and all other input-event contents or payloads
- Screen recordings, screenshots, screen pixels, or audio
- Window titles, accessibility/UI text, URLs, tabs, workspace or project names, prompts, documents, file contents, messages, email, clipboard, or typed text
- File paths, names of files or documents opened inside applications, command-line arguments, environment variables, shell history, repository names or contents, DNS, domains, IPs, ports, or network destinations. Significant executable/process names are the only filename-like identity retained.
- Credentials, secrets, or account identifiers

MY MACHINE contains no analytics SDK, remote service, AI call, updater, push-notification service, or outbound network client. It never uploads telemetry, app-family rollups, reports, or diagnosis briefs. Reports and local report-ready alerts work entirely offline. Detailed samples default to three days; daily summaries support longer trends. A file export requires an explicit Save action; a diagnosis clipboard handoff requires an explicit Diagnose My Machine action.

**Diagnose My Machine** is an explicit, user-initiated handoff. It builds a deterministic brief locally from the latest 24 elapsed hours, places it on the current Mac's clipboard, and may open the official ChatGPT or Claude website selected in Settings. It never reads existing clipboard contents, types, pastes, attaches, uploads, or sends the brief. No monitoring data or diagnosis content reaches an external provider unless the user chooses to paste and send it, at which point that provider's privacy terms apply. Opening a selected website still makes the ordinary browser request needed to load that site. While MY MACHINE remains running, it clears the copied brief after roughly ten minutes only when it can confirm the clipboard has not since been replaced; quitting or a crash can prevent that cleanup.

The brief is capped at 32 KiB. It can include aggregate CPU/GPU, memory pressure and swap context, thermal and battery trends, disk/network totals, coverage, gaps, confirmed sleep, qualitative hands-on activity, MY MACHINE's own footprint, and a few top foreground/background application display names. Application names can be replaced with anonymous labels in Settings. The brief excludes bundle identifiers, PIDs, process starts, parent PIDs, worker/process names, raw input counts, exact raw samples, paths, destinations, raw database contents, and stored event/report prose. Application labels are sanitized and explicitly marked as untrusted data, never instructions.

The optional graphics-driver value describes aggregate hardware activity only. Reading it does not capture, inspect, reconstruct, or infer screen pixels, windows, images, video, or any other displayed content. When the driver does not expose a usable value, MY MACHINE stores and shows no GPU estimate.

App-family attribution is practical context, not forensic accounting. Memory footprint can include pages shared with other processes. Per-process read/write counters show observed file or disk activity; they do not reveal file contents, measure storage consumed, or estimate SSD wear.
