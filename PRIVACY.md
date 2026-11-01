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

MY MACHINE contains no analytics SDK, hosted telemetry service, AI call, updater, or push-notification service. It never uploads telemetry, app-family rollups, reports, or diagnosis briefs. Reports and local report-ready alerts work entirely offline. Detailed samples default to three days; daily summaries support longer trends. A file export requires an explicit Save action; a diagnosis clipboard handoff requires an explicit Diagnose My Machine action.

Optional daylight shading uses a manually chosen city. Clicking **Find city** sends only the entered search to Apple's geocoding service; no monitoring data accompanies it. After confirmation, the city name and coordinates are stored in local preferences. Sunrise, sunset and civil-twilight estimates are then calculated offline for the displayed dates using NOAA's solar-position approximation. MY MACHINE does not request location permission, track location, or infer a city from a time zone. The saved city applies to all displayed history, not a recorded travel history, and can be turned off in Settings.

**Diagnose My Machine** is an explicit, user-initiated handoff. It builds a deterministic brief locally from the latest 24 elapsed hours, places it on the current Mac's clipboard, and may open the official ChatGPT or Claude website selected in Settings. It never reads existing clipboard contents, types, pastes, attaches, uploads, or sends the brief. No monitoring data or diagnosis content reaches an external provider unless the user chooses to paste and send it, at which point that provider's privacy terms apply. Opening a selected website still makes the ordinary browser request needed to load that site. While MY MACHINE remains running, it clears the copied brief after roughly ten minutes only when it can confirm the clipboard has not since been replaced; quitting or a crash can prevent that cleanup.

The brief is capped at 32 KiB. It can include aggregate CPU/GPU, memory pressure and swap context, thermal and battery trends, disk/network totals, coverage, gaps, confirmed sleep, qualitative hands-on activity, MY MACHINE's own footprint, and a few top foreground/background application display names. Application names can be replaced with anonymous labels in Settings. The brief excludes bundle identifiers, PIDs, process starts, parent PIDs, worker/process names, raw input counts, exact raw samples, paths, destinations, raw database contents, and stored event/report prose. Application labels are sanitized and explicitly marked as untrusted data, never instructions.

The optional graphics-driver value describes aggregate hardware activity only. Reading it does not capture, inspect, reconstruct, or infer screen pixels, windows, images, video, or any other displayed content. When the driver does not expose a usable value, MY MACHINE stores and shows no GPU estimate.

App-family attribution is practical context, not forensic accounting. Memory footprint can include pages shared with other processes. Per-process read/write counters show observed file or disk activity; they do not reveal file contents, measure storage consumed, or estimate SSD wear.

## Optional manual fan control

Monitoring works without administrator access. Fan control is separately enabled from Settings: the app shows a confirmation, then opens a reviewable installer in Terminal, where macOS asks for an administrator password. MY MACHINE never receives or stores that password. The installer trusts the specific locally installed, ad-hoc signed app you approve; this is not verification of an external publisher. It copies that exact signed build into a root-owned system location and registers a narrowly scoped local helper. No manual fan target is applied during setup; updates first release any fan control owned by MY MACHINE.

The helper accepts only capability/status reads, a bounded all-fan percentage, Auto, and lease heartbeats. Both sides require the same exact code-signing hash, and only the active console user may connect. Unsupported hardware, protected thermal modes, stale readings, and mismatched fan ownership fail closed. The percentage describes RPM relative to each fan's measured maximum, not electrical power or sound volume. The hardware minimum is respected; Auto returns control to macOS instead of forcing the fans off.

Owned manual targets are released on client disconnect, lost heartbeat (20 seconds), sleep, serious/critical/unknown thermal state, or system-protected fan mode. A small root-private ownership journal records only hardware identity and fan mode/target metadata so a restarted helper can recover its own targets after a crash. Recovery never takes over a target changed by another controller. These are best-effort hardware operations: an unavailable device or failed write is reported and its recovery journal retained, rather than claiming success.

The protected app copy is `/Library/PrivilegedHelperTools/local.mymachine.fancontrol.app`; its service definition is `/Library/LaunchDaemons/local.mymachine.fancontrol.plist`; its private journal and lock are under `/Library/Application Support/local.mymachine.fancontrol`. Settings → Fan control → Remove opens the administrator remover, which restores or relinquishes owned control before removing the service and app copy. An empty private journal directory/lock may remain. Neither the helper nor its installer uploads data. Each changed app build requires updating this exact-build helper through Enable/Update; ordinary monitoring remains available without it.
