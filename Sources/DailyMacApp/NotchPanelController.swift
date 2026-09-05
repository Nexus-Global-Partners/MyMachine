import AppKit
import Combine
import QuartzCore
import DailyMacCore
import SwiftUI

@MainActor
final class NotchPanelController: NSObject, NSWindowDelegate {
    static let shared = NotchPanelController()
    static let hoverKey = "notchHoverEnabled"
    private weak var model: AppModel?
    private var panel: DashboardPanel?
    private var interaction = NotchInteraction()
    private var displayedPhase = NotchInteraction.Phase.hidden
    private var screen: NSScreen?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observations: [AnyCancellable] = []
    private var deadline: DispatchWorkItem?
    private var animationGeneration = 0
    private var suspended = false

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        UserDefaults.standard.register(defaults: [Self.hoverKey: true])
        let center = NotificationCenter.default
        center.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateMonitoring() }.store(in: &observations)
        center.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.dismissImmediately(); self?.updateMonitoring()
            }.store(in: &observations)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.dismissImmediately()
            }.store(in: &observations)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.suspended = true; self?.dismissImmediately(); self?.updateMonitoring()
            }.store(in: &observations)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.suspended = false; self?.updateMonitoring()
            }.store(in: &observations)
        }
        updateMonitoring()
    }

    func toggle() {
        guard model != nil, !suspended else { return }
        if interaction.phase == .expanded { dismiss(); return }
        screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        expand()
    }

    private var hoverEnabled: Bool { UserDefaults.standard.bool(forKey: Self.hoverKey) }
    private var hoverAllowed: Bool {
        let options = NSApp.currentSystemPresentationOptions
        return hoverEnabled && !suspended && !options.contains(.fullScreen)
            && !options.contains(.hideMenuBar) && !options.contains(.autoHideMenuBar)
    }
    private func activation(on screen: NSScreen) -> CGRect? {
        NotchGeometry.activation(screen: screen.frame, topInset: screen.safeAreaInsets.top,
                                 left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
    }

    private func updateMonitoring() {
        if !hoverEnabled && interaction.phase != .expanded { dismissImmediately(refreshObservation: false) }
        let needed = !suspended && ((hoverEnabled && NSScreen.screens.contains { activation(on: $0) != nil }) || interaction.phase == .expanded)
        if !needed {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil; localMonitor = nil
            deadline?.cancel(); deadline = nil
            return
        }
        guard globalMonitor == nil else { return }
        // Mouse events only, transiently used for presentation. No event tap,
        // global keyboard listener, input log, or additional permission request.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard !suspended else { return }
        let point = NSEvent.mouseLocation
        if event.type != .mouseMoved {
            if interaction.phase == .expanded {
                if panel?.frame.contains(point) != true { dismiss() }
            } else if event.type == .leftMouseDown, hoverAllowed,
                      let target = NSScreen.screens.first(where: { activation(on: $0)?.contains(point) == true }) {
                screen = target
                expand()
            }
            return
        }
        evaluatePointer()
    }

    private func evaluatePointer() {
        deadline?.cancel(); deadline = nil
        guard interaction.phase != .expanded else { return }
        guard hoverAllowed, NSEvent.pressedMouseButtons == 0 else {
            if interaction.phase != .hidden || interaction.needsDeadline { dismiss() }
            return
        }
        let point = NSEvent.mouseLocation
        let target = NSScreen.screens.first { activation(on: $0)?.contains(point) == true }
        if interaction.phase == .hidden, let target {
            if screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber != target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                interaction = NotchInteraction()
            }
            screen = target
        }
        let inActivation = screen.flatMap { activation(on: $0) }?.contains(point) == true
        let inSurface = interaction.phase == .preview && panel?.frame.contains(point) == true
        interaction.pointer(at: ProcessInfo.processInfo.systemUptime, inActivation: inActivation, inSurface: inSurface)
        render()
        if interaction.needsDeadline {
            let item = DispatchWorkItem { [weak self] in self?.evaluatePointer() }
            deadline = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }
    }

    private func expand() {
        deadline?.cancel(); deadline = nil
        interaction.expand()
        render()
        updateMonitoring()
    }

    func dismiss() {
        deadline?.cancel(); deadline = nil
        interaction.dismiss()
        render()
        updateMonitoring()
    }

    private func dismissImmediately(refreshObservation: Bool = true) {
        deadline?.cancel(); deadline = nil
        interaction.dismiss()
        displayedPhase = .hidden
        animationGeneration += 1
        panel?.orderOut(nil)
        if refreshObservation { updateMonitoring() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if interaction.phase == .expanded { dismiss() }
    }

    private func render() {
        guard displayedPhase != interaction.phase, let model, let screen else { return }
        let wasHidden = displayedPhase == .hidden
        displayedPhase = interaction.phase
        animationGeneration += 1
        let generation = animationGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if interaction.phase == .hidden {
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 0
                if !reduceMotion {
                    var frame = panel.frame
                    frame.origin.y = frame.maxY - 1; frame.size.height = 1
                    panel.animator().setFrame(frame, display: true)
                }
            } completionHandler: { [weak self] in
                guard self?.animationGeneration == generation else { return }
                self?.panel?.orderOut(nil)
            }
            return
        }
        let expanded = interaction.phase == .expanded
        let window: DashboardPanel
        if let panel { window = panel } else {
            window = DashboardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .darkAqua)
            window.hasShadow = true
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.isMovable = false
            window.title = "MY MACHINE dashboard"
            window.delegate = self
            window.onDismiss = { [weak self] in self?.dismiss() }
            panel = window
        }
        window.acceptsFocus = expanded
        let view = NotchDashboardView(model: model, expanded: expanded,
                                      open: { [weak self] in self?.expand() },
                                      close: { [weak self] in self?.dismiss() },
                                      navigate: { [weak self] destination in
                                          self?.dismissImmediately()
                                          AppRoute.shared.request(destination)
                                      })
        window.contentView = DashboardHostingView(rootView: view)
        let destination = NotchGeometry.panel(screen: screen.frame, visible: screen.visibleFrame,
                                             activation: activation(on: screen),
                                             size: expanded ? CGSize(width: 460, height: 440) : CGSize(width: 280, height: 64))
        if wasHidden {
            var initial = destination
            if !reduceMotion { initial.origin.y = initial.maxY - 1; initial.size.height = 1 }
            window.setFrame(initial, display: false)
            window.alphaValue = 0
        }
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : (expanded ? 0.3 : 0.18)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(destination, display: true)
            window.animator().alphaValue = 1
        }
        if expanded { window.makeKey() }
    }
}

private final class DashboardPanel: NSPanel {
    var acceptsFocus = false
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { acceptsFocus }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

private final class DashboardHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
