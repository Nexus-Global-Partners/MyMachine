import AppKit
import DailyMacCore
import Foundation
import SwiftUI

enum TimelinePresentation: Equatable {
    case full
    case expanded
    case menuBar
}

/// One time-aligned view of the Mac. Dense telemetry is rendered by a single
/// asynchronous Canvas; the lightweight selection overlay redraws independently.
struct MonitoringTimelineView: View, Equatable {
    let snapshot: MonitoringSnapshot
    let samples: [SystemSample]
    let backgroundPoints: [BackgroundActivityPoint]
    let events: [ActivityEvent]
    let presentation: TimelinePresentation
    let expandedProcessorHeight: CGFloat?

    @State private var selectedTime: Date?

    private let interval: DateInterval
    private let sleepIntervals: [DateInterval]
    private let batteryRuns: [BatteryTimelineRun]
    private let batteryTenPointTiming: BatteryTenPointTiming
    private let showsBatteryTrack: Bool
    private let processorTrend: [ProcessorTrendPoint]
    private let memoryConditions: MemoryConditionTimeline
    private let processorScaleMaximum: Double
    private let windowUsageSummary: TimelineWindowUsageSummary

    init(
        snapshot: MonitoringSnapshot,
        samples: [SystemSample],
        backgroundPoints: [BackgroundActivityPoint],
        events: [ActivityEvent],
        presentation: TimelinePresentation = .full,
        expandedProcessorHeight: CGFloat? = nil
    ) {
        self.snapshot = snapshot
        let orderedSamples = samples.sorted(by: { $0.timestamp < $1.timestamp })
        self.samples = orderedSamples
        self.backgroundPoints = backgroundPoints
        self.events = events
        self.presentation = presentation
        self.expandedProcessorHeight = expandedProcessorHeight
        self.interval = snapshot.interval
        let processorTrend = Self.makeProcessorTrend(
            from: orderedSamples,
            within: snapshot.interval,
            range: snapshot.range
        )
        self.processorTrend = processorTrend
        self.memoryConditions = Self.makeMemoryConditions(
            from: orderedSamples,
            within: snapshot.interval
        )
        self.processorScaleMaximum = Self.processorScaleMaximum(for: processorTrend)
        self.windowUsageSummary = TimelineSemantics.windowUsageSummary(
            from: orderedSamples,
            within: snapshot.interval
        )

        let sleeps = TimelineSemantics.sleepIntervals(from: events, within: snapshot.interval)
        self.sleepIntervals = sleeps
        let rawBatteryRuns = TimelineSemantics.batteryRuns(
            from: self.samples,
            within: snapshot.interval,
            sleepIntervals: sleeps,
            pointLimit: .max
        )
        self.batteryTenPointTiming = rawBatteryRuns.last.map(TimelineSemantics.batteryTenPointTiming)
            ?? .collecting
        let runs = TimelineSemantics.batteryRuns(
            from: self.samples,
            within: snapshot.interval,
            sleepIntervals: sleeps
        )
        self.batteryRuns = runs
        let latestIsOnBattery = self.samples.last.map(Self.isValidBatterySample) ?? false
        self.showsBatteryTrack = presentation != .menuBar
            && (latestIsOnBattery || runs.contains { $0.readings.count >= 2 })
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.samples == rhs.samples
            && lhs.backgroundPoints == rhs.backgroundPoints
            && lhs.events == rhs.events
            && lhs.presentation == rhs.presentation
            && lhs.expandedProcessorHeight == rhs.expandedProcessorHeight
    }

    var body: some View {
        let layout = UnifiedTimelineLayout(
            showsBattery: showsBatteryTrack,
            showsMemory: presentation != .menuBar,
            presentation: presentation,
            expandedProcessorHeight: expandedProcessorHeight
        )

        VStack(alignment: .leading, spacing: contentSpacing) {
            inspector
                .frame(height: inspectorHeight, alignment: .center)

            HStack(alignment: .top, spacing: contentSpacing) {
                labelRail(layout: layout)
                    .frame(width: labelWidth, height: layout.totalHeight, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedTime = nil }

                ZStack {
                    UnifiedDataCanvas(
                        samples: samples,
                        processorTrend: processorTrend,
                        memoryConditions: memoryConditions,
                        batteryRuns: batteryRuns,
                        sleepIntervals: sleepIntervals,
                        interval: interval,
                        processorScaleMaximum: processorScaleMaximum,
                        layout: layout
                    )
                    .equatable()

                    TimelineSelectionOverlay(
                        selectedTime: $selectedTime,
                        interval: interval,
                        rightAxisWidth: layout.rightAxisWidth
                    )
                }
                .frame(height: layout.totalHeight)
            }

            timeAxis
                .contentShape(Rectangle())
                .onTapGesture { selectedTime = nil }
        }
        .onChange(of: snapshot.interval) {
            guard let selectedTime else { return }
            if !snapshot.interval.contains(selectedTime) { self.selectedTime = nil }
        }
        .accessibilityElement(children: .contain)
    }

    private var labelWidth: CGFloat {
        switch presentation {
        case .menuBar: return 148
        case .full: return 152
        case .expanded: return 188
        }
    }

    private var contentSpacing: CGFloat {
        switch presentation {
        case .menuBar: return 8
        case .full: return 12
        case .expanded: return 16
        }
    }

    private var inspectorHeight: CGFloat {
        switch presentation {
        case .menuBar: return 36
        case .full: return 44
        case .expanded: return 48
        }
    }

