import AppKit
import DailyMacCore
import SwiftUI

extension MachineInstrument {
    var tint: Color {
        switch self {
        case .cpu: MachinePalette.processor
        case .gpu: MachinePalette.graphics
        case .memory: MachinePalette.normal
        case .fan: MachinePalette.human
        }
    }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.3.layers.3d"
        case .memory: "memorychip"
        case .fan: "fan"
        }
    }
    var explanation: String {
        switch self {
        case .cpu: "Processing demand across all CPU cores. A high reading means the Mac is working, not necessarily struggling."
        case .gpu: "Graphics-engine activity reported by macOS. Missing readings are not treated as zero."
        case .memory: "Share of physical memory in use. The pressure label, not fullness alone, tells you whether memory is constrained."
        case .fan: "Measured fan RPM as a share of its hardware maximum. On multi-fan Macs this is the fastest relative fan. This is not power, temperature, or noise."
        }
    }
}

struct InstrumentPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selected: Set<MachineInstrument>
    @Binding var followsRange: Bool

    private var content: MonitoringDisplayState? { model.menuBarMonitoringContent }
    private var liveSample: SystemSample? {
        guard model.collectionState == .monitoring, let sample = model.latestSystem,
              MachineStatusSignal.isFresh(sample) else { return nil }
        return sample
    }
    private var thermal: ThermalLevel {
        followsRange ? (content?.snapshot.thermalPeak ?? .unknown) : (liveSample?.thermalLevel ?? .unknown)
    }
    private var pressure: MemoryPressureLevel? {
        followsRange ? content?.snapshot.peakMemoryPressure : liveSample?.memoryPressure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("My Mac").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                Menu {
                    Button("Live readings") { followsRange = false }
                    Button("Selected period") { followsRange = true }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(followsRange ? Color.secondary : (liveSample == nil ? .gray : MachinePalette.normal))
                            .frame(width: 5, height: 5)
                        Text(followsRange ? "Period" : "Live").font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .padding(.horizontal, 9).frame(height: 25)
                    .background(.quaternary.opacity(0.45), in: Capsule())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Live: current readings. Period: averages and busiest apps for the graph's selected dates.")
                .accessibilityLabel("Instrument readings: \(followsRange ? "selected period" : "live")")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(MachineInstrument.allCases) { metric in card(metric) }
            }
            thermalIndicator
            appList
            Spacer(minLength: 0)
        }
        .frame(width: 214)
    }

    private func value(_ metric: MachineInstrument) -> Double? {
        if followsRange {
            guard let content else { return nil }
            return InstrumentHistory.average(metric, samples: content.samples, in: content.snapshot.interval)
        }
        guard let liveSample else { return nil }
        if metric == .cpu || metric == .gpu {
            let reading = MachineDemandAverage.current(sample: liveSample, recentSamples: model.recentSystemSamples)
            return metric == .cpu ? reading.map { Double($0.cpuPercent) } : reading?.gpuPercent.map(Double.init)
        }
        if metric == .fan, let date = model.fanReadingsAt, Date().timeIntervalSince(date) < 45 {
            return model.fanReadings?.map(\.percentOfMaximum).max()
        }
        return metric.value(in: liveSample)
    }

    private func detail(_ metric: MachineInstrument) -> String {
        guard value(metric) != nil else { return followsRange ? "Not recorded" : "Unavailable" }
        switch metric {
        case .cpu: return followsRange ? "Average demand" : "Processing · 2m"
        case .gpu: return followsRange ? "Average demand" : "Graphics · 2m"
        case .memory:
            switch pressure {
            case .low: return followsRange ? "Pressure normal" : "Normal pressure"
            case .elevated: return followsRange ? "Pressure rose" : "Pressure rising"
            case .high: return "Under pressure"
            case nil: return "Memory in use"
            }
        case .fan:
            if followsRange { return "Average speed" }
            if let fans = model.fanReadings, let fan = fans.max(by: { $0.percentOfMaximum < $1.percentOfMaximum }) {
                return "\(Int(fan.rpm.rounded())) RPM"
            }
            return "Measured speed"
        }
    }

    private func warning(_ metric: MachineInstrument) -> Bool {
        metric == .memory && pressure == .high
            || ((metric == .cpu || metric == .gpu) && (thermal == .serious || thermal == .critical))
    }

    private func card(_ metric: MachineInstrument) -> some View {
        let isSelected = selected.contains(metric)
        let reading = value(metric)
        let alert = warning(metric)
        return Button {
            if isSelected {
                if selected.count > 1 { selected.remove(metric) }
            } else { selected.insert(metric) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Text(metric.title).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                    if metric == .memory && pressure != nil && pressure != .low {
                        Circle().fill(pressure == .high ? MachinePalette.critical : .orange).frame(width: 5, height: 5)
                    }
                }
                .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(reading.map { String(Int($0.rounded())) } ?? "—")
                        .font(.system(size: 27, weight: .medium, design: .rounded))
                    if reading != nil { Text("%").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
                }
                .monospacedDigit().foregroundStyle(isSelected ? metric.tint : Color.primary)
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading).frame(height: 84)
            .background {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.027))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(alert ? MachinePalette.critical.opacity(0.7) : .clear, lineWidth: 0.8)
                    .shadow(color: alert ? MachinePalette.critical.opacity(0.25) : .clear, radius: 5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .help("\(detail(metric)). \(metric.explanation)\n\(followsRange ? "Average over recorded coverage in the selected period." : "Live sensor readings; CPU/GPU are two-minute averages.")\nClick to \(isSelected ? "hide" : "show") on the graph. At least one signal stays visible.")
        .accessibilityLabel("\(metric.title), \(reading.map { "\(Int($0)) percent" } ?? "not available"), \(detail(metric))")
        .accessibilityValue(isSelected ? "Shown in graph" : "Hidden in graph")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var thermalIndicator: some View {
        let stage: Int = switch thermal {
        case .nominal: 1
        case .fair: 2
        case .serious: 3
        case .critical: 4
        case .unknown: 0
        }
        let title: String = switch thermal {
        case .nominal: "Comfortable"
        case .fair: "Warm"
        case .serious: "High"
        case .critical: "Critical"
        case .unknown: "Unavailable"
        }
        let tint: Color = stage >= 4 ? MachinePalette.critical : stage >= 3 ? .orange : stage == 2 ? .yellow : MachinePalette.normal
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(followsRange ? "Peak thermal pressure" : "Thermal pressure")
                Spacer(minLength: 2)
                Text(title).foregroundStyle(stage >= 3 ? tint : .secondary)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    Capsule().fill(index < stage ? tint.opacity(0.8) : Color.primary.opacity(0.055)).frame(height: 6)
                }
            }
        }
        .help("macOS reports four thermal states, not a temperature or a percentage. \(thermal.explanation)")
        .accessibilityElement(children: .ignore).accessibilityLabel("Thermal pressure: \(title)")
    }

    private struct AppRow: Identifiable {
        let id: String
        let name: String
        let bundle: String?
        let percent: Double
    }

    private var apps: [AppRow] {
        if followsRange {
            return content?.appContributors.prefix(5).map {
                AppRow(id: $0.id, name: $0.ownerName, bundle: $0.ownerBundleID, percent: $0.observedCPUSharePercent)
            } ?? []
        }
        guard liveSample != nil else { return [] }
        let fresh = model.liveAppResources.filter {
            $0.cpuMeasurementVersion == 1 && $0.cpuPercent.isFinite && $0.cpuPercent > 0
                && Date().timeIntervalSince($0.timestamp) < 90
        }
        let total = fresh.reduce(0) { $0 + $1.cpuPercent }
        guard total > 0 else { return [] }
        return fresh.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5).map {
            AppRow(id: $0.ownerBundleID ?? $0.ownerName, name: $0.ownerName, bundle: $0.ownerBundleID, percent: $0.cpuPercent / total * 100)
        }
    }

    private func friendlyName(_ name: String) -> String {
        switch name.lowercased() {
        case "windowserver": "Display & windows"
        case "kernel_task": "macOS system"
        case "mds", "mds_stores", "mdworker", "mdworker_shared": "Spotlight indexing"
        case "backupd": "Time Machine"
        case "photoanalysisd", "photolibraryd": "Photos processing"
        default: name
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Using your Mac")
                Spacer()
                Text("CPU share")
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .help("Share of measured application CPU, not total machine capacity. System, protected, and short-lived work may be outside this coverage. Not GPU attribution.")
            if apps.isEmpty {
                Text(followsRange ? "No app attribution recorded" : "Waiting for app readings")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                ForEach(apps) { app in
                    HStack(spacing: 7) {
                        Image(nsImage: ApplicationIconCache.shared.image(bundleIdentifier: app.bundle, ownerName: app.name))
                            .resizable().frame(width: 17, height: 17)
                        Text(friendlyName(app.name)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(Int(app.percent.rounded()))%").font(.system(size: 11, weight: .medium))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(height: 20)
                    .help("\(app.name)\n\(Int(app.percent.rounded()))% of observed app CPU \(followsRange ? "over this period" : "in the latest reading").")
                }
            }
        }
    }
}
