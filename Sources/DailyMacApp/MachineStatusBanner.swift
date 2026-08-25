import AppKit
import DailyMacCore
import SwiftUI

/// A glanceable current-state summary. Load intensity and machine health are
/// separate so a processor can be near full capacity while the Mac is healthy.
struct MachineStatusBanner: View {
    let snapshot: MonitoringSnapshot
    let samples: [SystemSample]
    let collectionState: CollectionState
    let presentation: TimelinePresentation
    var resumeAction: (() -> Void)?

    private var moment: MachineMoment {
        MachineMoment.make(
            snapshot: snapshot,
            samples: samples,
            collectionState: collectionState,
            now: Date()
        )
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .menuBar ? 8 : 10) {
            HStack(spacing: 10) {
                Text("Current load")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if moment.health != moment.intensity {
                    Text(moment.health)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.92))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .fill(moment.healthTone.color.opacity(colorScheme == .dark ? 0.18 : 0.11))
                        }
                        .overlay {
                            Capsule()
                                .stroke(
                                    moment.healthTone.color.opacity(colorScheme == .dark ? 0.42 : 0.30),
                                    lineWidth: 0.75
                                )
                        }
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 9) {
                if moment.valueText == "—" {
                    Text(moment.intensity)
                        .font(.system(
                            size: presentation == .menuBar ? 30 : 36,
                            weight: .bold,
                            design: .rounded
                        ))
                        .foregroundStyle(moment.intensityTone.color)
                    Spacer(minLength: 10)
                } else {
                    Text(moment.valueText)
                        .font(.system(
                            size: presentation == .menuBar ? 36 : 43,
                            weight: .bold,
                            design: .rounded
                        ))
                        .monospacedDigit()
                        .foregroundStyle(moment.intensityTone.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(moment.metricTitle)
                            .font(presentation == .menuBar ? .subheadline.weight(.semibold) : .headline)
                        if moment.isEstimate {
                            Text("Estimate")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 10)
                    Text(moment.intensity)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.82))
                }
            }

            Text(moment.explanation)
                .font(presentation == .menuBar ? .caption : .callout)
                .foregroundStyle(.primary.opacity(0.79))
                .lineLimit(2)
                .lineSpacing(1)

            if let usage = moment.usagePercent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.primary.opacity(colorScheme == .dark ? 0.11 : 0.07))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [moment.intensityTone.color.opacity(0.72), moment.intensityTone.color],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: geometry.size.width * CGFloat(usage / 100))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }

            if collectionState == .paused, let resumeAction {
                Button("Resume Monitoring", action: resumeAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(presentation == .menuBar ? 13 : 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        moment.intensityTone.color.opacity(colorScheme == .dark ? 0.15 : 0.09),
                        moment.intensityTone.color.opacity(colorScheme == .dark ? 0.045 : 0.025),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 12, y: 4)
        .help("Shows a two-minute whole-Mac CPU average, or the GPU activity estimate when it is both well-covered and clearly higher. CPU and GPU are never combined into a made-up total.")
        .accessibilityElement(children: .combine)
    }
}

private struct MachineMoment {
    let metricTitle: String
    let valueText: String
    let isEstimate: Bool
    let usagePercent: Double?
    let intensity: String
    let health: String
    let explanation: String
    let intensityTone: MachineStatusTone
    let healthTone: MachineStatusTone

