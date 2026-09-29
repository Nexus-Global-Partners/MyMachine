import AppKit
import Combine
import DailyMacCore
import SwiftUI

@main
struct DailyMacApp: App {
    @NSApplicationDelegateAdaptor(MenuBarApplicationDelegate.self) private var appDelegate
    var body: some Scene {
        Settings {
            PreferencesView()
                .environmentObject(appDelegate.model)
                .frame(width: 660, height: 650)
                .alert("MY MACHINE", isPresented: Binding(
                    get: { appDelegate.model.errorMessage != nil },
                    set: { if !$0 { appDelegate.model.errorMessage = nil } }
                )) {
                    Button("OK") { appDelegate.model.errorMessage = nil }
                } message: {
                    Text(appDelegate.model.errorMessage ?? "")
                }
        }
    }
}

/// Own presentation through public AppKit APIs. The popover is anchored to the
/// actual status item. Changing SwiftUI content never replaces its window.
@MainActor
final class MenuBarApplicationDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var routeSubscription: AnyCancellable?
    private var stateSubscription: AnyCancellable?
    private var sampleSubscription: AnyCancellable?
    private var recentSamplesSubscription: AnyCancellable?
    private var statusIconTimer: AnyCancellable?
    private var fanIconTimer: AnyCancellable?
    private var fanReadInFlight = false
    private var appearanceSubscription: AnyCancellable?
    private var iconConfigurationSubscription: AnyCancellable?
    private var effectiveAppearanceSubscription: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCoordinator.shared.configureDelegate()
        NSApp.setActivationPolicy(.accessory)
        applyStoredAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: 85)
        statusItem = item
        if let button = item.button {
            button.image = MachineStatusIcon.image(for: .waiting, average: nil)
            button.target = self
            button.action = #selector(toggleMonitoring)
            button.setAccessibilityLabel("MY MACHINE")
            button.toolTip = "MY MACHINE — waiting for a fresh machine reading"
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        // One native owner avoids a retained SwiftUI window override when the
        // preference changes from Dark/Light back to System.
        appearanceSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in
                AppAppearance.resolved(from: UserDefaults.standard.string(forKey: AppAppearance.storageKey) ?? AppAppearance.system.rawValue)
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyStoredAppearance() }
        iconConfigurationSubscription = NotificationCenter.default.publisher(for: MenuBarIconConfiguration.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusIcon() }
        effectiveAppearanceSubscription = NSApp.publisher(for: \.effectiveAppearance, options: [.initial, .new])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.synchronizePopoverAppearance() }

        routeSubscription = AppRoute.shared.$monitoringRequestGeneration
            .dropFirst()
            .sink { [weak self] _ in self?.openPendingRoute() }
        stateSubscription = model.$collectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusIcon()
                self?.refreshFanReadings()
            }
        sampleSubscription = model.$latestSystem
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusIcon() }
        recentSamplesSubscription = model.$recentSystemSamples
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusIcon() }
        // A stopped or delayed sampler must not leave a colored "live" icon.
        statusIconTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshStatusIcon() }
        fanIconTimer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshFanReadings() }
        refreshStatusIcon()
        refreshFanReadings()
        openPendingRoute()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMonitoring()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.menuBarDidClose()
        popover.close()
    }

    func popoverWillShow(_ notification: Notification) {
        model.menuBarDidOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        model.menuBarDidClose()
        // A closed panel should not rebuild graphs for telemetry publications.
        // Keep its cached data in AppModel and release only the presentation.
        popover.contentViewController = nil
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    @objc private func toggleMonitoring() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showMonitoring()
        }
    }

    private func showMonitoring() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        synchronizePopoverAppearance()
        if popover.contentViewController == nil {
            let hosting = NSHostingController(rootView: MenuBarAppearanceContainer(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            popover.contentViewController = hosting
        }
        if let content = popover.contentViewController {
            content.view.layoutSubtreeIfNeeded()
            let fittingSize = content.view.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                popover.contentSize = fittingSize
            }
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openPendingRoute() {
        guard AppRoute.shared.consumeMonitoringRequest() else { return }
        showMonitoring()
    }

    private func applyStoredAppearance() {
        let rawValue = UserDefaults.standard.string(forKey: AppAppearance.storageKey) ?? AppAppearance.system.rawValue
        NSApp.appearance = AppAppearance.resolved(from: rawValue).nativeAppearance
        synchronizePopoverAppearance()
    }

    private func synchronizePopoverAppearance() {
        // NSPopover has its own appearance. Explicitly follow the application's
        // effective value so System works both now and after a live OS change.
        popover.appearance = NSApp.effectiveAppearance
        refreshStatusIcon()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let state: MachineStatusIcon.State
        switch model.collectionState {
        case .monitoring:
            if let signal = MachineStatusSignal.current(
                sample: model.latestSystem,
                recentSamples: model.recentSystemSamples
            ) {
                state = .live(signal)
            } else {
                state = .waiting
            }
        case .starting: state = .waiting
        case .paused: state = .paused
        case .sleeping: state = .asleep
        case .failed: state = .failed
        }
        let average = model.collectionState == .monitoring
            ? MachineDemandAverage.current(
                sample: model.latestSystem,
                recentSamples: model.recentSystemSamples
            )
            : nil
        let isLive: Bool
        if case .live = state { isLive = true } else { isLive = false }
        let fanVisible = model.collectionState == .monitoring
        let freshFans = fanVisible && model.fanReadingsAt.map { Date().timeIntervalSince($0) < 45 } == true
            ? model.fanReadings : nil
        let fanPercent = freshFans?.map(\.percentOfMaximum).max()
        let thermalLevel = isLive ? model.latestSystem?.thermalLevel : nil
        let configuration = MenuBarIconConfiguration.load()
        let icon = MachineStatusIcon.image(
            for: state,
            average: average,
            fanPercent: fanPercent,
            thermalLevel: thermalLevel,
            configuration: configuration
        )
        statusItem?.length = icon.size.width + 4
        button.image = icon
        let averageDescription = average.map { reading in
            "Two-minute average: CPU \(reading.cpuPercent)%, "
                + (reading.gpuPercent.map { "GPU \($0)%" } ?? "GPU unavailable") + ". "
        } ?? ""
        let fanDescription: String
        if let fans = freshFans, !fans.isEmpty {
            fanDescription = fans.map { fan in
                "Fan \(fan.index + 1): \(Int(fan.rpm.rounded())) RPM, \(Int(fan.percentOfMaximum.rounded()))% of reported maximum, \(fan.speedDescription.lowercased())."
            }.joined(separator: " ") + " "
        } else {
            fanDescription = "Fan speed unavailable. "
        }
        let thermalDescription = thermalLevel.map { "macOS thermal pressure: \($0.rawValue). " } ?? "Thermal pressure unavailable. "
        button.setAccessibilityValue(fanDescription + thermalDescription + averageDescription + state.accessibilityValue)
        let instrumentHelp = configuration.displayedInstruments.map { instrument in
            switch instrument {
            case .physical: "Fan speed relative to reported maximum; categorical thermal pressure."
            case .compute: "Two-minute CPU and GPU averages."
            case .state: "Machine health above, four-step effort below."
            }
        }.joined(separator: " ")
        button.toolTip = "MY MACHINE — \(fanDescription)\(thermalDescription)\(averageDescription)\(state.accessibilityValue) Icon order: \(instrumentHelp)"
    }

    private func refreshFanReadings() {
        guard model.collectionState == .monitoring else {
            model.setFanReadings(nil)
            refreshStatusIcon()
            return
        }
        guard !fanReadInFlight else { return }
        fanReadInFlight = true
        Task { @MainActor [weak self] in
            let readings = await Task.detached(priority: .utility) { FanTelemetry.sharedRead() }.value
            guard let self else { return }
            self.fanReadInFlight = false
            guard self.model.collectionState == .monitoring else { return }
            self.model.setFanReadings(readings)
            self.refreshStatusIcon()
        }
    }
}

private struct MenuBarAppearanceContainer: View {
    @ObservedObject var model: AppModel
    var body: some View {
        MenuBarMonitoringView()
            .environmentObject(model)
            .fixedSize(horizontal: true, vertical: true)
    }
}
