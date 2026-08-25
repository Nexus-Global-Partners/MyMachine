import DailyMacCore
import SwiftUI

struct MonitoringView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let snapshot = model.monitoringSnapshot {
                    MachineStatusBanner(
                        snapshot: snapshot,
                        samples: model.monitoringSamples,
                        collectionState: model.collectionState,
                        presentation: .full,
                        resumeAction: { model.startMonitoring() }
                    )

                    if snapshot.sampleCount > 0 {
                        if model.monitoringSamples.count >= 2 {
                            VStack(alignment: .leading, spacing: 11) {
                                Text("Machine timeline")
                                    .font(.headline)
                                MonitoringTimelineView(
                                    snapshot: snapshot,
                                    samples: model.monitoringSamples,
                                    backgroundPoints: model.monitoringBackgroundPoints,
                                    events: model.monitoringEvents
                                )
                                .equatable()
                            }
                        }

                        if !snapshot.backgroundApplications.isEmpty {
                            backgroundWork(snapshot)
                        }

                        if !snapshot.applications.isEmpty {
                            foregroundUse(snapshot)
                        }

                        notable(snapshot)
                        details(snapshot)
                    } else {
                        emptyState
                    }
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("")
        .task { model.refreshMonitoringIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Monitoring")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 5) {
                    Text(model.monitoringRange == .oneHour
                        ? "Last hour"
                        : "Last \(model.monitoringRange.label.lowercased())")
                    if let dataThrough = model.monitoringDataThrough {
                        Text("·")
                        Text("Data through \(dataThrough.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 14)

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
            .frame(width: 220)

            Button {
                model.refreshNow()
            } label: {
                if model.monitoringIsRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh monitoring")
            .accessibilityLabel("Refresh monitoring")
            .disabled(model.monitoringIsRefreshing)
        }
    }

    private func backgroundWork(_ snapshot: MonitoringSnapshot) -> some View {
        let applications = snapshot.backgroundApplications.sorted { lhs, rhs in
            let lhsHasAgents = lhs.maximumAgentWorkerCount > 0
            let rhsHasAgents = rhs.maximumAgentWorkerCount > 0
            if lhsHasAgents != rhsHasAgents { return lhsHasAgents }
            if lhs.maximumAgentWorkerCount != rhs.maximumAgentWorkerCount {
                return lhs.maximumAgentWorkerCount > rhs.maximumAgentWorkerCount
            }
            return lhs.backgroundActivityDuration > rhs.backgroundActivityDuration
        }
        let visibleApplications = Array(applications.prefix(2))
        let sectionConclusion: String
        if visibleApplications.contains(where: { $0.seriousThermalOverlapDuration > 0 }) {
            sectionConclusion = "Some off-screen work overlapped heat that may have reduced speed. Let useful work finish; stop an unused task only if the Mac stays hot or slow."
        } else if visibleApplications.contains(where: { $0.elevatedMemoryOverlapDuration >= 60 }) {
            sectionConclusion = "Some off-screen work overlapped memory pressure, so app switching may have felt slower. This was noticeable, not dangerous; no action is needed unless it repeats."
        } else {
            sectionConclusion = "Useful work continued without a noticeable effect on performance."
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Work continuing off-screen")
                .font(.headline)
            Text(sectionConclusion)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleApplications.enumerated()), id: \.element.id) { index, app in
                    BackgroundAppRow(summary: app)
                    if index < visibleApplications.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func foregroundUse(_ snapshot: MonitoringSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In the foreground")
                .font(.headline)
            Text("Which apps were in front while you were active. This is workflow context—not a claim about what caused the machine load.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(snapshot.applications.prefix(3)) { app in
                    MonitoringAppRow(app: app, totalActiveDuration: snapshot.activeDuration)
                }
            }
        }
    }

    @ViewBuilder
    private func notable(_ snapshot: MonitoringSnapshot) -> some View {
        let insights = notableInsights(snapshot)
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text("Worth knowing")
                    .font(.headline)
                ForEach(insights.prefix(1)) { insight in
                    MonitoringInsightRow(insight: insight)
                }
            }
        }
    }

    private func details(_ snapshot: MonitoringSnapshot) -> some View {
        DisclosureGroup("Details & privacy") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The default view interprets the practical effect first. These exact readings are available for deeper inspection.")
                    .foregroundStyle(.secondary)

                VStack(spacing: 7) {
                    LabeledContent("Recorded coverage", value: Formatters.duration(snapshot.observedDuration))
                    LabeledContent("Longest continuous stretch", value: Formatters.duration(snapshot.longestContinuousCoverage))
                    LabeledContent("CPU peak", value: Formatters.percent(snapshot.peakCPU))
                    LabeledContent("Memory average", value: Formatters.bytes(snapshot.averageMemoryBytes))
                    LabeledContent("Memory peak", value: Formatters.bytes(snapshot.peakMemoryBytes))
                    LabeledContent("Swap at the latest reading", value: Formatters.bytes(snapshot.endingSwapBytes))
                    LabeledContent("Observed whole-Mac file activity", value: Formatters.bytes(snapshot.totalDiskBytes))
                    LabeledContent("Whole-Mac network traffic", value: Formatters.bytes(snapshot.totalNetworkBytes))
                    LabeledContent("Background app families", value: "\(snapshot.backgroundApplications.count)")
                    LabeledContent("Foreground app changes", value: "\(snapshot.contextSwitches)")
                    LabeledContent("Samples used", value: "\(snapshot.sampleCount)")
                }
                .font(.callout)

                Divider()

                Label("Local only", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                Text("MY MACHINE sees app identity, parent relationships between running processes, whole-Mac behavior, and interval totals for typing, pointer movement, clicks, and scrolling. It never reads what you type, individual keys, pointer coordinates or targets, command lines, workspace names, window contents, prompts, files, screenshots, URLs, messages, credentials, or account history. Codex and ChatGPT are treated like any other app, and monitoring data is not uploaded or sent to an AI service.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Metric sources and limits") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(MetricCatalog.disclosures) { disclosure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(disclosure.metric) · \(disclosure.origin.rawValue)")
                                    .font(.caption.weight(.semibold))
                                Text(disclosure.plainLanguage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 7)
                }
            }
            .padding(.top, 10)
            .textSelection(.enabled)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.collectionState == .paused {
            ContentUnavailableView {
                Label("Monitoring is paused", systemImage: "pause.circle")
            } description: {
                Text("Resume to begin collecting new readings. No activity is inferred while monitoring is paused.")
            } actions: {
                Button("Resume Monitoring") { model.startMonitoring() }
            }
            .frame(maxWidth: .infinity, minHeight: 340)
        } else {
            ContentUnavailableView {
                Label("Collecting enough history", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Monitoring is active. This view will fill in as readings arrive.")
            }
            .frame(maxWidth: .infinity, minHeight: 340)
        }
    }

    private func notableInsights(_ snapshot: MonitoringSnapshot) -> [ReportInsight] {
        snapshot.insights.filter { insight in
            if snapshot.peakMemoryPressure != .low,
               insight.title.localizedCaseInsensitiveContains("memory")
                || insight.title.localizedCaseInsensitiveContains("swap") {
                return false
            }
            if snapshot.thermalPeak == .serious || snapshot.thermalPeak == .critical,
               insight.title.localizedCaseInsensitiveContains("thermal") {
                return false
            }
            if snapshot.averageCPU >= 60,
               insight.title.localizedCaseInsensitiveContains("processor") {
                return false
            }
            if insight.kind == .caution || insight.kind == .recommendation { return true }
            return insight.title == "Part of this window is unrecorded"
                || insight.title == "Foreground apps changed frequently"
                || insight.title == "Swap allocation grew during the continuous window"
        }
    }
}