    static func make(
        snapshot: MonitoringSnapshot,
        samples: [SystemSample],
        collectionState: CollectionState,
        now: Date
    ) -> MachineMoment {
        switch collectionState {
        case .starting:
            return state(
                value: "—",
                intensity: "Preparing",
                health: "Starting",
                explanation: "MY MACHINE is preparing a current reading. Nothing needs to be set up."
            )
        case .paused:
            return state(
                value: "—",
                intensity: "Paused",
                health: "Paused",
                explanation: "History remains available, but no current machine state is inferred while monitoring is paused."
            )
        case .sleeping:
            return state(
                value: "—",
                intensity: "Asleep",
                health: "Asleep",
                explanation: "Normal applications and agents are paused by macOS until the Mac wakes.",
                intensityTone: .neutral,
                healthTone: .neutral
            )
        case .failed:
            return state(
                value: "—",
                intensity: "Unavailable",
                health: "Needs attention",
                explanation: "Monitoring could not update the current state. Earlier history is still available. Refresh once; reopen MY MACHINE if it continues.",
                intensityTone: .neutral,
                healthTone: .critical
            )
        case .monitoring:
            break
        }

        guard let latest = samples.last(where: { $0.duration > 0 }) else {
            return state(
                value: "—",
                intensity: "Waiting",
                health: "No current status",
                explanation: snapshot.sampleCount == 0
                    ? "Monitoring will show load after the first complete measured interval."
                    : "The timeline keeps earlier history without guessing a current state."
            )
        }

        let age = max(0, now.timeIntervalSince(latest.timestamp))
        let maximumAge = max(120, latest.samplingInterval * 4)
        guard age <= maximumAge, let reading = recentReading(from: samples) else {
            return state(
                metricTitle: "Last reading",
                value: Formatters.duration(age) + " ago",
                intensity: "Cached history",
                health: "Status unavailable",
                explanation: "The current state is not recent enough to interpret. Refreshing keeps the history below and waits for a fresh reading."
            )
        }

        let gpuCoverageIsEnough = reading.gpuCoverage >= 0.60
        let gpuLeads = gpuCoverageIsEnough
            && (reading.gpuAverage ?? 0) > reading.cpuAverage + 5
        let usage = min(100, max(0, gpuLeads ? (reading.gpuAverage ?? 0) : reading.cpuAverage))
        let metricTitle = gpuLeads ? "GPU activity" : "CPU demand"
        let source = gpuLeads ? "Graphics work" : "CPU work"
        let intensity = intensity(for: usage)
        let intensityTone = intensityTone(for: usage)

        if reading.latest.thermalLevel == .critical || reading.latest.thermalLevel == .serious {
            return measured(
                metricTitle: metricTitle,
                usage: usage,
                isEstimate: gpuLeads,
                intensity: intensity,
                health: "Heat limiting speed",
                explanation: "macOS reports serious heat pressure and may reduce speed. Let one heavy task finish before adding more work.",
                intensityTone: intensityTone,
                healthTone: .critical
            )
        }

        if reading.latest.memoryPressure == .high {
            return measured(
                metricTitle: metricTitle,
                usage: usage,
                isEstimate: gpuLeads,
                intensity: intensity,
                health: "Memory constrained",
                explanation: "Memory is tight, so app switching or agent work may feel slower. Finish an unused heavy task only if the slowdown repeats.",
                intensityTone: intensityTone,
                healthTone: .critical
            )
        }

        if reading.latest.memoryPressure == .elevated {
            return measured(
                metricTitle: metricTitle,
                usage: usage,
                isEstimate: gpuLeads,
                intensity: intensity,
                health: "Memory elevated",
                explanation: "\(source) is active and memory is elevated, so switching may feel slower. This is noticeable, not dangerous.",
                intensityTone: intensityTone,
                healthTone: .warning
            )
        }

        switch reading.latest.thermalLevel {
        case .fair:
            return measured(
                metricTitle: metricTitle,
                usage: usage,
                isEstimate: gpuLeads,
                intensity: intensity,
                health: "Warm",
                explanation: "\(source) is creating warmth that macOS is managing. No slowdown is indicated; no action is usually needed.",
                intensityTone: intensityTone,
                healthTone: .warning
            )
        case .unknown:
            return measured(
                metricTitle: metricTitle,
                usage: usage,
                isEstimate: gpuLeads,
                intensity: intensity,
                health: "Heat unavailable",
                explanation: "\(source) is \(intensity.lowercased()). Memory is comfortable, but macOS did not provide a current heat state.",
                intensityTone: intensityTone,
                healthTone: .neutral
            )
        case .nominal:
            break
        case .serious, .critical:
            break
        }

        let isOnBattery = reading.latest.powerSource == .battery
        let explanation: String
        switch usage {
        case 85...:
            explanation = "\(source) is working near full capacity. Memory and heat are comfortable; warmth\(isOnBattery ? " and faster battery use" : "") are normal."
        case 60..<85:
            explanation = "\(source) is carrying a high load. Memory and heat remain comfortable, so the Mac should stay responsive."
        case 25..<60:
            explanation = "Normal active work with comfortable memory and heat. No action is needed."
        default:
            explanation = "Plenty of headroom. Background work can continue without affecting responsiveness."
        }
        return measured(
            metricTitle: metricTitle,
            usage: usage,
            isEstimate: gpuLeads,
            intensity: intensity,
            health: "Healthy",
            explanation: explanation,
            intensityTone: intensityTone,
            healthTone: .comfortable
        )
    }

    private static func state(
        metricTitle: String = "Current load",
        value: String,
        intensity: String,
        health: String,
        explanation: String,
        intensityTone: MachineStatusTone = .neutral,
        healthTone: MachineStatusTone = .neutral
    ) -> MachineMoment {
        MachineMoment(
            metricTitle: metricTitle,
            valueText: value,
            isEstimate: false,
            usagePercent: nil,
            intensity: intensity,
            health: health,
            explanation: explanation,
            intensityTone: intensityTone,
            healthTone: healthTone
        )
    }

