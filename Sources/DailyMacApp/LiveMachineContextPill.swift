import AppKit
import DailyMacCore
import SwiftUI

/// A small explanation layer over the graph. CPU capacity is the observed
/// process-family core time divided by the machine's logical-core count; it is
/// never inferred from worker counts or from the person being present.
struct LiveMachineContextPill: View {
    let samples: [SystemSample]
    let appSamples: [AppResourceSample]
    let endingAt: Date
    @State private var showsDetails = false

    private var latest: SystemSample? {
        guard let value = samples.last(where: { $0.duration > 0 }),
              endingAt.timeIntervalSince(value.timestamp) <= max(120, value.samplingInterval * 4) else { return nil }
        return value
    }
    private var attribution: TimelineWorkAttribution? {
        TimelineWorkAttribution.summarize(
            appSamples: appSamples,
            within: DateInterval(start: endingAt.addingTimeInterval(-120), end: endingAt)
        )
    }

    var body: some View {
        if let latest {
            Button { showsDetails.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: attribution?.latestAgentWorkerCount ?? 0 > 0 ? "cpu" : "gearshape.2")
                    Text(pillTitle(latest))
                        .monospacedDigit()
                    Image(systemName: "info.circle").foregroundStyle(.tertiary)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(0.75))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(.thinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.04), radius: 6, y: 1)
            }
            .buttonStyle(.plain)
            .help("What is using the machine? Observed app CPU capacity, memory and heat. Agent apps include their interface and helpers.")
            .accessibilityLabel("Live machine context. \(pillTitle(latest))")
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
                details(latest)
            }
        }
    }

    private func pillTitle(_ sample: SystemSample) -> String {
        if let attribution, attribution.latestAgentWorkerCount > 0,
           let cpu = attribution.averageAgentAppCPUPercent {
            return "Agent apps · \(capacity(cpu)) CPU"
        }
        if let attribution, attribution.backgroundCPUSharePercent >= 40 {
            return "Background · \(capacity(attribution.averageBackgroundCPUPercent)) CPU"
        }
        return "Memory · \(bytes(sample.memoryUsedBytes)) / \(bytes(sample.memoryTotalBytes))"
    }

    private func details(_ sample: SystemSample) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What’s using your Mac").font(.headline)
                Spacer()
                Text("Live · 2 min").font(.caption).foregroundStyle(.secondary)
            }
            if let attribution {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CPU CAPACITY").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    capacityRow("Foreground apps", value: attribution.averageForegroundCPUPercent)
                    capacityRow("Background apps", value: attribution.averageBackgroundCPUPercent)
                    if let agentCPU = attribution.averageAgentAppCPUPercent, attribution.latestAgentWorkerCount > 0 {
                        Divider().opacity(0.5)
                        capacityRow("Includes agent apps", value: agentCPU)
                        Text("\(attribution.latestAgentWorkerCount) detected agent workers. Their app families include the app interface and ordinary helpers; this is not an agents-only CPU measurement.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("100% means all \(ProcessInfo.processInfo.processorCount) logical cores. These are observed app families; system and unassigned work are not included. Foreground does not mean human-caused.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !attribution.topAppContributors.isEmpty {
                        Divider().opacity(0.5)
                        Text("LEADING APPS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(attribution.topAppContributors) { contributor in
                            capacityRow(contributor.name, value: contributor.averageCPUPercent)
                        }
                    }
                }
            } else {
                Text("App CPU attribution is still collecting. Hardware readings below remain available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider().opacity(0.5)
            HStack(alignment: .top, spacing: 20) {
                hardware("Memory", value: "\(bytes(sample.memoryUsedBytes)) / \(bytes(sample.memoryTotalBytes))")
                hardware("Swap", value: bytes(sample.swapUsedBytes))
                hardware("Heat", value: heatLabel(sample.thermalLevel))
            }
            if let performance = sample.performanceCorePercent, let efficiency = sample.efficiencyCorePercent {
                Text("Performance cores \(Int(performance.rounded()))% · Efficiency cores \(Int(efficiency.rounded()))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(sample.isIdle
                 ? "You’re away; the Mac is awake. Background work can continue."
                 : "You’re using the Mac. Agents and background work can run at the same time.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 350)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func capacityRow(_ label: String, value: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(capacity(value)).monospacedDigit().fontWeight(.semibold)
        }.font(.caption)
    }

    private func hardware(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
    }

    private func capacity(_ perCorePercent: Double) -> String {
        let percent = max(0, min(100, perCorePercent / Double(max(1, ProcessInfo.processInfo.processorCount))))
        return percent > 0 && percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func heatLabel(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: return "Comfortable"
        case .fair: return "Managed"
        case .serious, .critical: return "Under pressure"
        case .unknown: return "Unavailable"
        }
    }
}