    private func labelRail(layout: UnifiedTimelineLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.sectionGap) {
            processorTrackLabel
            .frame(height: layout.cpuHeight, alignment: .topLeading)

            handsOnTrackLabel
            .frame(height: layout.handsOnHeight, alignment: .topLeading)

            if showsBatteryTrack {
                trackLabel(
                    title: "Battery",
                    status: batteryStatus,
                    symbol: "battery.75percent"
                )
                .frame(height: layout.batteryHeight, alignment: .topLeading)
            }

            if layout.showsMemory {
                trackLabel(
                    title: "Memory",
                    status: memoryStatus,
                    symbol: "memorychip"
                )
                .frame(height: layout.memoryHeight, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var processorTrackLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            processorKey(
                "CPU",
                meaning: cpuLabel(snapshot.averageCPU),
                value: snapshot.averageCPU,
                color: TimelineColors.processor
            )
            if let graphicsAverage {
                processorKey(
                    "GPU",
                    meaning: gpuLabel(graphicsAverage),
                    value: graphicsAverage,
                    color: TimelineColors.graphics,
                    isEstimate: true
                )
            }
            if let processorMemoryKey {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(TimelineColors.memory)
                        .frame(width: 10, height: 4)
                    Text(processorMemoryKey)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(processorWindowPrimary)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(2)
            if let processorWindowImpact {
                Text(processorWindowImpact)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func processorKey(
        _ title: String,
        meaning: String,
        value: Double,
        color: Color,
        isEstimate: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            Text("\(title)\(isEstimate ? " est." : "") \(Formatters.percent(value))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text("· \(meaning.lowercased())")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var processorMemoryKey: String? {
        switch snapshot.peakMemoryPressure {
        case .low:
            return nil
        case .elevated:
            return snapshot.elevatedMemoryDuration >= 5 * 60
                ? "Memory elevated"
                : nil
        case .high:
            return longestConstrainedMemoryDuration >= 2 * 60
                ? "Memory constrained"
                : "Brief memory pressure"
        }
    }

    private var handsOnTrackLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(handsOnHeadline, systemImage: "person")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TimelineColors.handsOn)
                .lineLimit(1)
            Text(handsOnObservedLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let handsOnLongestLine {
                Text(handsOnLongestLine)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.76))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Hands-on share uses recorded typing, pointer, click, and scroll totals. It does not judge focus or productivity.")
    }

    @ViewBuilder
    private var inspector: some View {
        if presentation == .menuBar {
            compactContextStrip
        } else if let selectedTime {
            TimelineInspector(
                selection: selectedState,
                time: selectedTime,
                background: selectedBackgroundPoints,
                batteryRun: selectedBatteryRun,
                previousSample: selectedPreviousSample,
                isSustainedMemoryConstraint: isSustainedMemoryConstraint(at: selectedTime),
                onDismiss: { self.selectedTime = nil }
            )
        } else {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: currentStatus.symbol)
                        .foregroundStyle(currentStatus.color)
                    Text(currentStatus.message)
                        .foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Text("Drag the timeline for exact context")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
    }

    private var compactContextStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: compactContextSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(compactContextColor)
                .frame(width: 15)
            compactContextCopy
                .frame(maxWidth: .infinity, alignment: .leading)
            if selectedTime != nil {
                Button {
                    selectedTime = nil
                } label: {
                    Label("Now", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .help("Clear selection and return to the current status")
                .accessibilityLabel("Return to current status")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(compactContextColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var compactContextCopy: some View {
        if selectedTime == nil {
            Text(compactTakeaway)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.80))
                .lineLimit(2)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(compactContextPrimary)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(compactContextSecondary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var compactContextPrimary: String {
        guard let selectedTime else { return compactTakeaway }
        let clock = selectedTime.formatted(date: .omitted, time: .shortened)
        switch selectedState {
        case .sleep:
            return "\(clock) · Mac asleep"
        case .unrecorded:
            return "\(clock) · Not recorded"
        case .observed(let sample):
            let foreground = sample.foregroundApp.isEmpty ? "Mac in use" : "\(sample.foregroundApp) in front"
            return "\(clock) · \(foreground) · \(compactHandsOnMeaning(sample))"
        }
    }

    private var compactContextSecondary: String {
        switch selectedState {
        case .sleep:
            return "Normal app and agent work was paused; no readings are inferred."
        case .unrecorded:
            return "The gap stays blank instead of being guessed."
        case .observed(let sample):
            var processor = "CPU \(Formatters.percent(sample.cpuPercent))"
            if let gpu = sample.gpuPercent {
                processor += " · GPU \(Formatters.percent(gpu)) est."
            }
            return "\(processor) · memory \(compactMemoryMeaning(sample)) · \(compactPowerMeaning(sample))"
        }
    }

    private var compactContextSymbol: String {
        guard selectedTime != nil else { return compactTakeawaySymbol }
        switch selectedState {
        case .sleep: return "moon.fill"
        case .unrecorded: return "clock.badge.questionmark"
        case .observed: return "waveform.path.ecg"
        }
    }

    private var compactContextColor: Color {
        guard selectedTime != nil else { return compactTakeawayColor }
        switch selectedState {
        case .sleep, .unrecorded: return .secondary
        case .observed(let sample):
            return urgency(for: sample).color
        }
    }

    private var compactTakeaway: String {
        currentStatus.message
    }

    private var compactTakeawaySymbol: String {
        currentStatus.symbol
    }

    private var compactTakeawayColor: Color {
        currentStatus.color
    }

    private var currentStatus: TimelineCurrentStatus {
        guard let latest = samples.last(where: { $0.duration > 0 }) else {
            return .unavailable("Waiting for the first complete reading.")
        }
        let age = max(0, interval.end.timeIntervalSince(latest.timestamp))
        guard age <= max(120, latest.samplingInterval * 4) else {
            return .unavailable("No current reading. Earlier history remains visible below.")
        }

        let recentCutoff = latest.timestamp.addingTimeInterval(-120)
        let recent = processorTrend.filter {
            $0.timestamp >= recentCutoff && $0.timestamp <= latest.timestamp
        }
        let cpu = recent.isEmpty
            ? latest.cpuPercent
            : recent.reduce(0.0) { $0 + $1.cpuPercent } / Double(recent.count)
        let graphics = recent.compactMap(\.gpuPercent)
        let gpu = graphics.isEmpty
            ? latest.gpuPercent
            : graphics.reduce(0, +) / Double(graphics.count)
        let gpuLeads = (gpu ?? 0) > cpu + 5
        let usage = min(100, max(0, gpuLeads ? (gpu ?? 0) : cpu))
        let source = gpuLeads ? "GPU activity" : "CPU demand"
        let estimate = gpuLeads ? "Estimated " : ""
        let baseUrgency = urgency(for: usage)

        if latest.thermalLevel == .serious || latest.thermalLevel == .critical {
            return TimelineCurrentStatus(
                urgency: .critical,
                message: "Heat may be limiting speed. Let one heavy task finish before adding more work."
            )
        }
        if latest.memoryPressure == .high,
           isSustainedMemoryConstraint(at: latest.timestamp) {
            return TimelineCurrentStatus(
                urgency: .critical,
                message: "Memory is constrained. App switching may feel slower; finish an unused heavy task only if this persists."
            )
        }
        if latest.memoryPressure == .high {
            return TimelineCurrentStatus(
                urgency: .elevated,
                message: "Memory pressure rose briefly. The Mac should remain responsive; no action is needed unless it persists."
            )
        }
        if baseUrgency == .critical {
            return TimelineCurrentStatus(
                urgency: .critical,
                message: "\(estimate)\(source) is near capacity at \(Formatters.percent(usage)). Warmth or faster battery use is normal; act only if work slows."
            )
        }
        if latest.memoryPressure == .elevated || latest.thermalLevel == .fair {
            return TimelineCurrentStatus(
                urgency: .elevated,
                message: "Demand is elevated but manageable. The Mac should remain responsive; no action is needed unless slowdown repeats."
            )
        }
        if baseUrgency == .elevated {
            return TimelineCurrentStatus(
                urgency: .elevated,
                message: "\(estimate)\(source) is high at \(Formatters.percent(usage)), within a normal active-work range. No action is needed."
            )
        }
        return TimelineCurrentStatus(
            urgency: .normal,
            message: "Demand looks normal. The Mac has comfortable headroom for active work."
        )
    }

    private func urgency(for sample: SystemSample) -> TimelineUrgency {
        if sample.thermalLevel == .serious || sample.thermalLevel == .critical
            || (sample.memoryPressure == .high
                && isSustainedMemoryConstraint(at: sample.timestamp)) {
            return .critical
        }
        let processor = max(sample.cpuPercent, sample.gpuPercent ?? 0)
        if processor >= 85 { return .critical }
        if sample.thermalLevel == .fair || sample.memoryPressure != .low
            || processor >= 60 {
            return .elevated
        }
        return .normal
    }

    private func urgency(for usage: Double) -> TimelineUrgency {
        if usage >= 85 { return .critical }
        if usage >= 60 { return .elevated }
        return .normal
    }

    private func compactHandsOnMeaning(_ sample: SystemSample) -> String {
        guard let activity = sample.manualActivity else {
            return sample.isIdle ? "no recent input" : "recent physical input"
        }
        return activity.intensity(over: sample.duration) < 0.04 ? "no recent input" : "physical input"
    }

    private func compactMemoryMeaning(_ sample: SystemSample) -> String {
        switch sample.memoryPressure {
        case .low: return "comfortable"
        case .elevated: return "elevated"
        case .high:
            return isSustainedMemoryConstraint(at: sample.timestamp)
                ? "constrained"
                : "brief pressure"
        }
    }

    private func compactPowerMeaning(_ sample: SystemSample) -> String {
        switch sample.powerSource {
        case .adapter:
            return "plugged in"
        case .battery:
            guard let percent = sample.batteryPercent else { return "on battery" }
            return "battery \(Formatters.percent(percent))"
        case .unknown:
            return "power unavailable"
        }
    }

    private var timeAxis: some View {
        HStack(spacing: contentSpacing) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geometry in
                let plotWidth = max(1, geometry.size.width - UnifiedTimelineLayout.rightAxisWidth)
                let tickLabelWidth: CGFloat = 38
                ZStack(alignment: .topLeading) {
                    ForEach(timeMarks) { mark in
                        let fraction = min(1, max(
                            0,
                            mark.date.timeIntervalSince(interval.start) / max(1, interval.duration)
                        ))
                        let clockX = plotWidth * CGFloat(fraction)
                        let positionX = mark.label == "Now"
                            ? plotWidth + UnifiedTimelineLayout.rightAxisWidth / 2
                            : max(tickLabelWidth / 2, clockX)
                        VStack(spacing: 1) {
                            Capsule()
                                .fill(.secondary.opacity(0.38))
                                .frame(width: 1, height: 3)
                            Text(mark.label)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: tickLabelWidth)
                        }
                        .position(x: positionX, y: 8)
                    }
                }
            }
            .frame(height: 18)
        }
    }

    private func trackLabel(title: String, status: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var selectedState: TimelineSelection {
        guard let selectedTime else { return .unrecorded }
        return TimelineSemantics.selection(
            at: selectedTime,
            samples: samples,
            sleepIntervals: sleepIntervals,
            within: interval,
            samplesAreChronological: true
        )
    }

    private var selectedBackgroundPoints: [BackgroundActivityPoint] {
        guard let selectedTime, case .observed = selectedState else { return [] }
        return backgroundPoints.filter { point in
                guard point.duration > 0 else { return false }
                let start = point.timestamp.addingTimeInterval(-point.duration)
                let coversSelection = selectedTime >= start && selectedTime <= point.timestamp
                let isUseful = point.agentWorkerCount > 0
                    || point.cpuPercent >= 0.5
                    || point.diskBytes >= 128_000
                return coversSelection && isUseful
        }
        .sorted { lhs, rhs in
            if lhs.agentWorkerCount != rhs.agentWorkerCount {
                return lhs.agentWorkerCount > rhs.agentWorkerCount
            }
            return lhs.cpuPercent > rhs.cpuPercent
        }
        .prefix(2)
        .map { $0 }
    }

    private var selectedBatteryRun: BatteryTimelineRun? {
        guard let selectedTime else { return nil }
        return batteryRuns.first { run in
            guard let first = run.readings.first, let last = run.readings.last else { return false }
            if run.readings.count == 1 {
                return abs(first.timestamp.timeIntervalSince(selectedTime)) <= 30
            }
            return selectedTime >= first.timestamp && selectedTime <= last.timestamp
        }
    }

    private var selectedPreviousSample: SystemSample? {
        guard case .observed(let selected) = selectedState,
              let index = samples.firstIndex(where: { $0.id == selected.id }),
              index > samples.startIndex else { return nil }
        let previous = samples[samples.index(before: index)]
        let gap = selected.timestamp.timeIntervalSince(previous.timestamp)
        let expected = max(selected.samplingInterval, previous.samplingInterval)
        guard gap > 0, gap <= max(120, expected * 2.2) else { return nil }
        return previous
    }

    private var timeMarks: [TimelineAxisMark] {
        let marks: [(TimeInterval, String)]
        switch snapshot.range {
        case .oneHour:
            marks = [(-3_600, "−1h"), (-1_800, "−30m"), (-600, "−10m"), (0, "Now")]
        case .sixHours:
            marks = [(-21_600, "−6h"), (-7_200, "−2h"), (-3_600, "−1h"), (-1_800, "−30m"), (0, "Now")]
        case .twentyFourHours:
            marks = [(-86_400, "−24h"), (-43_200, "−12h"), (-21_600, "−6h"), (-7_200, "−2h"), (0, "Now")]
        }
        return marks.map { offset, label in
            TimelineAxisMark(
                date: interval.end.addingTimeInterval(offset),
                label: label
            )
        }
    }

    private var graphicsAverage: Double? {
        let readings = samples.compactMap { sample -> (value: Double, weight: Double)? in
            guard let gpu = sample.gpuPercent, gpu.isFinite else { return nil }
            return (gpu, max(1, sample.duration))
        }
        guard !readings.isEmpty else { return nil }
        let totalWeight = readings.reduce(0.0) { $0 + $1.weight }
        return readings.reduce(0.0) { $0 + $1.value * $1.weight } / max(1, totalWeight)
    }

    private var processorWindowPrimary: String {
        guard windowUsageSummary.observedDuration >= CoverageEvaluator.narrativeMinimum else {
            return "Building a reliable pattern"
        }
        if windowUsageSummary.longestHeavyProcessorRun >= 5 * 60 {
            return "Heavy · \(railDuration(windowUsageSummary.longestHeavyProcessorRun)) continuous"
        }
        if windowUsageSummary.heavyProcessorDuration >= 5 * 60 {
            return "Heavy bursts · \(railDuration(windowUsageSummary.heavyProcessorDuration)) total"
        }
        let average = max(snapshot.averageCPU, graphicsAverage ?? 0)
        if average >= TimelineSemantics.heavyProcessorThreshold {
            return "Busy across this window"
        }
        if average >= 25 { return "Moderate · headroom left" }
        return "Light · ample headroom"
    }

    private var processorWindowImpact: String? {
        if snapshot.thermalPeak == .serious || snapshot.thermalPeak == .critical {
            return "Heat may reduce speed"
        }
        if !sustainedMemoryConstraints.isEmpty {
            return "App switching may slow"
        }
        guard windowUsageSummary.heavyProcessorDuration >= 5 * 60 else {
            return windowUsageSummary.observedDuration >= CoverageEvaluator.narrativeMinimum
                ? "Normal for active work"
                : nil
        }
        let latestIsOnBattery = samples.last.map(Self.isValidBatterySample) ?? false
        return latestIsOnBattery
            ? "More warmth + battery use"
            : "More warmth; still responsive"
    }

    private var memoryStatus: String {
        switch snapshot.peakMemoryPressure {
        case .low:
            return "Comfortable · normal"
        case .elevated:
            return snapshot.elevatedMemoryDuration < 5 * 60
                ? "Brief rise · no issue"
                : "Elevated · may slow"
        case .high:
            return longestConstrainedMemoryDuration >= 2 * 60
                ? "Constrained · may slow"
                : "Brief pressure · watching"
        }
    }

    private var longestConstrainedMemoryDuration: TimeInterval {
        memoryConditions.constrained.map(\.duration).max() ?? 0
    }

    private var sustainedMemoryConstraints: [DateInterval] {
        TimelineSemantics.sustainedMemoryConstraints(in: memoryConditions.constrained)
    }

    private func isSustainedMemoryConstraint(at time: Date) -> Bool {
        TimelineSemantics.isSustainedMemoryConstraint(
            at: time,
            in: memoryConditions.constrained
        )
    }

    private var handsOnHeadline: String {
        guard let share = windowUsageSummary.handsOnShare else {
            return "Hands-on · measuring"
        }
        return "Hands-on \(Formatters.percent(share * 100))"
    }

    private var handsOnObservedLine: String {
        guard windowUsageSummary.handsOnShare != nil else { return "Measuring from now" }
        return "\(compactRailDuration(windowUsageSummary.handsOnDuration)) of \(compactRailDuration(windowUsageSummary.manualActivityObservedDuration)) recorded"
    }

    private var handsOnLongestLine: String? {
        guard windowUsageSummary.handsOnShare != nil else { return nil }
        guard windowUsageSummary.longestHandsOnRun >= 60 else { return "Short input bursts" }
        return "Longest · \(railDuration(windowUsageSummary.longestHandsOnRun))"
    }

    private func railDuration(_ duration: TimeInterval) -> String {
        duration < 60 ? "under 1 min" : Formatters.duration(duration)
    }

    private func compactRailDuration(_ duration: TimeInterval) -> String {
        guard duration >= 60 else { return "<1m" }
        let minutes = Int(duration / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }

    private var batteryStatus: String {
        switch batteryTenPointTiming {
        case .observed(let duration):
            return "Last 10% took \(Formatters.duration(duration))"
        case .equivalent(let duration):
            return "10% pace · ≈\(Formatters.duration(duration))"
        case .collecting:
            return "10% pace · collecting"
        }
    }

    private func cpuLabel(_ value: Double) -> String {
        switch value {
        case ..<25: return "Light"
        case ..<60: return "Moderate"
        default: return "Heavy"
        }
    }

    private func gpuLabel(_ value: Double) -> String {
        switch value {
        case ..<25: return "Light"
        case ..<60: return "Moderate"
        default: return "Busy"
        }
    }

    private static func isValidBatterySample(_ sample: SystemSample) -> Bool {
        guard sample.powerSource == .battery,
              sample.isCharging != true,
              let percent = sample.batteryPercent else { return false }
        return percent.isFinite && (0...100).contains(percent)
    }

    private static func makeProcessorTrend(
        from samples: [SystemSample],
        within interval: DateInterval,
        range: MonitoringRange
    ) -> [ProcessorTrendPoint] {
        let bucketDuration: TimeInterval
        switch range {
        case .oneHour: bucketDuration = 30
        case .sixHours: bucketDuration = 120
        case .twentyFourHours: bucketDuration = 600
        }

        var buckets: [ProcessorBucketKey: [SystemSample]] = [:]
        var segment = 0
        var previous: SystemSample?
        for sample in samples where sample.timestamp >= interval.start && sample.timestamp <= interval.end {
            guard sample.duration > 0 else {
                previous = nil
                segment += 1
                continue
            }
            if let previous {
                let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let expected = max(previous.samplingInterval, sample.samplingInterval)
                if gap <= 0 || gap > max(120, expected * 2.2) { segment += 1 }
            }
            let bucket = max(0, Int(sample.timestamp.timeIntervalSince(interval.start) / bucketDuration))
            buckets[ProcessorBucketKey(segment: segment, bucket: bucket), default: []].append(sample)
            previous = sample
        }

        return buckets.keys.sorted {
            $0.segment == $1.segment ? $0.bucket < $1.bucket : $0.segment < $1.segment
        }.compactMap { key in
            guard let values = buckets[key], let latest = values.last else { return nil }
            let cpuWeighted = values.reduce(0.0) { partial, sample in
                partial + sample.cpuPercent * max(1, sample.duration)
            }
            let cpuWeight = values.reduce(0.0) { $0 + max(1, $1.duration) }
            let graphics = values.compactMap { sample -> (Double, Double)? in
                guard let gpu = sample.gpuPercent else { return nil }
                return (gpu, max(1, sample.duration))
            }
            let gpuPercent: Double? = graphics.isEmpty
                ? nil
                : graphics.reduce(0.0) { $0 + $1.0 * $1.1 } / graphics.reduce(0.0) { $0 + $1.1 }
            let coreReadings = values.compactMap { sample -> (Double, Double, Double, Double)? in
                guard let performance = sample.performanceCorePercent,
                      let efficiency = sample.efficiencyCorePercent,
                      let contribution = sample.performanceCoreContributionPercent,
                      performance.isFinite, efficiency.isFinite, contribution.isFinite else { return nil }
                return (performance, efficiency, contribution, max(1, sample.duration))
            }
            let hasCompleteCoreCoverage = CoreDistributionSemantics.hasCompleteCoverage(in: values)
            let coreWeight = coreReadings.reduce(0.0) { $0 + $1.3 }
            let cpuPercent = cpuWeighted / max(1, cpuWeight)
            let performanceCorePercent: Double? = !hasCompleteCoreCoverage
                ? nil
                : coreReadings.reduce(0.0) { $0 + $1.0 * $1.3 } / coreWeight
            let efficiencyCorePercent: Double? = !hasCompleteCoreCoverage
                ? nil
                : coreReadings.reduce(0.0) { $0 + $1.1 * $1.3 } / coreWeight
            let performanceContribution: Double? = !hasCompleteCoreCoverage
                ? nil
                : min(
                    cpuPercent,
                    max(0, coreReadings.reduce(0.0) { $0 + $1.2 * $1.3 } / coreWeight)
                )
            return ProcessorTrendPoint(
                segment: key.segment,
                timestamp: latest.timestamp,
                cpuPercent: cpuPercent,
                performanceCorePercent: performanceCorePercent,
                efficiencyCorePercent: efficiencyCorePercent,
                performanceCoreContributionPercent: performanceContribution,
                gpuPercent: gpuPercent
            )
        }
    }

    private static func makeMemoryConditions(
        from samples: [SystemSample],
        within interval: DateInterval
    ) -> MemoryConditionTimeline {
        let observed = memoryIntervals(from: samples, within: interval) { _ in true }
        let elevated = memoryIntervals(from: samples, within: interval) { $0.memoryPressure == .elevated }
        let constrained = memoryIntervals(from: samples, within: interval) { $0.memoryPressure == .high }
        return MemoryConditionTimeline(
            observed: mergeIntervals(observed),
            elevated: mergeIntervals(elevated),
            constrained: mergeIntervals(constrained)
        )
    }

    private static func memoryIntervals(
        from samples: [SystemSample],
        within interval: DateInterval,
        matching predicate: (SystemSample) -> Bool
    ) -> [DateInterval] {
        samples.compactMap { sample in
            guard sample.duration > 0,
                  sample.timestamp >= interval.start,
                  sample.timestamp <= interval.end,
                  predicate(sample) else { return nil }
            let start = max(interval.start, sample.timestamp.addingTimeInterval(-sample.duration))
            let end = min(interval.end, sample.timestamp)
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    private static func mergeIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            guard let previous = result.last else {
                result.append(interval)
                continue
            }
            // Timer jitter can leave a sub-second seam between readings. Closing only
            // that seam keeps a sustained condition legible without bridging real gaps.
            if interval.start.timeIntervalSince(previous.end) <= 1.5 {
                result[result.count - 1] = DateInterval(
                    start: previous.start,
                    end: max(previous.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// Uses one of two stable processor scales without visually clipping a real
    /// peak: every recorded value fits either the 0–50% or 0–100% domain.
    private static func processorScaleMaximum(for trend: [ProcessorTrendPoint]) -> Double {
        let cpuHigh = trend.map(\.cpuPercent).filter(\.isFinite).max() ?? 0
        let gpuHigh = trend.compactMap(\.gpuPercent).filter(\.isFinite).max() ?? 0
        return max(cpuHigh, gpuHigh) <= 50 ? 50 : 100
    }

}

private enum TimelineColors {
    static let processor = Color(nsColor: .systemBlue)
    static let handsOn = Color.indigo
    static let graphics = Color(nsColor: .systemTeal)
    static let battery = Color(nsColor: .systemGreen)
    static let memory = Color(nsColor: .systemGray)
    static let normal = Color(nsColor: .systemGreen)
    static let critical = Color(nsColor: .systemRed)
}

private enum TimelineUrgency: Equatable {
    case normal
    case elevated
    case critical
    case unavailable

    var color: Color {
        switch self {
        case .normal: return TimelineColors.normal
        case .elevated: return .secondary
        case .critical: return TimelineColors.critical
        case .unavailable: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle"
        case .elevated: return "waveform.path.ecg"
        case .critical: return "exclamationmark.triangle.fill"
        case .unavailable: return "clock.badge.questionmark"
        }
    }
}

private struct TimelineCurrentStatus {
    let urgency: TimelineUrgency
    let message: String

    var color: Color { urgency.color }
    var symbol: String { urgency.symbol }

    static func unavailable(_ message: String) -> Self {
        Self(urgency: .unavailable, message: message)
    }
}

private struct TimelineAxisMark: Identifiable {
    let date: Date
    let label: String

    var id: String { label }
}

private struct UnifiedTimelineLayout: Equatable {
    static let rightAxisWidth: CGFloat = 38

    let showsBattery: Bool
    let showsMemory: Bool
    let cpuHeight: CGFloat
    let handsOnHeight: CGFloat
    let batteryHeight: CGFloat
    let memoryHeight: CGFloat
    let sectionGap: CGFloat
    let rightAxisWidth: CGFloat = Self.rightAxisWidth

    init(
        showsBattery: Bool,
        showsMemory: Bool,
        presentation: TimelinePresentation,
        expandedProcessorHeight: CGFloat?
    ) {
        self.showsBattery = showsBattery
        self.showsMemory = showsMemory
        switch presentation {
        case .full:
            cpuHeight = 220
            handsOnHeight = 52
            batteryHeight = 56
            memoryHeight = 36
            sectionGap = 12
        case .expanded:
            cpuHeight = min(520, max(320, expandedProcessorHeight ?? 320))
            handsOnHeight = 64
            batteryHeight = 60
            memoryHeight = 42
            sectionGap = 14
        case .menuBar:
            cpuHeight = 148
            handsOnHeight = 44
            batteryHeight = 42
            memoryHeight = 32
            sectionGap = 8
        }
    }

    var sectionCount: Int {
        2 + (showsBattery ? 1 : 0) + (showsMemory ? 1 : 0)
    }

    var totalHeight: CGFloat {
        cpuHeight
            + handsOnHeight
            + (showsBattery ? batteryHeight : 0)
            + (showsMemory ? memoryHeight : 0)
            + CGFloat(max(0, sectionCount - 1)) * sectionGap
    }

    func rects(in size: CGSize) -> UnifiedTimelineRects {
        let plotWidth = max(1, size.width - rightAxisWidth)
        var y: CGFloat = 0
        let cpu = CGRect(x: 0, y: y, width: plotWidth, height: cpuHeight)
        y += cpuHeight + sectionGap
        let handsOn = CGRect(x: 0, y: y, width: plotWidth, height: handsOnHeight)
        y += handsOnHeight

        var battery: CGRect?
        if showsBattery {
            y += sectionGap
            battery = CGRect(x: 0, y: y, width: plotWidth, height: batteryHeight)
            y += batteryHeight
        }

        var memory: CGRect?
        if showsMemory {
            y += sectionGap
            memory = CGRect(x: 0, y: y, width: plotWidth, height: memoryHeight)
        }
        return UnifiedTimelineRects(
            plotWidth: plotWidth,
            cpu: cpu,
            handsOn: handsOn,
            battery: battery,
            memory: memory
        )
    }
}

private struct UnifiedTimelineRects {
    let plotWidth: CGFloat
    let cpu: CGRect
    let handsOn: CGRect
    let battery: CGRect?
    let memory: CGRect?
}

private struct ProcessorTrendPoint: Equatable {
    let segment: Int
    let timestamp: Date
    let cpuPercent: Double
    let performanceCorePercent: Double?
    let efficiencyCorePercent: Double?
    let performanceCoreContributionPercent: Double?
    let gpuPercent: Double?
}

private struct ProcessorBucketKey: Hashable {
    let segment: Int
    let bucket: Int
}

private struct MemoryConditionTimeline: Equatable {
    let observed: [DateInterval]
    let elevated: [DateInterval]
    let constrained: [DateInterval]
}

private struct UnifiedDataCanvas: View, Equatable {
    let samples: [SystemSample]
    let processorTrend: [ProcessorTrendPoint]
    let memoryConditions: MemoryConditionTimeline
    let batteryRuns: [BatteryTimelineRun]
    let sleepIntervals: [DateInterval]
    let interval: DateInterval
    let processorScaleMaximum: Double
    let layout: UnifiedTimelineLayout

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.samples == rhs.samples
            && lhs.processorTrend == rhs.processorTrend
            && lhs.memoryConditions == rhs.memoryConditions
            && lhs.batteryRuns == rhs.batteryRuns
            && lhs.sleepIntervals == rhs.sleepIntervals
            && lhs.interval == rhs.interval
            && lhs.processorScaleMaximum == rhs.processorScaleMaximum
            && lhs.layout == rhs.layout
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            let rects = layout.rects(in: size)
            drawTrackBackgrounds(in: &context, rects: rects)
            drawProcessorGrid(in: &context, rect: rects.cpu, rightAxisX: rects.plotWidth)
            drawConfirmedSleep(in: &context, size: size, plotWidth: rects.plotWidth)
            drawProcessorMemory(in: &context, rect: rects.cpu)
            drawProcessor(in: &context, rect: rects.cpu)
            drawSeriousHeat(in: &context, rect: rects.cpu)
            drawHandsOn(in: &context, rect: rects.handsOn)
            if let battery = rects.battery {
                drawBattery(in: &context, rect: battery, rightAxisX: rects.plotWidth)
            }
            if let memory = rects.memory {
                drawMemory(in: &context, rect: memory)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Click or drag across any row to inspect the same moment in every signal.")
    }

    private func drawTrackBackgrounds(in context: inout GraphicsContext, rects: UnifiedTimelineRects) {
        context.fill(Path(rects.cpu), with: .color(.secondary.opacity(0.012)))
        context.fill(
            Path(roundedRect: rects.handsOn, cornerRadius: 4),
            with: .color(TimelineColors.handsOn.opacity(0.035))
        )
        if let battery = rects.battery {
            context.fill(
                Path(roundedRect: battery, cornerRadius: 4),
                with: .color(TimelineColors.battery.opacity(0.035))
            )
        }
        if let memory = rects.memory {
            context.fill(
                Path(roundedRect: memory, cornerRadius: 4),
                with: .color(TimelineColors.memory.opacity(0.035))
            )
        }
    }

    private func drawProcessorGrid(
        in context: inout GraphicsContext,
        rect: CGRect,
        rightAxisX: CGFloat
    ) {
        let plot = rect.insetBy(dx: 0, dy: 6)
        let values = processorScaleMaximum == 50 ? [0.0, 25.0, 50.0] : [0.0, 50.0, 100.0]
        let hasClippedPeaks = processorTrend.contains {
            $0.cpuPercent > processorScaleMaximum || ($0.gpuPercent ?? 0) > processorScaleMaximum
        }
        for value in values {
            let y = processorYPosition(value, in: plot)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(
                path,
                with: .color(.secondary.opacity(value == 50 ? 0.16 : 0.09)),
                lineWidth: 1
            )
            context.draw(
                Text(value == processorScaleMaximum && hasClippedPeaks ? "\(Int(value))%+" : "\(Int(value))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: rightAxisX + 6, y: y),
                anchor: .leading
            )
        }
    }

    private func drawConfirmedSleep(
        in context: inout GraphicsContext,
        size: CGSize,
        plotWidth: CGFloat
    ) {
        for sleep in sleepIntervals {
            let x = xPosition(sleep.start, plotWidth: plotWidth)
            let width = max(2, xPosition(sleep.end, plotWidth: plotWidth) - x)
            let rect = CGRect(x: x, y: 0, width: width, height: size.height)
            let fade = min(0.22, max(0.04, 12 / width))
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .secondary.opacity(0), location: 0),
                        .init(color: .secondary.opacity(0.032), location: fade),
                        .init(color: .secondary.opacity(0.032), location: 1 - fade),
                        .init(color: .secondary.opacity(0), location: 1)
                    ]),
                    startPoint: CGPoint(x: rect.minX, y: rect.midY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                )
            )

            if width >= 210 {
                context.draw(
                    Text("Mac asleep · apps and agents paused")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary.opacity(0.72)),
                    at: CGPoint(x: rect.midX, y: rect.minY + 10),
                    anchor: .top
                )
            }
        }
    }

    private func drawProcessor(in context: inout GraphicsContext, rect: CGRect) {
        let plot = rect.insetBy(dx: 0, dy: 6)
        let grouped = Dictionary(
            grouping: processorTrend.filter { $0.timestamp >= interval.start && $0.timestamp <= interval.end },
            by: \.segment
        )
        for segment in grouped.keys.sorted() {
            guard let values = grouped[segment]?.sorted(by: { $0.timestamp < $1.timestamp }),
                  !values.isEmpty else { continue }

            let cpuPoints = values.map { point in
                CGPoint(
                    x: xPosition(point.timestamp, plotWidth: plot.width),
                    y: processorYPosition(point.cpuPercent, in: plot)
                )
            }

            var graphicsRuns: [[CGPoint]] = []
            var currentGraphicsRun: [CGPoint] = []
            for point in values {
                guard let gpu = point.gpuPercent else {
                    if !currentGraphicsRun.isEmpty {
                        graphicsRuns.append(currentGraphicsRun)
                        currentGraphicsRun = []
                    }
                    continue
                }
                currentGraphicsRun.append(CGPoint(
                    x: xPosition(point.timestamp, plotWidth: plot.width),
                    y: processorYPosition(gpu, in: plot)
                ))
            }
            if !currentGraphicsRun.isEmpty {
                graphicsRuns.append(currentGraphicsRun)
            }

            let cpuDisplayPoints = smoothedProcessorPoints(cpuPoints)
            let graphicsDisplayRuns = graphicsRuns.map(smoothedProcessorPoints)

            var coreSplitRuns: [(cpu: [CGPoint], efficiencyBoundary: [CGPoint])] = []
            var currentCoreCPU: [CGPoint] = []
            var currentEfficiencyBoundary: [CGPoint] = []
            func finishCoreRun() {
                guard currentCoreCPU.count >= 2 else {
                    currentCoreCPU.removeAll(keepingCapacity: true)
                    currentEfficiencyBoundary.removeAll(keepingCapacity: true)
                    return
                }
                coreSplitRuns.append((
                    smoothedProcessorPoints(currentCoreCPU),
                    smoothedProcessorPoints(currentEfficiencyBoundary)
                ))
                currentCoreCPU = []
                currentEfficiencyBoundary = []
            }
            for point in values {
                guard let performanceContribution = point.performanceCoreContributionPercent else {
                    finishCoreRun()
                    continue
                }
                let x = xPosition(point.timestamp, plotWidth: plot.width)
                let boundedPerformance = min(point.cpuPercent, max(0, performanceContribution))
                let efficiencyContribution = max(0, point.cpuPercent - boundedPerformance)
                currentCoreCPU.append(CGPoint(
                    x: x,
                    y: processorYPosition(point.cpuPercent, in: plot)
                ))
                currentEfficiencyBoundary.append(CGPoint(
                    x: x,
                    y: processorYPosition(efficiencyContribution, in: plot)
                ))
            }
            finishCoreRun()

            drawProcessorArea(
                cpuDisplayPoints,
                color: TimelineColors.processor,
                topOpacity: coreSplitRuns.isEmpty ? 0.095 : 0.048,
                in: &context,
                plot: plot
            )
            for run in coreSplitRuns {
                // One blue language, two quiet densities: the lower wash is the
                // efficiency-core share; the stronger upper wash is performance-core work.
                drawProcessorArea(
                    run.efficiencyBoundary,
                    color: TimelineColors.processor,
                    topOpacity: 0.038,
                    in: &context,
                    plot: plot
                )
                drawProcessorBand(
                    upper: run.cpu,
                    lower: run.efficiencyBoundary,
                    color: TimelineColors.processor,
                    opacity: 0.072,
                    in: &context,
                    plot: plot
                )
            }
            for run in graphicsDisplayRuns {
                drawProcessorArea(
                    run,
                    color: TimelineColors.graphics,
                    topOpacity: 0.08,
                    in: &context,
                    plot: plot
                )
            }

            drawProcessorLine(
                cpuDisplayPoints,
                color: TimelineColors.processor,
                lineWidth: 1.9,
                in: &context,
                plot: plot
            )
            drawProcessorUrgency(
                cpuDisplayPoints,
                sourcePoints: cpuPoints,
                in: &context,
                plot: plot
            )
            for (runIndex, run) in graphicsDisplayRuns.enumerated() {
                drawProcessorLine(
                    run,
                    color: TimelineColors.graphics,
                    lineWidth: 1.8,
                    in: &context,
                    plot: plot
                )
                drawProcessorUrgency(
                    run,
                    sourcePoints: graphicsRuns[runIndex],
                    in: &context,
                    plot: plot
                )
            }
        }
    }

    /// Two bounded corner-cutting passes make interval averages easier to scan
    /// without overshooting the measured range or joining separate data runs.
    private func smoothedProcessorPoints(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        func cornerCut(_ input: [CGPoint]) -> [CGPoint] {
            guard let first = input.first, let last = input.last else { return input }
            var result: [CGPoint] = [first]
            result.reserveCapacity(input.count * 2)
            for index in 0..<(input.count - 1) {
                let start = input[index]
                let end = input[index + 1]
                result.append(CGPoint(
                    x: start.x * 0.75 + end.x * 0.25,
                    y: start.y * 0.75 + end.y * 0.25
                ))
                result.append(CGPoint(
                    x: start.x * 0.25 + end.x * 0.75,
                    y: start.y * 0.25 + end.y * 0.75
                ))
            }
            result.append(last)
            return result
        }
        return cornerCut(cornerCut(points))
    }

    private func drawProcessorArea(
        _ points: [CGPoint],
        color: Color,
        topOpacity: Double,
        in context: inout GraphicsContext,
        plot: CGRect
    ) {
        guard points.count >= 2, let first = points.first, let last = points.last else { return }
        var area = Path()
        area.move(to: first)
        for point in points.dropFirst() { area.addLine(to: point) }
        area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
        area.addLine(to: CGPoint(x: first.x, y: plot.maxY))
        area.closeSubpath()

        context.fill(
            area,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: color.opacity(topOpacity), location: 0),
                    .init(color: color.opacity(topOpacity * 0.72), location: 0.40),
                    .init(color: color.opacity(topOpacity * 0.08), location: 1)
                ]),
                startPoint: CGPoint(x: plot.midX, y: plot.minY),
                endPoint: CGPoint(x: plot.midX, y: plot.maxY)
            )
        )
    }

    private func drawProcessorBand(
        upper: [CGPoint],
        lower: [CGPoint],
        color: Color,
        opacity: Double,
        in context: inout GraphicsContext,
        plot: CGRect
    ) {
        guard upper.count >= 2, upper.count == lower.count,
              let first = upper.first, let last = upper.last else { return }
        var band = Path()
        band.move(to: first)
        for point in upper.dropFirst() { band.addLine(to: point) }
        for point in lower.reversed() { band.addLine(to: point) }
        band.closeSubpath()
        context.fill(
            band,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: color.opacity(opacity), location: 0),
                    .init(color: color.opacity(opacity * 0.68), location: 0.58),
                    .init(color: color.opacity(opacity * 0.22), location: 1)
                ]),
                startPoint: CGPoint(x: (first.x + last.x) / 2, y: plot.minY),
                endPoint: CGPoint(x: (first.x + last.x) / 2, y: plot.maxY)
            )
        )
    }

    private func drawProcessorLine(
        _ points: [CGPoint],
        color: Color,
        lineWidth: CGFloat,
        in context: inout GraphicsContext,
        plot: CGRect
    ) {
        guard points.count >= 2, let first = points.first, let last = points.last else { return }
        var line = Path()
        line.move(to: first)
        for point in points.dropFirst() { line.addLine(to: point) }
        let width = max(1, last.x - first.x)
        let fadeFraction = min(0.20, max(0.035, 14 / width))
        let fadesIn = first.x > plot.minX + 2
        let fadesOut = last.x < plot.maxX - 2
        var mainStops: [Gradient.Stop] = [
            .init(color: color.opacity(fadesIn ? 0.16 : 0.90), location: 0)
        ]
        if fadesIn {
            mainStops.append(.init(color: color.opacity(0.90), location: fadeFraction))
        }
        if fadesOut {
            mainStops.append(.init(color: color.opacity(0.90), location: 1 - fadeFraction))
        }
        mainStops.append(.init(color: color.opacity(fadesOut ? 0.16 : 0.90), location: 1))
        let mainShading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: mainStops),
            startPoint: CGPoint(x: first.x, y: plot.midY),
            endPoint: CGPoint(x: last.x, y: plot.midY)
        )
        context.stroke(
            line,
            with: .color(color.opacity(0.085)),
            style: StrokeStyle(lineWidth: lineWidth + 3.2, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            line,
            with: mainShading,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawProcessorUrgency(
        _ points: [CGPoint],
        sourcePoints: [CGPoint],
        in context: inout GraphicsContext,
        plot: CGRect
    ) {
        guard points.count >= 2, sourcePoints.count >= 2 else { return }
        var criticalRanges: [ClosedRange<CGFloat>] = []
        for index in 1..<sourcePoints.count {
            let start = sourcePoints[index - 1]
            let end = sourcePoints[index]
            let startValue = processorValue(at: start.y, in: plot)
            let endValue = processorValue(at: end.y, in: plot)
            guard max(startValue, endValue) >= 85 else { continue }
            let range = min(start.x, end.x)...max(start.x, end.x)
            if let previous = criticalRanges.last, range.lowerBound <= previous.upperBound + 0.5 {
                criticalRanges[criticalRanges.count - 1] = previous.lowerBound...max(previous.upperBound, range.upperBound)
            } else {
                criticalRanges.append(range)
            }
        }

        for range in criticalRanges {
            let run = clippedPolyline(points, to: range)
            guard run.count >= 2 else { continue }
            var segment = Path()
            segment.move(to: run[0])
            for point in run.dropFirst() { segment.addLine(to: point) }
            context.stroke(
                segment,
                with: .color(TimelineColors.critical.opacity(0.16)),
                style: StrokeStyle(lineWidth: 5.2, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                segment,
                with: .color(TimelineColors.critical.opacity(0.96)),
                style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func clippedPolyline(
        _ points: [CGPoint],
        to range: ClosedRange<CGFloat>
    ) -> [CGPoint] {
        guard points.count >= 2 else { return [] }
        var result: [CGPoint] = []
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            guard end.x >= range.lowerBound, start.x <= range.upperBound else { continue }
            let clippedStartX = max(start.x, range.lowerBound)
            let clippedEndX = min(end.x, range.upperBound)
            guard clippedEndX >= clippedStartX else { continue }
            let dx = end.x - start.x
            let startFraction = dx > 0 ? (clippedStartX - start.x) / dx : 0
            let endFraction = dx > 0 ? (clippedEndX - start.x) / dx : 0
            let clippedStart = CGPoint(
                x: clippedStartX,
                y: start.y + (end.y - start.y) * startFraction
            )
            let clippedEnd = CGPoint(
                x: clippedEndX,
                y: start.y + (end.y - start.y) * endFraction
            )
            if result.last != clippedStart { result.append(clippedStart) }
            if result.last != clippedEnd { result.append(clippedEnd) }
        }
        return result
    }

    private func drawProcessorMemory(in context: inout GraphicsContext, rect: CGRect) {
        let plot = rect.insetBy(dx: 0, dy: 6)
        let sustained = TimelineSemantics.sustainedMemoryConstraints(
            in: memoryConditions.constrained
        )
        let brief = memoryConditions.constrained.filter { !sustained.contains($0) }
        drawProcessorMemoryRuns(
            brief,
            in: &context,
            plot: plot,
            color: TimelineColors.memory,
            bandOpacity: 0.055
        )
        drawProcessorMemoryRuns(
            sustained,
            in: &context,
            plot: plot,
            color: TimelineColors.critical,
            bandOpacity: 0.085
        )
    }

    private func drawProcessorMemoryRuns(
        _ runs: [DateInterval],
        in context: inout GraphicsContext,
        plot: CGRect,
        color: Color,
        bandOpacity: Double
    ) {
        let rawSpans = runs.map { run in
            (
                start: xPosition(run.start, plotWidth: plot.width),
                end: xPosition(run.end, plotWidth: plot.width)
            )
        }
        var spans: [(start: CGFloat, end: CGFloat)] = []
        for span in rawSpans.sorted(by: { $0.start < $1.start }) {
            if let previous = spans.last, span.start - previous.end <= 5 {
                spans[spans.count - 1].end = max(previous.end, span.end)
            } else {
                spans.append(span)
            }
        }

        for span in spans {
            let rawStart = span.start
            let rawEnd = span.end
            let center = (rawStart + rawEnd) / 2
            let width = min(plot.width, max(5, rawEnd - rawStart))
            let x = min(max(plot.minX, center - width / 2), max(plot.minX, plot.maxX - width))
            let band = CGRect(x: x, y: plot.minY, width: width, height: plot.height)
            let fade = min(0.38, max(0.10, 3 / max(1, width)))
            context.fill(
                Path(roundedRect: band, cornerRadius: 2),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(0), location: 0),
                        .init(color: color.opacity(bandOpacity), location: fade),
                        .init(color: color.opacity(bandOpacity), location: 1 - fade),
                        .init(color: color.opacity(0), location: 1)
                    ]),
                    startPoint: CGPoint(x: band.minX, y: band.midY),
                    endPoint: CGPoint(x: band.maxX, y: band.midY)
                )
            )
        }
    }

    private func drawSeriousHeat(in context: inout GraphicsContext, rect: CGRect) {
        let bucketCount = visualBucketCount(for: rect.width)
        var buckets = Set<Int>()
        for point in samples where point.thermalLevel == .serious || point.thermalLevel == .critical {
            guard point.duration > 0 else { continue }
            let start = max(interval.start, point.timestamp.addingTimeInterval(-point.duration))
            let end = min(interval.end, point.timestamp)
            guard end > start else { continue }
            let first = visualBucketIndex(for: start, count: bucketCount)
            let last = visualBucketIndex(for: end, count: bucketCount)
            for index in first...last { buckets.insert(index) }
        }
        for index in buckets.sorted() {
            let horizontal = visualBucketRect(index: index, count: bucketCount, plotWidth: rect.width)
            let cap = CGRect(x: horizontal.minX, y: rect.minY, width: horizontal.width, height: 3)
            context.fill(Path(roundedRect: cap, cornerRadius: 1.5), with: .color(.red.opacity(0.78)))
        }
    }

    private func drawHandsOn(in context: inout GraphicsContext, rect: CGRect) {
        let bucketCount = visualBucketCount(for: rect.width)
        var valuesByBucket: [Int: [Double]] = [:]
        for point in samples where point.duration > 0 {
            guard let intensity = point.manualActivity?.intensity(over: point.duration) else { continue }
            let index = visualBucketIndex(for: point.timestamp, count: bucketCount)
            valuesByBucket[index, default: []].append(intensity)
        }

        for index in valuesByBucket.keys.sorted() {
            guard let values = valuesByBucket[index], !values.isEmpty else { continue }
            let average = values.reduce(0, +) / Double(values.count)
            let peak = values.max() ?? 0
            let intensity = min(1, max(average, peak * 0.60))
            let horizontal = visualBucketRect(index: index, count: bucketCount, plotWidth: rect.width)
            let availableHeight = max(2, rect.height - 5)
            let height = max(1.5, availableHeight * CGFloat(min(1, max(0, intensity))))
            let bar = CGRect(
                x: horizontal.minX,
                y: rect.maxY - height - 2,
                width: horizontal.width,
                height: height
            )
            let opacity = intensity < 0.04 ? 0.18 : 0.30 + min(0.55, intensity * 0.55)
            context.fill(
                Path(roundedRect: bar, cornerRadius: 1),
                with: .color(TimelineColors.handsOn.opacity(opacity))
            )
        }
    }

    private func drawBattery(
        in context: inout GraphicsContext,
        rect: CGRect,
        rightAxisX: CGFloat
    ) {
        let plot = rect.insetBy(dx: 0, dy: 5)
        let domain = batteryDomain
        for value in [domain.lowerBound, domain.upperBound] {
            let y = batteryYPosition(value, in: plot, domain: domain)
            context.draw(
                Text("\(Int(value.rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: rightAxisX + 6, y: y),
                anchor: .leading
            )
        }

        for run in batteryRuns {
            let readings = summarizedBatteryReadings(run.readings, plotWidth: plot.width)
            guard let first = readings.first else { continue }
            if readings.count == 1 {
                let center = CGPoint(
                    x: xPosition(first.timestamp, plotWidth: plot.width),
                    y: batteryYPosition(first.percent, in: plot, domain: domain)
                )
                let dot = CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: dot), with: .color(TimelineColors.battery))
                continue
            }

            var line = Path()
            for (index, reading) in readings.enumerated() {
                let position = CGPoint(
                    x: xPosition(reading.timestamp, plotWidth: plot.width),
                    y: batteryYPosition(reading.percent, in: plot, domain: domain)
                )
                if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
            }
            context.stroke(
                line,
                with: .color(TimelineColors.battery),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawMemory(in context: inout GraphicsContext, rect: CGRect) {
        let y = rect.midY
        let sustained = TimelineSemantics.sustainedMemoryConstraints(
            in: memoryConditions.constrained
        )
        let brief = memoryConditions.constrained.filter { !sustained.contains($0) }
        drawMemoryBaselineRuns(
            memoryConditions.observed,
            in: &context,
            y: y,
            plotWidth: rect.width,
            color: TimelineColors.memory.opacity(0.70),
            lineWidth: 2.2
        )
        drawMemoryConditionRuns(
            memoryConditions.elevated,
            in: &context,
            y: y,
            plotWidth: rect.width,
            color: TimelineColors.memory.opacity(0.86),
            height: 7
        )
        drawMemoryConditionRuns(
            brief,
            in: &context,
            y: y,
            plotWidth: rect.width,
            color: TimelineColors.memory.opacity(0.96),
            height: 9
        )
        drawMemoryConditionRuns(
            sustained,
            in: &context,
            y: y,
            plotWidth: rect.width,
            color: .red.opacity(0.95),
            height: 10
        )
    }

    private func drawMemoryBaselineRuns(
        _ runs: [DateInterval],
        in context: inout GraphicsContext,
        y: CGFloat,
        plotWidth: CGFloat,
        color: Color,
        lineWidth: CGFloat
    ) {
        for run in runs {
            var path = Path()
            let startX = xPosition(run.start, plotWidth: plotWidth)
            let endX = max(startX + 1, xPosition(run.end, plotWidth: plotWidth))
            path.move(to: CGPoint(x: startX, y: y))
            path.addLine(to: CGPoint(x: endX, y: y))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }
    }

    private func drawMemoryConditionRuns(
        _ runs: [DateInterval],
        in context: inout GraphicsContext,
        y: CGFloat,
        plotWidth: CGFloat,
        color: Color,
        height: CGFloat
    ) {
        for run in runs {
            let rawStart = xPosition(run.start, plotWidth: plotWidth)
            let rawEnd = xPosition(run.end, plotWidth: plotWidth)
            let center = (rawStart + rawEnd) / 2
            let width = max(4, rawEnd - rawStart)
            let x = min(max(0, center - width / 2), max(0, plotWidth - width))
            let marker = CGRect(x: x, y: y - height / 2, width: width, height: height)
            context.fill(
                Path(roundedRect: marker, cornerRadius: min(2, height / 3)),
                with: .color(color)
            )
        }
    }

    private func summarizedBatteryReadings(
        _ readings: [BatteryTimelineReading],
        plotWidth: CGFloat
    ) -> [BatteryTimelineReading] {
        guard readings.count > 2 else { return readings }
        let bucketCount = visualBucketCount(for: plotWidth)
        let grouped = Dictionary(grouping: readings) {
            visualBucketIndex(for: $0.timestamp, count: bucketCount)
        }
        var result = grouped.keys.sorted().compactMap { grouped[$0]?.last }
        if let first = readings.first, result.first?.id != first.id { result.insert(first, at: 0) }
        if let last = readings.last, result.last?.id != last.id { result.append(last) }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    private func visualBucketCount(for plotWidth: CGFloat) -> Int {
        max(24, min(160, Int((plotWidth / 5.5).rounded(.down))))
    }

    private func visualBucketIndex(for date: Date, count: Int) -> Int {
        let fraction = min(1, max(0, date.timeIntervalSince(interval.start) / max(1, interval.duration)))
        return min(count - 1, max(0, Int(fraction * Double(count))))
    }

    private func visualBucketRect(index: Int, count: Int, plotWidth: CGFloat) -> CGRect {
        let width = plotWidth / CGFloat(max(1, count))
        let gap = min(1.2, width * 0.18)
        return CGRect(
            x: CGFloat(index) * width + gap / 2,
            y: 0,
            width: max(1.2, width - gap),
            height: 1
        )
    }

    private func xPosition(_ date: Date, plotWidth: CGFloat) -> CGFloat {
        let fraction = min(1, max(0, date.timeIntervalSince(interval.start) / max(1, interval.duration)))
        return plotWidth * CGFloat(fraction)
    }

    private func processorYPosition(_ value: Double, in rect: CGRect) -> CGFloat {
        rect.maxY - rect.height * CGFloat(min(processorScaleMaximum, max(0, value)) / processorScaleMaximum)
    }

    private func processorValue(at y: CGFloat, in rect: CGRect) -> Double {
        let fraction = min(1, max(0, (rect.maxY - y) / max(1, rect.height)))
        return Double(fraction) * processorScaleMaximum
    }

    private func batteryYPosition(
        _ value: Double,
        in rect: CGRect,
        domain: ClosedRange<Double>
    ) -> CGFloat {
        let fraction = (value - domain.lowerBound) / max(1, domain.upperBound - domain.lowerBound)
        return rect.maxY - rect.height * CGFloat(min(1, max(0, fraction)))
    }

    /// A stable 50-point battery scale keeps ordinary movement readable without
    /// making a small change fill the entire track. Crossing below 50% expands
    /// the honest scale to the full 0...100 range.
    private var batteryDomain: ClosedRange<Double> {
        let values = batteryRuns.flatMap(\.readings).map(\.percent)
        guard let minimum = values.min() else { return 0...100 }
        return minimum >= 50 ? 50...100 : 0...100
    }

    private var accessibilitySummary: String {
        var summary = "A shared timeline aligns whole-machine CPU demand and physical input."
        if processorTrend.contains(where: { $0.gpuPercent != nil }) {
            summary += " A second solid line shows the optional graphics-driver activity estimate on the same scale."
        }
        if processorTrend.contains(where: { $0.performanceCoreContributionPercent != nil }) {
            summary += " Two subtle blue densities inside the CPU fill divide performance-core and efficiency-core contributions; exact cluster utilization appears only when inspecting a moment."
        }
        if processorScaleMaximum == 50 {
            summary += " The processor plot uses a zero-to-fifty-percent scale; rarer higher peaks touch the fifty-percent-plus cap."
        }
        if !sleepIntervals.isEmpty { summary += " Gray bands show confirmed Mac sleep, when normal app and agent work is paused." }
        if layout.showsBattery && !batteryRuns.isEmpty {
            summary += " Battery level appears only during unplugged periods."
        }
        let sustainedMemory = TimelineSemantics.sustainedMemoryConstraints(
            in: memoryConditions.constrained
        )
        let briefMemory = memoryConditions.constrained.filter { !sustainedMemory.contains($0) }
        if !memoryConditions.elevated.isEmpty || !briefMemory.isEmpty {
            summary += " Neutral gray bands show elevated or brief memory pressure that is worth watching but not constrained."
        }
        if !sustainedMemory.isEmpty {
            summary += " Red bands indicate memory constrained for at least two minutes, when slowdown is more likely."
        }
        if samples.contains(where: { $0.thermalLevel == .serious || $0.thermalLevel == .critical }) {
            summary += " A red cap marks heat high enough that macOS may reduce speed."
        }
        return summary
    }
}

private struct TimelineSelectionOverlay: View {
    @Binding var selectedTime: Date?
    let interval: DateInterval
    let rightAxisWidth: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
                guard let selectedTime else { return }
                let plotWidth = max(1, size.width - rightAxisWidth)
                let fraction = min(1, max(0, selectedTime.timeIntervalSince(interval.start) / max(1, interval.duration)))
                let x = plotWidth * CGFloat(fraction)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    line,
                    with: .color(.primary.opacity(0.46)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )

                var marker = Path()
                marker.move(to: CGPoint(x: x - 4, y: 0))
                marker.addLine(to: CGPoint(x: x + 4, y: 0))
                marker.addLine(to: CGPoint(x: x, y: 5))
                marker.closeSubpath()
                context.fill(marker, with: .color(.primary.opacity(0.58)))
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        updateSelection(
                            at: value.location.x,
                            totalWidth: geometry.size.width,
                            togglesCurrentMarker: true
                        )
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                        updateSelection(at: value.location.x, totalWidth: geometry.size.width)
                    }
            )
        }
        .accessibilityHidden(true)
    }