    private static func measured(
        metricTitle: String,
        usage: Double,
        isEstimate: Bool,
        intensity: String,
        health: String,
        explanation: String,
        intensityTone: MachineStatusTone,
        healthTone: MachineStatusTone
    ) -> MachineMoment {
        MachineMoment(
            metricTitle: metricTitle,
            valueText: "\(Int(usage.rounded()))%",
            isEstimate: isEstimate,
            usagePercent: usage,
            intensity: intensity,
            health: health,
            explanation: explanation,
            intensityTone: intensityTone,
            healthTone: healthTone
        )
    }

    private static func intensity(for usage: Double) -> String {
        switch usage {
        case 85...: return "Near full"
        case 60..<85: return "High"
        case 25..<60: return "Active"
        default: return "Light"
        }
    }

    private static func intensityTone(for usage: Double) -> MachineStatusTone {
        switch usage {
        case 85...: return .critical
        case 60..<85: return .warning
        case 25..<60: return .neutral
        default: return .comfortable
        }
    }

    private struct RecentReading {
        let latest: SystemSample
        let cpuAverage: Double
        let gpuAverage: Double?
        let gpuCoverage: Double
    }

    private static func recentReading(from samples: [SystemSample]) -> RecentReading? {
        let ordered = samples.sorted(by: { $0.timestamp < $1.timestamp })
        guard let latestIndex = ordered.lastIndex(where: { $0.duration > 0 }) else { return nil }
        let latest = ordered[latestIndex]
        let cutoff = latest.timestamp.addingTimeInterval(-120)
        var recent: [SystemSample] = []
        var index = latestIndex

        while true {
            let sample = ordered[index]
            guard sample.duration > 0, sample.timestamp >= cutoff else { break }
            if let newer = recent.last {
                let gap = newer.timestamp.timeIntervalSince(sample.timestamp)
                let expected = max(newer.samplingInterval, sample.samplingInterval)
                if gap <= 0 || gap > max(45, expected * 2.2) { break }
            }
            recent.append(sample)
            if index == ordered.startIndex { break }
            index = ordered.index(before: index)
        }

        guard !recent.isEmpty else { return nil }
        let cpuWeight = recent.reduce(0.0) { $0 + max(1, $1.duration) }
        let cpuAverage = recent.reduce(0.0) {
            $0 + $1.cpuPercent * max(1, $1.duration)
        } / max(1, cpuWeight)
        let graphics = recent.compactMap { sample -> (Double, Double)? in
            guard let gpu = sample.gpuPercent, gpu.isFinite else { return nil }
            return (gpu, max(1, sample.duration))
        }
        let graphicsWeight = graphics.reduce(0.0) { $0 + $1.1 }
        let gpuAverage: Double? = graphics.isEmpty
            ? nil
            : graphics.reduce(0.0) { $0 + $1.0 * $1.1 } / max(1, graphicsWeight)
        return RecentReading(
            latest: latest,
            cpuAverage: cpuAverage,
            gpuAverage: gpuAverage,
            gpuCoverage: graphicsWeight / max(1, cpuWeight)
        )
    }
}

private enum MachineStatusTone {
    case comfortable
    case neutral
    case warning
    case critical

    var color: Color {
        switch self {
        case .comfortable: MachinePalette.comfortable
        case .neutral: MachinePalette.neutral
        case .warning: MachinePalette.warning
        case .critical: MachinePalette.critical
        }
    }
}

private enum MachinePalette {
    static let comfortable = adaptive(
        light: NSColor(srgbRed: 0.098, green: 0.478, blue: 0.294, alpha: 1),
        dark: NSColor(srgbRed: 0.345, green: 0.788, blue: 0.522, alpha: 1)
    )
    static let neutral = adaptive(
        light: NSColor(srgbRed: 0.125, green: 0.129, blue: 0.141, alpha: 1),
        dark: NSColor(srgbRed: 0.894, green: 0.894, blue: 0.906, alpha: 1)
    )
    static let warning = adaptive(
        light: NSColor(srgbRed: 0.541, green: 0.353, blue: 0.000, alpha: 1),
        dark: NSColor(srgbRed: 0.961, green: 0.769, blue: 0.318, alpha: 1)
    )
    static let critical = adaptive(
        light: NSColor(srgbRed: 0.788, green: 0.184, blue: 0.231, alpha: 1),
        dark: NSColor(srgbRed: 1.000, green: 0.357, blue: 0.408, alpha: 1)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
