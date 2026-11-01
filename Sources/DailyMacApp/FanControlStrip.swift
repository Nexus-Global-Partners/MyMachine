import DailyMacCore
import SwiftUI

/// One quiet row. Moving the slider requests a target; the Fan card remains the
/// independently measured RPM percentage, including while the fan spins up.
struct FanControlStrip: View {
    @ObservedObject private var control = FanControlClient.shared
    @State private var target = 50.0
    @State private var dragging = false
    @State private var keyboardCommit: Task<Void, Never>?
    @State private var showsError = false
    @State private var pendingAction = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "fan").font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            switch control.availability {
            case .checking:
                Text("Checking fan control…").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .unsupported(let reason):
                Text("Fan control unavailable").foregroundStyle(.secondary)
                    .help(reason)
                Spacer(minLength: 0)
            case .notEnabled, .needsApproval:
                Button(control.availability == .needsApproval ? "Set up fan control…" : "Enable fan control…") {
                    perform(control.enable)
                }
                    .buttonStyle(.plain)
                    .help(control.availability == .needsApproval
                        ? "Complete or update the fan-control installer in Terminal. Once approved, the controls connect automatically. Monitoring keeps working."
                        : "Optional fan control requires macOS administrator approval. Monitoring does not.")
                Spacer(minLength: 0)
            case .enabled:
                let minimum = control.snapshot?.minimumPercent ?? 100
                Slider(value: Binding(get: { target }, set: { newValue in
                    target = newValue
                    if !dragging { scheduleKeyboardCommit() }
                }), in: min(99, minimum)...100, step: 1) { editing in
                    dragging = editing
                    keyboardCommit?.cancel()
                    if !editing { perform { control.setPercent(target) } }
                }
                .controlSize(.mini)
                .tint(MachinePalette.human)
                .disabled(control.snapshot?.manualControlAvailable != true || minimum >= 100)
                .accessibilityLabel("Fan target, all fans")
                .accessibilityValue("\(Int(target)) percent of maximum")
                .help("Controls the physical fans now, regardless of graph date. Sets every fan to this share of its own maximum, within its reported operating range. In Live mode, the Fan card shows measured speed. macOS thermal control takes priority.")
                Text(dragging || control.snapshot?.ownsManualControl == true ? "\(Int(target))%" : "—")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                Button("Auto") { perform(control.returnToAutomatic) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(control.snapshot?.ownsManualControl == true ? Color.primary : .secondary)
                    .disabled(control.snapshot?.ownsManualControl != true)
                    .help("Return fan speed to macOS. Auto does not mean fan off.")
            }
            if control.isBusy { ProgressView().controlSize(.mini).frame(width: 12) }
        }
        .font(.system(size: 10, weight: .medium))
        .frame(height: 24)
        .disabled(control.isBusy)
        .onAppear { control.refresh(); synchronizeTarget() }
        .onChange(of: control.snapshot) { _, _ in if !dragging { synchronizeTarget() } }
        .onChange(of: control.isBusy) { _, busy in
            if !busy && pendingAction {
                showsError = control.errorMessage != nil
                pendingAction = false
                synchronizeTarget()
            }
        }
        .onDisappear { keyboardCommit?.cancel() }
        .alert("Fan control", isPresented: $showsError) { Button("OK", role: .cancel) { } }
            message: { Text(control.errorMessage ?? "Fan control is unavailable.") }
    }

    private func synchronizeTarget() {
        guard let snapshot = control.snapshot else { return }
        let measured = snapshot.fans.map { $0.actualRPM / $0.maximumRPM * 100 }.max() ?? snapshot.minimumPercent
        target = min(100, max(snapshot.minimumPercent, snapshot.requestedPercent ?? measured)).rounded()
    }

    private func perform(_ action: () -> Void) {
        pendingAction = true
        action()
        if !control.isBusy {
            showsError = control.errorMessage != nil
            pendingAction = false
        }
    }

    private func scheduleKeyboardCommit() {
        keyboardCommit?.cancel()
        keyboardCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !dragging else { return }
            perform { control.setPercent(target) }
        }
    }
}

struct FanControlSettingsSection: View {
    @ObservedObject private var control = FanControlClient.shared
    @State private var pendingRemoval = false
    @State private var showsRemovalError = false
    var body: some View {
        Section("Fan control") {
            FanControlStrip()
            Text("Optional manual cooling for all physical fans. Auto returns control to macOS; it never forces a fan off. Targets stay inside each fan’s reported range. Measured speed may take time to reach a requested target.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Enabling this feature requires macOS approval for a narrowly scoped administrator helper. Manual settings expire if the app disconnects and yield when thermal pressure rises. Core monitoring needs no administrator access.")
                .font(.caption).foregroundStyle(.secondary)
            if control.availability == .enabled || control.availability == .needsApproval {
                Button("Disable fan control and remove helper") {
                    pendingRemoval = true
                    control.disable()
                    if !control.isBusy { finishRemoval() }
                }
                    .disabled(control.isBusy)
            }
        }
        .onChange(of: control.isBusy) { _, busy in
            if !busy && pendingRemoval { finishRemoval() }
        }
        .alert("Fan control", isPresented: $showsRemovalError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(control.errorMessage ?? "Fan control could not be removed.")
        }
    }

    private func finishRemoval() {
        showsRemovalError = control.errorMessage != nil
        pendingRemoval = false
    }
}
