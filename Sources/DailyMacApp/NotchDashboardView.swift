import AppKit
import DailyMacCore
import SwiftUI

struct NotchDashboardView: View {
    @ObservedObject var model: AppModel
    let expanded: Bool
    let open: () -> Void
    let close: () -> Void
    let navigate: (SidebarDestination) -> Void
    @FocusState private var closeFocused: Bool

    private var recentSample: SystemSample? {
        guard model.settings.hasCollectionConsent,
              model.collectionState == .monitoring,
              let sample = model.latestSystem,
              Date().timeIntervalSince(sample.timestamp) < max(120, sample.samplingInterval * 3) else { return nil }
        return sample
    }

    var body: some View {
        Group {
            if expanded { dashboard } else { preview }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.045, green: 0.05, blue: 0.065))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24))
        .overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
    }

    private var preview: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MY MACHINE").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.4)
                    Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("MY MACHINE, \(status). Open dashboard")
        .help("Click to open your dashboard")
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("MY MACHINE", systemImage: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(1.5)
                        .foregroundStyle(.mint)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close dashboard")
                        .help("Close dashboard (Escape)")
                        .focused($closeFocused)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(status).font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if model.settings.hasCollectionConsent {
                    HStack(spacing: 10) {
                        metric("CPU", value: recentSample.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "—", symbol: "cpu")
                        metric("Memory", value: recentSample.map { Formatters.bytes($0.memoryUsedBytes) } ?? "—", symbol: "memorychip")
                        metric("Battery", value: recentSample?.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "—", symbol: "battery.75percent")
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "leaf").foregroundStyle(.mint)
                        Text(insight).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    HStack {
                        Button(model.collectionState == .paused ? "Resume monitoring" : "Pause monitoring") {
                            if model.collectionState == .paused { model.startMonitoring() }
                            else { model.pauseIndefinitely() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.collectionState == .starting)
                        Spacer()
                        Label("Local only", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Records app names, activity counts and machine performance on this Mac. Never records what you type or see on screen. Detailed samples: 3 days; named reports: 30 days; aggregate trends: one year by default.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Start local monitoring") { model.acceptCollectionConsent() }
                        .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                        .disabled(model.collectionState == .starting)
                }
                Divider().overlay(.white.opacity(0.08))
                HStack {
                    Button("Open full dashboard") { navigate(.monitoring) }
                    Spacer()
                    Button { navigate(.history) } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Open history").help("History")
                    Button { navigate(.settings) } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Open settings").help("Settings and privacy")
                }
                .buttonStyle(.borderless).font(.callout)
            }
            .padding(24)
        }
        .onAppear { closeFocused = true }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if !model.settings.hasCollectionConsent { return "Your Mac, your choice" }
        switch model.collectionState {
        case .monitoring: return "Your Mac at a glance"
        case .paused: return "Monitoring paused"
        case .sleeping: return "Resting with your Mac"
        case .starting: return "Getting ready"
        case .failed: return "Monitoring needs attention"
        }
    }
    private var subtitle: String {
        guard model.settings.hasCollectionConsent else { return "Private insights. You decide when to start." }
        if let sample = recentSample { return "Machine readings · \(sample.timestamp.formatted(date: .omitted, time: .shortened))" }
        if model.collectionState == .paused { return "Nothing new is being recorded. Resume whenever you’re ready." }
        return "Current readings are unavailable. Open the full dashboard for details."
    }
    private var insight: String {
        guard let sample = recentSample else { return "Your history stays available in the full dashboard. Missing readings appear as a dash." }
        switch sample.memoryPressure {
        case .high: return "Memory pressure is elevated. Check the full dashboard before deciding which apps to close."
        case .elevated: return "Memory is under some pressure. Your history can help show whether this is a lasting pattern."
        default: return "Memory pressure is low in the latest reading. Use your history to spot longer-term changes."
        }
    }
}
