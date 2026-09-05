import AppKit
import DailyMacCore
import SwiftUI

struct MenuBarMonitoringView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(TimelineDisplayMode.storageKey)
    private var timelineDisplayMode = TimelineDisplayMode.precise.rawValue

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if let content = model.menuBarMonitoringContent {
                    VStack(spacing: 0) {
                        if content.snapshot.sampleCount > 0 {
                            MonitoringTimelineView(
                                snapshot: content.snapshot,
                                samples: content.samples,
                                backgroundPoints: content.backgroundPoints,
                                events: content.events,
                                appContributors: content.appContributors,
                                presentation: .menuBar,
                                displayMode: selectedTimelineDisplayMode
                            )
                            .equatable()
                        } else {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else {
                    emptyState
                }
            }
        }
        .frame(width: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            MenuBarWindowPresentationObserver {
                model.menuBarDidOpen()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Monitoring")
                    .font(.headline)
                MenuBarActivitySummaryLabel(
                    activeTodayDuration: model.todayReport?.activeDuration,
                    currentSessionDuration: model.currentSessionDuration
                )
            }

            Spacer(minLength: 12)

            HStack(alignment: .center, spacing: 9) {
                HStack(spacing: 8) {
                    if model.menuBarIsRefreshing {
                        Text("Updating")
                            .foregroundStyle(.secondary)
                    } else if model.menuBarRefreshMessage != nil {
                        Label("Cached", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                            .help(model.menuBarRefreshMessage ?? "")
                    }
                }
                .font(.caption)

                MonitoringRangePickerControl(
                    selection: model.menuBarMonitoringRange,
                    itemWidth: 27,
                    onSelect: model.selectMenuBarMonitoringRange
                )
                .help("Choose how much history to show")

                TimelineDisplayModeControl()

                DiagnosisIconButton()

                Button {
                    model.refreshMenuBarNow()
                } label: {
                    if model.menuBarIsRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh monitoring")
                .accessibilityLabel("Refresh monitoring")
                .disabled(model.menuBarIsRefreshing)

                moreOptionsMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var menuBarRangeTitle: String {
        let displayedRange = model.menuBarMonitoringContent?.snapshot.range
            ?? model.menuBarMonitoringRange
        switch displayedRange {
        case .oneHour: return "Last hour"
        case .sixHours: return "Last 6 hours"
        case .twelveHours: return "Last 12 hours"
        case .twentyFourHours: return "Last 24 hours"
        case .fortyEightHours: return "Last 48 hours"
        case .oneWeek: return "Last 7 days"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.menuBarIsRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: emptyStateSymbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text(emptyStateTitle)
                .font(.subheadline.weight(.medium))
            Text(emptyStateDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .padding(20)
    }

    private var moreOptionsMenu: some View {
        Menu {
            if model.collectionState == .paused {
                Button("Resume Monitoring") { model.startMonitoring() }
            } else {
                Button("Pause for One Hour") { model.pauseForOneHour() }
                Button("Pause Until Tomorrow") { model.pauseUntilTomorrow() }
                Button("Pause Until I Resume") { model.pauseIndefinitely() }
            }
            Divider()
            Button("Open Quick Dashboard") { NotchPanelController.shared.toggle() }
            Button("Open Full Dashboard") { AppRoute.shared.requestMonitoring() }
            Button("Settings") { AppRoute.shared.request(.settings) }
            Divider()
            Menu("Appearance") {
                ForEach(AppAppearance.allCases) { option in
                    Button {
                        appearance = option.rawValue
                    } label: {
                        Label(option.label, systemImage: appearance == option.rawValue ? "checkmark" : option.symbol)
                    }
                }
            }
            Divider()
            Button("Quit MY MACHINE") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 14, height: 14)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(GlassyIconButtonStyle())
        .fixedSize()
        .help("More options")
        .accessibilityLabel("More options")
    }

    private var selectedTimelineDisplayMode: TimelineDisplayMode {
        TimelineDisplayMode(rawValue: timelineDisplayMode) ?? .precise
    }

    private var emptyStateSymbol: String {
        switch model.collectionState {
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "clock"
        }
    }

    private var emptyStateTitle: String {
        if model.menuBarIsRefreshing { return "Preparing \(menuBarRangeTitle.lowercased())" }
        switch model.collectionState {
        case .paused: return "Monitoring is paused"
        case .failed: return "Recent history is unavailable"
        default: return "No readings in \(menuBarRangeTitle.lowercased()) yet"
        }
    }

    private var emptyStateDetail: String {
        if let message = model.menuBarRefreshMessage { return message }
        switch model.collectionState {
        case .paused:
            return "Nothing new is being recorded. Resume when you want the timeline to continue."
        case .failed:
            return "MY MACHINE could not prepare recent monitoring. Refresh once; reopen it if this continues."
        default:
            return "MY MACHINE will fill this view automatically as it observes the Mac."
        }
    }
}

/// `MenuBarExtra` does not expose an `isPresented` binding. This lightweight
/// bridge observes only its own window so every genuine reopening requests a
/// fresh cache without holding up presentation.
private struct MenuBarWindowPresentationObserver: NSViewRepresentable {
    let didOpen: () -> Void

    func makeNSView(context: Context) -> PresentationProbeView {
        PresentationProbeView(didOpen: didOpen)
    }

    func updateNSView(_ nsView: PresentationProbeView, context: Context) {
        nsView.didOpen = didOpen
    }

    static func dismantleNSView(_ nsView: PresentationProbeView, coordinator: ()) {
        nsView.stopObserving()
    }
}

private final class PresentationProbeView: NSView {
    var didOpen: () -> Void

    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var presentationReported = false
    private var deferredCloseCheck: DispatchWorkItem?
    private var deferredPositioning: DispatchWorkItem?
    private var deferredVisibilityRecovery: DispatchWorkItem?

    init(didOpen: @escaping () -> Void) {
        self.didOpen = didOpen
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observedWindow else { return }
        stopObserving()
        guard let window else { return }
        observedWindow = window
        concealWindowForAnchoredPlacement(window)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.deferredCloseCheck?.cancel()
            self?.reportOpeningIfNeeded()
        })
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.checkForClosureShortly()
        })
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updatePresentationState()
        })
        observers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.restorePresentationAnchor()
        })

        DispatchQueue.main.async { [weak self] in
            self?.reportOpeningIfNeeded()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func stopObserving() {
        if let observedWindow {
            MenuBarPanelAnchorLease.shared.releaseSoon(afterClosing: observedWindow)
        }
        deferredCloseCheck?.cancel()
        deferredCloseCheck = nil
        deferredPositioning?.cancel()
        deferredPositioning = nil
        deferredVisibilityRecovery?.cancel()
        deferredVisibilityRecovery = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        recoverVisibilityIfWindowSurvives(observedWindow)
        observedWindow = nil
        presentationReported = false
    }

    private func reportOpeningIfNeeded() {
        guard let window = observedWindow,
              window.isVisible,
              window.isKeyWindow,
              !presentationReported else { return }
        let anchor = MenuBarPanelAnchorLease.shared.acquire(for: window)
        presentationReported = true
        didOpen()
        positionWindow(window, under: anchor)
    }

    private func restorePresentationAnchor() {
        guard presentationReported,
              let window = observedWindow,
              window.isVisible,
              window.isKeyWindow,
              let anchor = MenuBarPanelAnchorLease.shared.current else { return }
        // Intrinsic-size changes (for example switching Calm/Precise) should
        // stay anchored without replaying the first-presentation conceal/reveal.
        positionWindowImmediately(window, under: anchor)
    }

    private func positionWindow(_ window: NSWindow, under anchor: MenuBarPanelAnchor) {
        deferredPositioning?.cancel()
        concealWindowForAnchoredPlacement(window)
        positionWindowImmediately(window, under: anchor)

        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self,
                  let window,
                  self.observedWindow === window,
                  self.presentationReported,
                  window.isVisible,
                  window.isKeyWindow else { return }

            self.positionWindowImmediately(window, under: anchor)
            window.alphaValue = 1
        }
        deferredPositioning = item
        DispatchQueue.main.async(execute: item)
    }

    private func concealWindowForAnchoredPlacement(_ window: NSWindow) {
        deferredVisibilityRecovery?.cancel()
        deferredVisibilityRecovery = nil
        window.alphaValue = 0
    }

    private func positionWindowImmediately(_ window: NSWindow, under anchor: MenuBarPanelAnchor) {
        let screen = NSScreen.screens.first {
            NSMouseInRect(anchor.pointer, $0.frame, false)
        } ?? window.screen ?? NSScreen.main
        guard let screen else { return }

        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 0)
        var frame = window.frame
        let desiredX = anchor.pointer.x - frame.width / 2
        if frame.width <= bounds.width {
            frame.origin.x = min(max(desiredX, bounds.minX), bounds.maxX - frame.width)
        } else {
            frame.origin.x = bounds.midX - frame.width / 2
        }
        let desiredY = anchor.topEdge - frame.height
        if frame.height <= bounds.height {
            frame.origin.y = min(max(desiredY, bounds.minY), bounds.maxY - frame.height)
        }
        guard abs(frame.origin.x - window.frame.origin.x) >= 0.5
                || abs(frame.origin.y - window.frame.origin.y) >= 0.5 else { return }
        window.setFrameOrigin(frame.origin)
    }

    private func recoverVisibilityIfWindowSurvives(_ window: NSWindow?) {
        guard let window, window.alphaValue < 1 else { return }
        let item = DispatchWorkItem { [weak window] in
            guard let window,
                  window.isVisible,
                  window.isKeyWindow,
                  window.alphaValue < 1 else { return }
            window.alphaValue = 1
        }
        deferredVisibilityRecovery = item
        DispatchQueue.main.async(execute: item)
    }

    private func updatePresentationState() {
        guard let window = observedWindow else { return }
        if !window.isVisible || !window.occlusionState.contains(.visible) {
            deferredPositioning?.cancel()
            deferredPositioning = nil
            window.alphaValue = 1
            presentationReported = false
            MenuBarPanelAnchorLease.shared.releaseSoon(afterClosing: window)
        } else if window.isKeyWindow {
            reportOpeningIfNeeded()
        }
    }

    private func checkForClosureShortly() {
        deferredCloseCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let window = self.observedWindow else { return }
            if !window.isVisible || !window.occlusionState.contains(.visible) {
                self.deferredPositioning?.cancel()
                self.deferredPositioning = nil
                window.alphaValue = 1
                self.presentationReported = false
                MenuBarPanelAnchorLease.shared.releaseSoon(afterClosing: window)
            }
        }
        deferredCloseCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}

