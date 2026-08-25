import AppKit
import DailyMacCore
import SwiftUI

/// The dedicated large-format surface. Opening this scene enters native macOS
/// full screen immediately; leaving full screen closes the scene again.
struct ExpandedMonitoringView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var fullscreenController = FullscreenWindowController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let snapshot = model.monitoringSnapshot, snapshot.sampleCount > 0 {
                    dashboard(snapshot)
                } else {
                    preparingState
                }
            }

            FullscreenWindowBridge(controller: fullscreenController)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .preferredColorScheme(.dark)
        .task { model.refreshMonitoringIfNeeded() }
    }

    private func dashboard(_ snapshot: MonitoringSnapshot) -> some View {
        GeometryReader { geometry in
            let layout = DashboardLayout(size: geometry.size)

            VStack(alignment: .leading, spacing: 0) {
                header(layout: layout)

                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: layout.contentSpacing) {
                    MonitoringTimelineView(
                        snapshot: snapshot,
                        samples: model.monitoringSamples,
                        backgroundPoints: model.monitoringBackgroundPoints,
                        events: model.monitoringEvents,
                        presentation: layout.timelinePresentation,
                        expandedProcessorHeight: layout.expandedProcessorHeight
                    )
                    .equatable()
                    .layoutPriority(1)

                    Rectangle()
                        .fill(Color.white.opacity(0.09))
                        .frame(height: 1)

                    NetworkThroughputGraph(
                        samples: model.monitoringSamples,
                        interval: snapshot.interval,
                        presentation: layout.networkPresentation
                    )
                    .equatable()
                    .frame(height: layout.networkHeight)

                    if layout.showsFooter {
                        footer
                    }
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, layout.verticalPadding)
                .padding(.bottom, layout.verticalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func header(layout: DashboardLayout) -> some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("MY MACHINE")
                    .font(.system(size: layout.isCompact ? 22 : 26, weight: .semibold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(Color.white.opacity(0.96))

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusMessage)
                    Text("·")
                    Text(rangeDescription)
                    if let dataThrough = model.monitoringDataThrough {
                        Text("·")
                        Text("updated \(dataThrough.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(layout.isCompact ? .caption : .subheadline)
                .foregroundStyle(Color.white.opacity(0.58))
                .lineLimit(1)
            }

            Spacer(minLength: 24)

            if layout.showsActiveSummary {
                ActiveUseSummaryLabel(duration: model.todayReport?.activeDuration)
                    .foregroundStyle(Color.white.opacity(0.72))
            }

            Picker("Time range", selection: Binding(
                get: { model.monitoringRange },
                set: { model.selectMonitoringRange($0) }
            )) {
                Text("1 hr").tag(MonitoringRange.oneHour)
                Text("6 hr").tag(MonitoringRange.sixHours)
                Text("24 hr").tag(MonitoringRange.twentyFourHours)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: layout.isCompact ? 210 : 250)
            .controlSize(layout.isCompact ? .regular : .large)

            Button {
                model.refreshNow()
            } label: {
                if model.monitoringIsRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .buttonStyle(DashboardIconButtonStyle())
            .help("Refresh monitoring")
            .accessibilityLabel("Refresh monitoring")
            .disabled(model.monitoringIsRefreshing)

            Button {
                fullscreenController.exitAndClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(DashboardIconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Close full-screen dashboard")
            .accessibilityLabel("Close full-screen dashboard")
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, layout.headerVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var preparingState: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Preparing your machine history")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.94))
            Text("The dashboard will appear as soon as a complete reading is ready.")
                .font(.body)
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
            Text("Local only")
            Text("·")
            Text("No destinations, content, or screen activity are recorded")
            Spacer()
            Text("Esc to close")
        }
        .font(.caption)
        .foregroundStyle(Color.white.opacity(0.42))
        .frame(height: 18)
    }

    private var rangeDescription: String {
        switch model.monitoringRange {
        case .oneHour: return "last hour"
        case .sixHours: return "last 6 hours"
        case .twentyFourHours: return "last 24 hours"
        }
    }

    private var latestSample: SystemSample? {
        model.monitoringSamples.last
    }

    private var statusColor: Color {
        guard let latestSample else { return Color.white.opacity(0.42) }
        let demand = max(latestSample.cpuPercent, latestSample.gpuPercent ?? 0)
        if latestSample.thermalLevel == .serious
            || latestSample.thermalLevel == .critical
            || demand >= 90 {
            return .red
        }
        return .green
    }

    private var statusMessage: String {
        guard let latest = latestSample else { return "Collecting current status" }
        if let dataThrough = model.monitoringDataThrough,
           Date().timeIntervalSince(dataThrough) > max(150, latest.samplingInterval * 3) {
            return "History is paused while the Mac is asleep or unrecorded"
        }

        let demand = max(latest.cpuPercent, latest.gpuPercent ?? 0)
        if latest.thermalLevel == .critical || latest.thermalLevel == .serious {
            return "Heat may be reducing performance now"
        }
        if latest.memoryPressure == .high {
            return "Memory demand may make switching feel slower"
        }
        if demand >= 90 {
            return "Working near capacity; useful work can continue"
        }
        if demand >= 60 {
            return "Working hard, with normal active-work headroom"
        }
        return "Comfortable headroom for active work"
    }
}

private struct DashboardLayout {
    let isCompact: Bool
    let horizontalPadding: CGFloat
    let headerVerticalPadding: CGFloat
    let verticalPadding: CGFloat
    let contentSpacing: CGFloat
    let timelinePresentation: TimelinePresentation
    let expandedProcessorHeight: CGFloat?
    let networkPresentation: NetworkThroughputGraph.Presentation
    let networkHeight: CGFloat
    let showsFooter: Bool
    let showsActiveSummary: Bool

    init(size: CGSize) {
        // The expanded timeline has a deliberately generous minimum processor
        // plot. On shorter MacBook panels the standard timeline preserves every
        // lane without clipping or requiring a scroll view.
        isCompact = size.height < 1_080 || size.width < 1_280
        horizontalPadding = isCompact ? 24 : 38
        headerVerticalPadding = isCompact ? 8 : 14
        verticalPadding = isCompact ? 8 : 18
        contentSpacing = isCompact ? 8 : 18
        timelinePresentation = isCompact ? .full : .expanded
        expandedProcessorHeight = isCompact ? nil : min(520, max(320, size.height - 760))
        networkPresentation = .expanded
        networkHeight = isCompact ? 178 : 190
        showsFooter = size.height >= 860
        showsActiveSummary = size.width >= 1_080
    }
}

private struct DashboardIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.58 : 0.86))
            .frame(width: 38, height: 38)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08), in: Circle())
            .contentShape(Circle())
    }
}