    private func updateSelection(
        at x: CGFloat,
        totalWidth: CGFloat,
        togglesCurrentMarker: Bool = false
    ) {
        let plotWidth = max(1, totalWidth - rightAxisWidth)
        if togglesCurrentMarker, let selectedTime {
            let selectedFraction = min(1, max(
                0,
                selectedTime.timeIntervalSince(interval.start) / max(1, interval.duration)
            ))
            let selectedX = plotWidth * CGFloat(selectedFraction)
            if abs(selectedX - x) <= 9 {
                self.selectedTime = nil
                return
            }
        }
        let fraction = min(1, max(0, x / plotWidth))
        selectedTime = interval.start.addingTimeInterval(interval.duration * Double(fraction))
    }
}

private struct TimelineInspector: View {
    let selection: TimelineSelection
    let time: Date
    let background: [BackgroundActivityPoint]
    let batteryRun: BatteryTimelineRun?
    let previousSample: SystemSample?
    let isSustainedMemoryConstraint: Bool
    let onDismiss: () -> Void

    @ViewBuilder
    var body: some View {
        switch selection {
        case .sleep(let interval):
            stateMessage(
                symbol: "moon.fill",
                title: "Mac asleep",
                detail: "Normal app and agent work paused for \(Formatters.duration(interval.duration)). No activity or power readings are inferred inside this band."
            )
        case .unrecorded:
            stateMessage(
                symbol: "clock.badge.questionmark",
                title: "Not recorded",
                detail: "No reading covers this moment. MY MACHINE leaves the gap blank instead of guessing."
            )
        case .observed(let sample):
            observedInspector(sample)
        }
    }

