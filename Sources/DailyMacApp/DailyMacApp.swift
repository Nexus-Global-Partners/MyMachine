import AppKit
import DailyMacCore
import SwiftUI

@main
struct DailyMacApp: App {
    @NSApplicationDelegateAdaptor(DailyMacApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        Window("MY MACHINE", id: "main") {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(AppAppearance.resolved(from: appearance).colorScheme)
                .frame(minWidth: 820, minHeight: 620)
        }
        .defaultSize(width: 980, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Monitoring") {
                Button("Open Monitoring") { AppRoute.shared.requestMonitoring() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                if model.collectionState == .paused {
                    Button("Resume Monitoring") { model.startMonitoring() }
                } else {
                    Button("Pause Monitoring") { model.pauseIndefinitely() }
                }
                Button("Refresh Report") { model.refreshNow() }
            }
        }

        Window("Expanded Monitoring", id: "expanded-monitoring") {
            ExpandedMonitoringView()
                .environmentObject(model)
                .preferredColorScheme(AppAppearance.resolved(from: appearance).colorScheme)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1280, height: 860)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarMonitoringView()
                .environmentObject(model)
                .preferredColorScheme(AppAppearance.resolved(from: appearance).colorScheme)
        } label: {
            DailyMacMenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct DailyMacMenuBarLabel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var route = AppRoute.shared

    var body: some View {
        Image(nsImage: MyMachineVisualIdentity.menuBarIcon)
            .accessibilityLabel("MY MACHINE — \(model.collectionState.label)")
            .task { openPendingRoute() }
            .onChange(of: route.monitoringRequestGeneration) {
                openPendingRoute()
            }
    }

    private func openPendingRoute() {
        guard route.consumeMonitoringRequest() else { return }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum MyMachineVisualIdentity {
    static let menuBarIcon: NSImage = {
        let image: NSImage
        if let url = Bundle.main.url(forResource: "MyMachineMenuIcon", withExtension: "png"),
           let bundled = NSImage(contentsOf: url) {
            image = bundled
        } else {
            image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "MY MACHINE")
                ?? NSImage(size: NSSize(width: 18, height: 18))
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