/// Gives SwiftUI's separate dashboard scene a direct native full-screen entry.
/// The bridge also closes the scene after the user leaves full screen so it never
/// lingers as a conventional black window.
private struct FullscreenWindowBridge: NSViewRepresentable {
    @ObservedObject var controller: FullscreenWindowController

    func makeNSView(context: Context) -> FullscreenProbeView {
        FullscreenProbeView(controller: controller)
    }

    func updateNSView(_ nsView: FullscreenProbeView, context: Context) {
        nsView.controller = controller
        nsView.prepareVisibleWindow()
    }

    static func dismantleNSView(_ nsView: FullscreenProbeView, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
private final class FullscreenWindowController: ObservableObject {
    private enum Phase {
        case idle
        case preparing
        case entering
        case fullScreen
        case exiting
        case closed
    }

    private weak var attachedWindow: NSWindow?
    private var phase: Phase = .idle
    private var observers: [NSObjectProtocol] = []
    private var closeAfterEntry = false

    func prepare(_ window: NSWindow, allowHiddenWindow: Bool) {
        if attachedWindow === window,
           phase != .idle,
           phase != .closed {
            return
        }
        guard allowHiddenWindow || window.isVisible else { return }

        removeLifecycleObservers()
        attachedWindow = window
        phase = .preparing
        closeAfterEntry = false
        configure(window)
        observeLifecycle(of: window)

        // Keep the ordinary scene invisible. It becomes opaque as the native
        // full-screen transition begins, so no titled or light window flashes.
        window.alphaValue = 0
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.attachedWindow === window else { return }
            self.enterFullScreen(window)
        }
    }

    func exitAndClose() {
        guard let window = attachedWindow else { return }
        switch phase {
        case .fullScreen:
            phase = .exiting
            window.toggleFullScreen(nil)
        case .entering, .preparing:
            closeAfterEntry = true
        case .idle, .closed:
            window.close()
        case .exiting:
            break
        }
    }

    private func configure(_ window: NSWindow) {
        window.backgroundColor = .black
        window.isOpaque = true
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.collectionBehavior.formUnion([.fullScreenPrimary, .managed])
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func enterFullScreen(_ window: NSWindow) {
        guard phase == .preparing else { return }
        if window.styleMask.contains(.fullScreen) {
            phase = .fullScreen
            window.alphaValue = 1
            return
        }

        phase = .entering
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)

        // A failed transition must not leave an invisible process-owned window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak window] in
            guard let self, let window, self.attachedWindow === window,
                  self.phase == .entering else { return }
            window.alphaValue = 1
            if !window.styleMask.contains(.fullScreen) {
                self.phase = .idle
            }
        }
    }

    private func observeLifecycle(of window: NSWindow) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, self.attachedWindow === window else { return }
                self.phase = .entering
                window.alphaValue = 1
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, self.attachedWindow === window else { return }
                self.phase = .fullScreen
                window.alphaValue = 1
                if self.closeAfterEntry {
                    self.closeAfterEntry = false
                    self.phase = .exiting
                    window.toggleFullScreen(nil)
                }
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, self.attachedWindow === window else { return }
                self.phase = .exiting
                window.alphaValue = 0
                DispatchQueue.main.async { [weak window] in window?.close() }
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, self.attachedWindow === window else { return }
                window.alphaValue = 0
                self.phase = .closed
                self.attachedWindow = nil
                self.removeLifecycleObservers()
            }
        })
    }

    private func removeLifecycleObservers() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

@MainActor
private final class FullscreenProbeView: NSView {
    var controller: FullscreenWindowController
    private weak var observedWindow: NSWindow?
    private var activationObserver: NSObjectProtocol?

    init(controller: FullscreenWindowController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeActivation()
        guard let window else { return }
        controller.prepare(window, allowHiddenWindow: true)
    }

    func prepareVisibleWindow() {
        guard let window, window.isVisible else { return }
        controller.prepare(window, allowHiddenWindow: false)
    }

    private func observeActivation() {
        guard observedWindow !== window else { return }
        stopObserving()
        observedWindow = window
        guard let window else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.controller.prepare(window, allowHiddenWindow: false)
            }
        }
    }

    func stopObserving() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        observedWindow = nil
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
}