    private func stateMessage(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(time.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.semibold).monospacedDigit())
                    Text(title)
                        .font(.caption.weight(.medium))
                }
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 32)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            dismissButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private func observedInspector(_ sample: SystemSample) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(handsOnMeaning(sample))
                    .font(.caption.weight(.medium))
                Text("\(sample.foregroundApp) in front")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 112, alignment: .leading)

            Divider().frame(height: 36)
            inspectorItem(sample.gpuPercent == nil ? "Processor" : "CPU / GPU", processorMeaning(sample))
            inspectorItem("Memory", memoryMeaning(sample, previous: previousSample))
            inspectorItem("Power", powerMeaning(sample))
            inspectorItem("Background", backgroundMeaning)
            Spacer(minLength: 0)
            dismissButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Label("Now", systemImage: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .keyboardShortcut(.cancelAction)
        .help("Clear selection and return to the current status")
        .accessibilityLabel("Return to current status")
    }

    private func inspectorItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func handsOnMeaning(_ sample: SystemSample) -> String {
        guard let activity = sample.manualActivity else {
            return sample.isIdle ? "No recent input" : "Recently active"
        }
        switch activity.intensity(over: sample.duration) {
        case 0..<0.04: return "No recent input"
        case ..<0.18: return "Light physical input"
        case ..<0.50: return "Steady physical input"
        case ..<0.75: return "Intense physical input"
        default: return "Very intense input"
        }
    }

    private func processorMeaning(_ sample: SystemSample) -> String {
        let level: String
        switch sample.cpuPercent {
        case ..<25: level = "Light"
        case ..<60: level = "Moderate"
        default: level = "Heavy"
        }
        var parts = ["CPU \(level.lowercased()) · \(Formatters.percent(sample.cpuPercent))"]
        if let performance = sample.performanceCorePercent,
           let efficiency = sample.efficiencyCorePercent {
            parts.append("P cores \(Formatters.percent(performance)) · E cores \(Formatters.percent(efficiency))")
        }
        if let gpu = sample.gpuPercent { parts.append("GPU \(Formatters.percent(gpu)) est.") }
        return parts.joined(separator: " · ")
    }

    private func memoryMeaning(_ sample: SystemSample, previous: SystemSample?) -> String {
        let condition: String
        switch sample.memoryPressure {
        case .low: condition = "Comfortable"
        case .elevated: condition = "Elevated · switching may slow"
        case .high:
            condition = isSustainedMemoryConstraint
                ? "Constrained · slowdown likely"
                : "Brief pressure · watching"
        }

        let usedPercent: Double
        if sample.memoryTotalBytes > 0 {
            usedPercent = Double(sample.memoryUsedBytes) / Double(sample.memoryTotalBytes) * 100
        } else {
            usedPercent = 0
        }
        let swap = Formatters.bytes(sample.swapUsedBytes)
        guard let previous else {
            return "\(condition) · \(Formatters.percent(usedPercent)) used · swap \(swap)"
        }
        let change = Int64(clamping: sample.swapUsedBytes) - Int64(clamping: previous.swapUsedBytes)
        if change > 128_000_000 {
            return "\(condition) · \(Formatters.percent(usedPercent)) used · swap growing to \(swap)"
        }
        if change < -128_000_000 {
            return "\(condition) · \(Formatters.percent(usedPercent)) used · swap falling to \(swap)"
        }
        return "\(condition) · \(Formatters.percent(usedPercent)) used · swap steady at \(swap)"
    }

    private func powerMeaning(_ sample: SystemSample) -> String {
        let heatSuffix: String
        switch sample.thermalLevel {
        case .serious, .critical: heatSuffix = " · heat may limit speed"
        default: heatSuffix = ""
        }

        switch sample.powerSource {
        case .adapter:
            return "Plugged in\(heatSuffix)"
        case .battery:
            guard let percent = sample.batteryPercent else { return "On battery\(heatSuffix)" }
            var result = "On battery · \(Formatters.percent(percent))"
            if let run = batteryRun,
               let first = run.readings.first {
                let readingsSoFar = run.readings.filter { $0.timestamp <= time }
                if let last = readingsSoFar.last,
                   last.timestamp.timeIntervalSince(first.timestamp) >= 20 * 60,
                   last.percent - first.percent <= -0.5 {
                    let change = last.percent - first.percent
                    let points = Int(abs(change).rounded())
                    result += " · down \(points) \(points == 1 ? "point" : "points")"
                }
            }
            return result + heatSuffix
        case .unknown:
            return "Power unavailable\(heatSuffix)"
        }
    }

    private var backgroundMeaning: String {
        guard let first = background.first else { return "No off-screen work stood out" }
        if first.agentWorkerCount > 0 {
            return "\(first.ownerName) · \(first.agentWorkerCount) \(first.agentWorkerCount == 1 ? "worker" : "workers")"
        }
        if first.cpuPercent >= 0.5 || first.diskBytes >= 128_000 {
            return "\(first.ownerName) active"
        }
        return "\(first.ownerName) present"
    }
}
