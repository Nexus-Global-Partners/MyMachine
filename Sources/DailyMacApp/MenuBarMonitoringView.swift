import AppKit
import DailyMacCore
import SwiftUI

struct MenuBarMonitoringView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var route = AppRoute.shared
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

            Divider()
            footer
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
                HStack(spacing: 5) {
                    Text(menuBarRangeTitle)
                    Text("·")
                    if let dataThrough = model.menuBarMonitoringContent?.dataThrough {
                        Text("Data through \(dataThrough.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Waiting for the first reading")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    if model.menuBarIsRefreshing {
                        Text("Updating")
                            .foregroundStyle(.secondary)
                    } else if model.menuBarRefreshMessage != nil {
                        Label("Cached", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                            .help(model.menuBarRefreshMessage ?? "")
                    }
                    ActiveUseSummaryLabel(duration: model.todayReport?.activeDuration)
                }
                .font(.caption)

                HStack(alignment: .center, spacing: 9) {
                    MonitoringRangePickerControl(
                        selection: model.menuBarMonitoringRange,
                        itemWidth: 34,
                        onSelect: model.selectMenuBarMonitoringRange
                    )
                    .help("Choose how much history to show")

                    DiagnosisActionButton()

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
                }
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

    private var footer: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.collectionState.label)
                    .font(.caption.weight(.medium))
                Text("Local only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            TimelineDisplayModeControl()

            Button {
                route.requestMonitoring()
                openWindow(id: "main")
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.borderless)
            .help("Open monitoring window")
            .accessibilityLabel("Open monitoring window")

            Button("Open Full-Screen Dashboard") {
                openWindow(id: "expanded-monitoring")
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.bordered)

            Menu {
                if model.collectionState == .paused {
                    Button("Resume Monitoring") { model.startMonitoring() }
                } else {
                    Button("Pause for One Hour") { model.pauseForOneHour() }
                    Button("Pause Until Tomorrow") { model.pauseUntilTomorrow() }
                    Button("Pause Until I Resume") { model.pauseIndefinitely() }
                }
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
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More options")
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch model.collectionState {
        case .monitoring: return .accentColor
        case .failed: return .red
        default: return .secondary
        }
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
        if model.menuBarIsRefreshing { return "Preparing the last hour" }
        switch model.collectionState {
        case .paused: return "Monitoring is paused"
        case .failed: return "Recent history is unavailable"
        default: return "No readings in the last hour yet"
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

        DispatchQueue.main.async { [weak self] in
            self?.reportOpeningIfNeeded()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func stopObserving() {
        deferredCloseCheck?.cancel()
        deferredCloseCheck = nil
        deferredPositioning?.cancel()
        deferredPositioning = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        observedWindow = nil
        presentationReported = false
    }

    private func reportOpeningIfNeeded() {
        guard let window = observedWindow,
              window.isVisible,
              window.isKeyWindow,
              !presentationReported else { return }
        let anchor = NSEvent.mouseLocation
        presentationReported = true
        didOpen()
        positionWindow(window, under: anchor)
    }

    private func positionWindow(_ window: NSWindow, under anchor: NSPoint) {
        deferredPositioning?.cancel()
        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self,
                  let window,
                  self.observedWindow === window,
                  self.presentationReported,
                  window.isVisible,
                  window.isKeyWindow else { return }

            let screen = NSScreen.screens.first {
                NSMouseInRect(anchor, $0.frame, false)
            } ?? window.screen ?? NSScreen.main
            guard let screen else { return }

            let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 0)
            var frame = window.frame
            let desiredX = anchor.x - frame.width / 2
            if frame.width <= bounds.width {
                frame.origin.x = min(max(desiredX, bounds.minX), bounds.maxX - frame.width)
            } else {
                frame.origin.x = bounds.midX - frame.width / 2
            }
            guard abs(frame.origin.x - window.frame.origin.x) >= 0.5 else { return }
            window.setFrameOrigin(frame.origin)
        }
        deferredPositioning = item
        DispatchQueue.main.async(execute: item)
    }

    private func updatePresentationState() {
        guard let window = observedWindow else { return }
        if !window.isVisible || !window.occlusionState.contains(.visible) {
            deferredPositioning?.cancel()
            deferredPositioning = nil
            presentationReported = false
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
                self.presentationReported = false
            }
        }
        deferredCloseCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}