/// SwiftUI can replace the private `MenuBarExtra` window when its intrinsic
/// height changes. Treating that replacement as a fresh opening would capture
/// the mode button's pointer position and make the whole panel jump. This short
/// lease carries the genuine opening anchor across an immediate replacement,
/// while clearing it after the panel has actually closed.
private struct MenuBarPanelAnchor {
    let pointer: NSPoint
    let topEdge: CGFloat
}

private final class MenuBarPanelAnchorLease {
    static let shared = MenuBarPanelAnchorLease()

    private(set) var current: MenuBarPanelAnchor?
    private weak var activeWindow: NSWindow?
    private var deferredRelease: DispatchWorkItem?

    private init() {}

    func acquire(for window: NSWindow) -> MenuBarPanelAnchor {
        deferredRelease?.cancel()
        deferredRelease = nil
        activeWindow = window
        if let current { return current }

        let anchor = MenuBarPanelAnchor(
            pointer: NSEvent.mouseLocation,
            topEdge: window.frame.maxY
        )
        current = anchor
        return anchor
    }

    func releaseSoon(afterClosing window: NSWindow) {
        deferredRelease?.cancel()
        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self else { return }
            if let activeWindow = self.activeWindow,
               activeWindow !== window,
               activeWindow.isVisible {
                return
            }
            self.activeWindow = nil
            self.current = nil
            self.deferredRelease = nil
        }
        deferredRelease = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }
}