private struct BackgroundAppRow: View {
    let summary: BackgroundAppSummary
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("What happened", value: happenedDetail)
                LabeledContent("Practical effect", value: practicalEffect)
                LabeledContent("Useful action", value: usefulAction)
                Text("The memory figure is the combined observed process-family footprint and can include shared pages. File activity is observed process I/O—not storage consumed or SSD wear.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.ownerName)
                    .font(.subheadline.weight(.semibold))
                if summary.maximumAgentWorkerCount > 0 {
                    Text(agentLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.11), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                } else if summary.maximumWorkerCount > 0 {
                    Text(workerLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(workDurationLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 9)
        .accessibilityHint("Expands the evidence, practical effect, and useful action")
    }

    private var agentLabel: String {
        "\(summary.maximumAgentWorkerCount) agent \(summary.maximumAgentWorkerCount == 1 ? "worker" : "workers")"
    }

    private var workDurationLabel: String {
        summary.backgroundActivityDuration < 60
            ? "Work just detected"
            : "Working \(Formatters.duration(summary.backgroundActivityDuration))"
    }

    private var workerLabel: String {
        "\(summary.maximumWorkerCount) observed \(summary.maximumWorkerCount == 1 ? "worker" : "workers")"
    }

    private var processorLabel: String {
        if summary.averageCPUPercent < 10, summary.peakCPUPercent < 30 { return "Light" }
        if summary.averageCPUPercent < 50, summary.peakCPUPercent < 100 { return "Moderate" }
        return "Heavy"
    }

    private var memoryLabel: String {
        switch summary.peakMemoryBytes {
        case ..<750_000_000: return "Light"
        case ..<2_000_000_000: return "Moderate"
        default: return "Substantial"
        }
    }

    private var fileActivityLabel: String {
        let bytes = summary.diskReadBytes &+ summary.diskWriteBytes
        switch bytes {
        case 0: return "Quiet"
        case ..<25_000_000: return "Light"
        case ..<500_000_000: return "Active"
        default: return "Bursty"
        }
    }

    private var hasMeaningfulOverlap: Bool {
        summary.elevatedMemoryOverlapDuration >= 60 || summary.seriousThermalOverlapDuration > 0
    }

    private var practicalEffect: String {
        if summary.seriousThermalOverlapDuration > 0 {
            return "Its work overlapped meaningful heat pressure, so the Mac may have reduced speed."
        }
        if summary.elevatedMemoryOverlapDuration >= 60 {
            return "Its work overlapped \(Formatters.duration(summary.elevatedMemoryOverlapDuration)) of elevated memory demand, which may have made heavy app switching slower."
        }
        if processorLabel == "Heavy" {
            return "This was meaningful processor work and may have added heat or battery use."
        }
        return "This looks like normal background work and should not have disrupted your workflow."
    }

    private var happenedDetail: String {
        let duration = Formatters.duration(summary.backgroundDuration)
        let work = Formatters.duration(summary.backgroundActivityDuration)
        return "Observed behind other apps for \(duration), with measurable processor or file work for \(work). Peak family footprint was about \(Formatters.bytes(summary.peakMemoryBytes))."
    }

    private var usefulAction: String {
        if hasMeaningfulOverlap {
            return "Keep it running while the work is useful. Finish an unused worker only if slowdown or heat repeats."
        }
        if processorLabel == "Heavy" {
            return "Let it finish if expected. If responsiveness drops, avoid stacking another heavy task."
        }
        return "Nothing to change."
    }
}

private struct MonitoringAppRow: View {
    let app: AppUsageSummary
    let totalActiveDuration: TimeInterval
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(appDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(app.name)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(Formatters.duration(app.activeDuration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: app.activeDuration, total: max(totalActiveDuration, 1))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
        }
        .accessibilityHint("Shows whole-Mac context while this app was in front")
    }

    private var appDetail: String {
        let level: String
        switch app.averageSystemCPU {
        case ..<25: level = "light, leaving plenty of headroom"
        case ..<60: level = "moderate and normal for active work"
        default: level = "heavy enough to add heat or battery use"
        }
        return "Whole-Mac CPU demand averaged \(Formatters.percent(app.averageSystemCPU)) while \(app.name) was in front—\(level). This is workflow context, not proof that the app caused the load."
    }
}

private struct MonitoringInsightRow: View {
    let insight: ReportInsight

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(color)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
                Text(insight.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
                if let evidence = insight.evidence {
                    DisclosureGroup("Why this appears") {
                        Text(evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: String {
        switch insight.kind {
        case .efficient: return "checkmark.circle"
        case .caution: return "exclamationmark.circle"
        case .recommendation: return "arrow.right.circle"
        case .observation: return "circle.fill"
        }
    }

    private var color: Color {
        insight.kind == .caution ? .orange : .secondary
    }
}
