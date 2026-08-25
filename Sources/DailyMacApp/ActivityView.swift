import DailyMacCore
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(title: "Processes & Activity", subtitle: "The latest usable machine and process readings, with stale data labelled clearly")

                if let sample = model.latestSystem {
                    ReportSection(title: isFreshUsable(sample) ? "Current machine state" : "Last recorded machine state") {
                        readingContext(sample)
                        currentState(sample, isCurrent: isFreshUsable(sample))
                    }
                } else {
                    ContentUnavailableView("Waiting for the first reading", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: 760, minHeight: 180)
                }

                ReportSection(title: "Largest observed process activity") {
                    Text(processContext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if processComparisonIsFresh {
                        Text(model.processCoverage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.processImpacts.isEmpty {
                        Text(processComparisonIsFresh
                             ? "No individual process crossed the meaningful CPU, memory, disk, or foreground thresholds in the latest comparison. Nothing useful needs attention from this list."
                             : "No significant process reading was retained for the last comparison. That is not evidence that nothing is active now; MY MACHINE needs a fresh comparison before drawing a conclusion.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.processImpacts) { process in
                            processRow(process)
                            if process.id != model.processImpacts.last?.id { Divider() }
                        }
                    }
                }

                ReportSection(title: "What this list can and cannot say") {
                    Text("A named process is one of the largest contributors MY MACHINE could observe—not proof that it caused every system change. macOS protects some processes, short-lived work can fall between samples, and helper processes are not guessed into an owning app without reliable identity. Background activity means resource use while not in front; it does not mean you were using that process.")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(30)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Processes & Activity")
    }

    private func currentState(_ sample: SystemSample, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ExplainedMetric(
                title: "Processor",
                interpretation: sample.duration > 0
                    ? PracticalInterpreter.cpu(sample.cpuPercent)
                    : "This reading established fresh counter baselines, so its zero processor delta is not treated as light use. MY MACHINE needs the next complete interval before drawing a performance conclusion.",
                detail: sample.duration > 0
                    ? "Whole-machine CPU was \(Formatters.percent(sample.cpuPercent)); 1-minute load average was \(String(format: "%.1f", sample.loadAverage1m))."
                    : "No complete CPU interval was available. The 1-minute load average was \(String(format: "%.1f", sample.loadAverage1m)), but it is secondary context rather than a substitute CPU conclusion."
            )
            ExplainedMetric(
                title: "Memory",
                interpretation: PracticalInterpreter.memory(used: sample.memoryUsedBytes, total: sample.memoryTotalBytes, pressure: sample.memoryPressure, swap: sample.swapUsedBytes),
                detail: "The active/wired/compressed footprint is \(Formatters.bytes(sample.memoryUsedBytes)) of \(Formatters.bytes(sample.memoryTotalBytes)); readily reclaimable cache is excluded. Swap allocated is \(Formatters.bytes(sample.swapUsedBytes)); pressure category is \(sample.memoryPressure.rawValue)."
            )
            ExplainedMetric(
                title: "Power and heat",
                interpretation: powerInterpretation(sample, isCurrent: isCurrent),
                detail: "Power source: \(sample.powerSource.rawValue). Battery: \(sample.batteryPercent.map(Formatters.percent) ?? "unavailable"). Charging: \(sample.isCharging.map { $0 ? "yes" : "no" } ?? "unavailable"). Thermal state: \(sample.thermalLevel.rawValue)."
            )
            Text("Last reading: \(sample.timestamp.formatted(date: .abbreviated, time: .standard))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isCurrent {
                Text("These values are historical context, not a live diagnosis. Resume monitoring or wait for a fresh complete interval before acting on them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func readingContext(_ sample: SystemSample) -> some View {
        if isFreshUsable(sample) {
            Text("This complete interval is recent enough to describe the Mac now. Interpretations below explain likely practical effects; exact readings remain secondary.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.collectionState == .paused {
            Text("Monitoring is paused. This reading is from \(sample.timestamp.formatted(date: .abbreviated, time: .shortened)) and may no longer describe the Mac. Nothing is being collected during the pause.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if case .failed = model.collectionState {
            Text("Monitoring stopped because MY MACHINE could not safely update its local history. This is the last saved reading, not a live diagnosis; existing data remains safe and reopening the app retries collection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.collectionState == .sleeping {
            Text("Collection is suspended while the Mac sleeps. This is the last reading before sleep; fresh counter baselines will be established after wake.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if sample.duration <= 0 {
            Text("MY MACHINE has a fresh baseline but not yet a complete interval. It will not interpret a baseline-only processor value as unusually light use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("The most recent complete interval is too old to describe the Mac now. It remains visible as dated history, and no current action is inferred from it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func powerInterpretation(_ sample: SystemSample, isCurrent: Bool) -> String {
        let heat = sample.thermalLevel.explanation
        let timing = isCurrent ? "The Mac is" : "At that reading, the Mac was"
        switch sample.powerSource {
        case .battery:
            return "\(timing) on battery at \(sample.batteryPercent.map(Formatters.percent) ?? "an unavailable level"). \(heat)"
        case .adapter:
            return "\(timing) connected to power. \(heat)"
        case .unknown:
            return "macOS did not expose a usable power-source reading for that interval. \(heat)"
        }
    }

    private func processRow(_ process: ProcessImpact) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                Text("CPU: \(String(format: "%.1f%%", process.cpuPercent)) of one core-equivalent. A multithreaded process may exceed 100%.")
                Text("Physical footprint: \(Formatters.bytes(process.memoryBytes)). Disk activity in its latest process interval: \(Formatters.bytes(process.diskBytes)).")
                Text("Collection source: best-effort kernel rusage counters. The executable/process name is sanitized; file paths, files opened by the process, arguments, environment variables, and network destinations are never stored.")
                Text("Recorded: \(process.timestamp.formatted(date: .abbreviated, time: .standard)). If this is not recent, it does not imply the process is still active.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 5)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(process.name).font(.subheadline.weight(.semibold))
                    if process.isForeground {
                        Text("In front")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Text(process.interpretation)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }

    private func isFreshUsable(_ sample: SystemSample) -> Bool {
        guard model.collectionState == .monitoring, sample.duration > 0 else { return false }
        let age = Date().timeIntervalSince(sample.timestamp)
        return age >= -5 && age <= max(120, sample.samplingInterval * 4)
    }

    private var processComparisonIsFresh: Bool {
        guard model.collectionState == .monitoring,
              let timestamp = model.processImpacts.map(\.timestamp).max() else { return false }
        let age = Date().timeIntervalSince(timestamp)
        return age >= -5 && age <= 180
    }

    private var processContext: String {
        guard let timestamp = model.processImpacts.map(\.timestamp).max() else {
            return "No meaningful process comparison has been retained yet. Process CPU needs two observations, and the list remains quiet until something crosses a useful threshold."
        }
        if processComparisonIsFresh {
            return "The latest significant process comparison was recorded at \(timestamp.formatted(date: .omitted, time: .standard)) and is recent enough to describe current contributors."
        }
        return "These are the last significant process readings, recorded at \(timestamp.formatted(date: .abbreviated, time: .standard)). They may no longer be running and are shown only as dated context."
    }
}
