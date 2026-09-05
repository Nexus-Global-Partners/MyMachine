# Quick dashboard and notch interaction

The quick dashboard is a presentation layer over the existing AppModel. It does not start a sampler, refresh collection, change consent, or persist input events. CPU, memory and battery use existing machine readings. Paused, missing and stale readings display a dash. No application names appear in the preview or dashboard.

## Interaction

- Rest the pointer within the camera housing's horizontal bounds for 300 ms to reveal a 280 × 64 point preview immediately below the housing.
- Click the preview (or the housing target directly) to expand a 460 × 440 point scrollable dashboard, clamped to the display's available bounds. Hover never takes keyboard focus.
- Moving from the target to the preview is continuous. Leaving the preview has a 200 ms grace period. Passing through the target while dragging does not trigger it.
- An expanded dashboard stays open when the pointer leaves. Escape, Close, outside click, application switch or Space change dismisses it. After dismissal the pointer must leave the target before hover can reopen it.
- Opening/closing uses brief top-anchored frame animations. Reduce Motion removes spatial animation. The opaque dark surface also remains usable with Reduce Transparency.
- Menu-bar options provide Open Quick Dashboard, Open Full Dashboard and Settings. Shift–Command–D toggles the quick dashboard **when MY MACHINE has keyboard focus**; it is not a global keyboard hook.
- Hover is enabled by default on notched displays and can be disabled in Settings. On other displays, explicit opening anchors below the menu bar. Hover does not activate when macOS reports full-screen presentation or a hidden/automatically hidden menu bar.
- Sleep, inactive user sessions, changed screen geometry and Space switches dismiss the overlay. Screen geometry is recalculated from NSScreen safe areas, including external monitors and nonzero screen origins.

## Product boundaries

This branch depends on the privacy foundation in PR #1. Opening either presentation preserves consent and pause state. The first-run Start action explains local collection and default retention. History and Settings continue to use a normal window. The main window and existing menu-bar analytics remain available.

The notch controller observes mouse movement and mouse-down events solely for transient hit testing. It neither reads global keys nor records pointer coordinates, event contents or other applications' click targets. No Accessibility, Input Monitoring, Screen Recording or camera access is requested. Disable hover to remove these observers while the dashboard is closed; on a display without a notch they are only present while the dashboard is explicitly open.

## Validation before release

Deterministic validation covers hover dwell, rapid crossings, preview exit grace, click persistence, dismissal/re-entry, invalid/no-notch geometry and bounds on secondary displays. CI builds both configurations and runs these alongside existing privacy checks.

The following require hands-on acceptance on a notched Mac and remain release gates:

1. Hover does not steal keyboard focus or intercept adjacent menu items. Quick crossings and dragging do not reveal the panel.
2. The preview remains open while moving into it; direct click opens without waiting for hover. Clicked-open content persists after pointer exit.
3. Escape, outside clicks, Close and app switching reliably dismiss. Rapid open/close has no orphan panel or reappearance.
4. Keyboard-only menu access, focus rings, VoiceOver control labels and Reduce Motion work. Read all content at different scaling settings and with a shorter display.
5. Test automatic menu-bar hiding, full-screen apps, Mission Control, Spaces, display unplugging, clamshell mode, sleep/wake and fast user switching. No overlay may survive the lock/session transition or block system controls.
6. Toggle hover off during dwell and during preview. No further hover activations occur. Re-enable only after leaving/re-entering the target.
7. Open while collection is unapproved or paused; confirm no samples are added. Confirm old/absent data is never labeled current, and sample app names never appear in the compact UI.
8. Review motion and contrast on real hardware. Exact timing is a starting point; no successful physical-device usability test is implied by a passing build.

Developer ID signing and notarization still require Apple Developer membership. These changes do not install the application or publish a signed release.
