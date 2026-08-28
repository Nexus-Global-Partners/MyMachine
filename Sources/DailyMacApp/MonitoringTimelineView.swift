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
    let appContributors: [AppComputeContribution]
    let presentation: TimelinePresentation
    let expandedProcessorHeight: CGFloat?
    let displayMode: TimelineDisplayMode

    @State private var selectedTime: Date?

    private let interval: DateInterval
    private let sleepIntervals: [DateInterval]
    private let batteryRuns: [BatteryTimelineRun]
    private let batteryTenPointTiming: BatteryTenPointTiming
    private let showsBatteryTrack: Bool
    private let processorTrend: [ProcessorTrendPoint]
    private let memoryConditions: MemoryConditionTimeline
    private let thermalContext: TimelineThermalContext
    private let presenceContext: TimelinePresenceContext
    private let visibleStress: TimelineVisibleStress
    private let currentProcessorStress: TimelineCurrentProcessorStress
    private let processorScaleMaximum: Double
    private let windowUsageSummary: TimelineWindowUsageSummary
    private let liveProcessorReading: TimelineLiveProcessorReading?
    private let currentActivity: TimelineCurrentActivity?

    init(
        snapshot: MonitoringSnapshot,
        samples: [SystemSample],
        backgroundPoints: [BackgroundActivityPoint],
        events: [ActivityEvent],
        appContributors: [AppComputeContribution] = [],
        presentation: TimelinePresentation = .full,
        expandedProcessorHeight: CGFloat? = nil,
        displayMode: TimelineDisplayMode = .precise
    ) {
        self.snapshot = snapshot
        let orderedSamples = samples.sorted(by: { $0.timestamp < $1.timestamp })
        self.samples = orderedSamples
        self.backgroundPoints = backgroundPoints
        self.events = events
        self.appContributors = appContributors
        self.presentation = presentation
        self.expandedProcessorHeight = expandedProcessorHeight
        self.displayMode = displayMode
        self.interval = snapshot.interval
        let processorTrend = Self.makeProcessorTrend(
            from: orderedSamples,
            within: snapshot.interval,
            range: snapshot.range,
            displayMode: displayMode
        )
        self.processorTrend = processorTrend
        let memoryConditions = Self.makeMemoryConditions(
            from: orderedSamples,
            within: snapshot.interval
        )
        self.memoryConditions = memoryConditions
        self.thermalContext = TimelineSemantics.thermalContext(
            from: orderedSamples,
            within: snapshot.interval
        )
        self.presenceContext = TimelineSemantics.presenceContext(
            from: orderedSamples,
            within: snapshot.interval
        )
        self.visibleStress = TimelineSemantics.visibleStress(
            samples: orderedSamples,
            within: snapshot.interval,
            constrainedMemoryIntervals: memoryConditions.constrained
        )
        self.currentProcessorStress = TimelineSemantics.currentProcessorStress(
            from: orderedSamples,
            relativeTo: snapshot.interval.end
        )
        if displayMode == .precise {
            self.processorScaleMaximum = Self.processorScaleMaximum(for: processorTrend)
        } else {
            let preciseTrend = Self.makeProcessorTrend(
                from: orderedSamples,
                within: snapshot.interval,
                range: snapshot.range,
                displayMode: .precise
            )
            self.processorScaleMaximum = Self.processorScaleMaximum(for: preciseTrend)
        }
        self.windowUsageSummary = TimelineSemantics.windowUsageSummary(
            from: orderedSamples,
            within: snapshot.interval
        )
        self.liveProcessorReading = Self.makeLiveProcessorReading(
            from: orderedSamples,
            endingAt: snapshot.interval.end
        )
        let activityLanes = TimelineSemantics.activityLanes(
            from: orderedSamples,
            background: backgroundPoints,
            within: snapshot.interval,
            limit: presentation == .menuBar ? 2 : 3
        )
        self.currentActivity = Self.makeCurrentActivity(
            samples: orderedSamples,
            backgroundPoints: backgroundPoints,
            lanes: activityLanes,
            endingAt: snapshot.interval.end
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
            && lhs.appContributors == rhs.appContributors
            && lhs.presentation == rhs.presentation
            && lhs.expandedProcessorHeight == rhs.expandedProcessorHeight
            && lhs.displayMode == rhs.displayMode
    }

    var body: some View {
        let layout = UnifiedTimelineLayout(
            showsBattery: showsBatteryTrack,
            showsMemory: presentation != .menuBar,
            presentation: presentation,
            expandedProcessorHeight: expandedProcessorHeight
        )

        Group {
            if usesCalmGraphOnlyLayout {
                calmGraphOnlyBody(layout: layout)
            } else {
                VStack(alignment: .leading, spacing: contentSpacing) {
                    inspector
                        .frame(height: inspectorHeight, alignment: .center)

                    HStack(alignment: .top, spacing: contentSpacing) {
                        labelRail(layout: layout)
                            .frame(width: labelWidth, height: layout.totalHeight, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTime = nil }

                        dataCanvas(layout: layout)
                            .frame(height: layout.totalHeight)
                    }

                    timeAxis
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTime = nil }
                }
            }
        }
        .onChange(of: snapshot.interval) {
            guard let selectedTime else { return }
            if !snapshot.interval.contains(selectedTime) { self.selectedTime = nil }
        }
        .task(id: selectedTime) {
            guard selectedTime != nil else { return }
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            selectedTime = nil
        }
        .accessibilityElement(children: .contain)
    }

    private var usesCalmGraphOnlyLayout: Bool {
        presentation == .menuBar && displayMode == .calm
    }

    private func calmGraphOnlyBody(layout: UnifiedTimelineLayout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            dataCanvas(layout: layout) {
                if let reading = contextProcessorReading {
                    calmProcessorLegend(reading)
                        .padding(.top, 8)
                        .padding(.leading, 10)
                }
            }
            .frame(height: layout.totalHeight)

            timeAxis
                .contentShape(Rectangle())
                .onTapGesture { selectedTime = nil }
        }
    }

    private func dataCanvas<Overlay: View>(
        layout: UnifiedTimelineLayout,
        @ViewBuilder overlay: () -> Overlay
    ) -> some View {
        ZStack(alignment: .topLeading) {
            UnifiedDataCanvas(
                samples: samples,
                processorTrend: processorTrend,
                memoryConditions: memoryConditions,
                thermalContext: thermalContext,
                presenceContext: presenceContext,
                visibleStress: visibleStress,
                batteryRuns: batteryRuns,
                sleepIntervals: sleepIntervals,
                interval: interval,
                processorScaleMaximum: processorScaleMaximum,
                layout: layout,
                displayMode: displayMode
            )
            .equatable()

            TimelineSelectionOverlay(
                selectedTime: $selectedTime,
                interval: interval,
                rightAxisWidth: layout.rightAxisWidth
            )

            overlay()
        }
    }

    private func dataCanvas(layout: UnifiedTimelineLayout) -> some View {
        dataCanvas(layout: layout) { EmptyView() }
    }

    private func calmProcessorLegend(_ reading: TimelineLiveProcessorReading) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: calmStatusSignal.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(calmStatusSignal.label)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(calmStatusSignal.color)

            Divider()
                .frame(height: 12)
                .opacity(0.45)

            calmProcessorLegendMetric(
                title: "CPU",
                value: reading.cpuPercent,
                color: TimelineColors.processor
            )
            if let gpuPercent = reading.gpuPercent {
                calmProcessorLegendMetric(
                    title: "GPU",
                    value: gpuPercent,
                    color: TimelineColors.graphics
                )
            }
            Text(calmProcessorContextLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.05), radius: 5, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(processorAccessibilityLabel(
            reading,
            label: "\(calmStatusSignal.label). \(calmProcessorAccessibilityContext)"
        ))
        .help(calmStatusSignal.help)
    }

    private var calmProcessorContextLabel: String {
        guard let selectedTime else { return "2 min" }
        return selectedTime.formatted(date: .omitted, time: .shortened)
    }

    private var calmProcessorAccessibilityContext: String {
        guard let selectedTime else { return "Live two minute average" }
        let clock = selectedTime.formatted(date: .omitted, time: .shortened)
        return "Selected at \(clock)"
    }

    private var calmStatusSignal: (symbol: String, label: String, color: Color, help: String) {
        if selectedTime != nil {
            switch selectedState {
            case .sleep:
                return ("moon.fill", "Asleep", .secondary, "The Mac was asleep at the selected time.")
            case .unrecorded:
                return ("clock.badge.questionmark", "No data", .secondary, "No reading was recorded at the selected time.")
            case .observed(let sample):
                if sample.thermalLevel == .serious || sample.thermalLevel == .critical {
                    return ("thermometer.high", "Heat", TimelineColors.critical, "Heat may have limited speed at the selected time.")
                }
                if sample.memoryPressure == .high {
                    return ("memorychip", "Memory", TimelineColors.memoryStatus, "Memory pressure was high at the selected time.")
                }
                let processor = max(sample.cpuPercent, sample.gpuPercent ?? 0)
                if processor >= TimelineSemantics.criticalProcessorThreshold {
                    return ("exclamationmark.triangle.fill", "Near limit", TimelineColors.critical, "Processor demand was near capacity at the selected time.")
                }
                if sample.memoryPressure == .elevated || sample.thermalLevel == .fair || processor >= 60 {
                    return ("waveform.path.ecg", "Busy", TimelineColors.active, "Demand was elevated but manageable at the selected time.")
                }
                return ("checkmark.circle", "Comfortable", TimelineColors.normal, "The Mac had comfortable headroom at the selected time.")
            }
        }

        let label: String
        switch currentStatus.tone {
        case .safe: label = "Comfortable"
        case .active: label = "Busy"
        case .memory: label = "Memory"
        case .pressure: label = "Near limit"
        case .unavailable: label = "Waiting"
        }
        return (currentStatus.symbol, label, currentStatus.color, currentStatus.message)
    }

    private func calmProcessorLegendMetric(
        title: String,
        value: Double,
        color: Color
    ) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(color)
                .frame(width: 10, height: 2)
            Text("\(title) \(Formatters.percent(value))")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private var labelWidth: CGFloat {
        switch presentation {
        case .menuBar: return 164
        case .full: return 196
        case .expanded: return 220
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
        case .menuBar: return 44
        case .full: return 44
        case .expanded: return 48
        }
    }

    private func labelRail(layout: UnifiedTimelineLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.sectionGap) {
            processorTrackLabel
            .frame(height: layout.cpuHeight, alignment: .topLeading)

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
                    symbol: "memorychip",
                    emphasis: visibleStress.memoryCriticalIntervals.isEmpty
                        ? nil
                        : TimelineColors.critical
                )
                .frame(height: layout.memoryHeight, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var processorTrackLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            if presentation != .menuBar {
                processorKey(
                    "CPU",
                    meaning: processorMeaning(
                        normal: cpuLabel(snapshot.averageCPU),
                        isCurrentlyCritical: currentProcessorStress.cpuIsCritical
                    ),
                    value: snapshot.averageCPU,
                    color: currentProcessorStress.cpuIsCritical
                        ? TimelineColors.critical
                        : TimelineColors.processor,
                    isCritical: currentProcessorStress.cpuIsCritical
                )
                if let graphicsAverage {
                    processorKey(
                        "GPU",
                        meaning: processorMeaning(
                            normal: gpuLabel(graphicsAverage),
                            isCurrentlyCritical: currentProcessorStress.gpuIsCritical
                        ),
                        value: graphicsAverage,
                        color: currentProcessorStress.gpuIsCritical
                            ? TimelineColors.critical
                            : TimelineColors.graphics,
                        isEstimate: true,
                        isCritical: currentProcessorStress.gpuIsCritical
                    )
                }
            }
            Text(processorWindowPrimary)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(presentation == .menuBar ? 1 : 2)
            if let processorMemoryKey {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(visibleStress.memoryCriticalIntervals.isEmpty
                            ? TimelineColors.memoryElevated
                            : TimelineColors.critical)
                        .frame(width: 10, height: 4)
                    Text(processorMemoryKey)
                        .font(.caption2)
                        .foregroundStyle(visibleStress.memoryCriticalIntervals.isEmpty
                            ? TimelineColors.memoryElevated
                            : TimelineColors.critical)
                        .lineLimit(1)
                }
            }
            if let processorThermalKey {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(processorThermalKey.color)
                    Text(processorThermalKey.text)
                        .font(.caption2)
                        .foregroundStyle(processorThermalKey.color)
                        .lineLimit(1)
                }
                .help("This is macOS thermal-pressure context, not an exact temperature or fan-speed reading.")
            }
            if presentation != .menuBar, let processorWindowImpact {
                Text(processorWindowImpact)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let currentActivity {
                currentActivityRow(currentActivity)
                    .padding(.top, presentation == .menuBar ? 1 : 3)
            }
            if !visibleAppContributors.isEmpty {
                VStack(alignment: .leading, spacing: presentation == .menuBar ? 2 : 4) {
                    Text(presentation == .menuBar ? "MOST ACTIVE APP" : "OBSERVED APP CPU")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.45)
                        .foregroundStyle(.secondary)
                    ForEach(visibleAppContributors) { contributor in
                        appContributorRow(contributor)
                    }
                }
                .padding(.top, presentation == .menuBar ? 1 : 3)
                .help("Share of observed app CPU in this window; this is not the app's share of total whole-machine demand.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var visibleAppContributors: [AppComputeContribution] {
        if presentation == .menuBar {
            return Array(appContributors.filter { $0.observedCPUSharePercent >= 35 }.prefix(1))
        }
        return Array(appContributors.prefix(3))
    }

    private func appContributorRow(_ contributor: AppComputeContribution) -> some View {
        let percentage = min(100, max(0, contributor.observedCPUSharePercent))
        return HStack(spacing: 6) {
            ContributorAppIcon(
                bundleIdentifier: contributor.ownerBundleID,
                ownerName: contributor.ownerName
            )
            .frame(width: presentation == .menuBar ? 15 : 18, height: presentation == .menuBar ? 15 : 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(contributor.ownerName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.86))
                        .lineLimit(1)
                        .help(contributor.ownerName)
                    Spacer(minLength: 2)
                    Text("\(Formatters.percent(percentage)) share")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(Color.primary.opacity(0.42))
                            .frame(width: geometry.size.width * CGFloat(percentage / 100))
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(contributor.ownerName), \(Formatters.percent(percentage)) of observed app CPU in this window")
        .accessibilityHint("This is a share of the app CPU MY MACHINE observed, not total whole-machine demand.")
    }

    private func currentActivityRow(_ activity: TimelineCurrentActivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("CURRENT ACTIVITY")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.45)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ContributorAppIcon(
                    bundleIdentifier: activity.bundleIdentifier,
                    ownerName: activity.appName
                )
                .frame(
                    width: presentation == .menuBar ? 17 : 19,
                    height: presentation == .menuBar ? 17 : 19
                )

                VStack(alignment: .leading, spacing: 0) {
                    Text(activity.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(activity.color)
                        .lineLimit(1)
                    Text(activity.detail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func processorKey(
        _ title: String,
        meaning: String,
        value: Double,
        color: Color,
        isEstimate: Bool = false,
        isCritical: Bool = false
    ) -> some View {
        let identity = "\(title)\(isEstimate ? " est." : "") \(Formatters.percent(value)) avg"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Text(identity)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Text("· \(meaning.lowercased())")
                    .font(.caption2)
                    .foregroundStyle(isCritical ? color : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(identity)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Text(meaning)
                    .font(.caption2)
                    .foregroundStyle(isCritical ? color : Color.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func inlineProcessorReadout(
        _ reading: TimelineLiveProcessorReading,
        label: String
    ) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.45)
                .foregroundStyle(.secondary)

            HStack(spacing: presentation == .menuBar ? 12 : 16) {
                liveProcessorMetric(
                    title: "CPU",
                    value: reading.cpuPercent,
                    color: TimelineColors.processor
                )
                if let gpuPercent = reading.gpuPercent {
                    liveProcessorMetric(
                        title: "GPU",
                        value: gpuPercent,
                        color: TimelineColors.graphics
                    )
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(processorAccessibilityLabel(reading, label: label))
    }

    private func liveProcessorMetric(title: String, value: Double, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
            Text(Formatters.percent(value))
                .font((presentation == .menuBar ? Font.subheadline : Font.body).monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(color)
    }

    private func processorAccessibilityLabel(
        _ reading: TimelineLiveProcessorReading,
        label: String
    ) -> String {
        var description = "\(label), CPU \(Formatters.percent(reading.cpuPercent))"
        if let gpuPercent = reading.gpuPercent {
            description += ", estimated GPU \(Formatters.percent(gpuPercent))"
        }
        return description
    }

    private var processorMemoryKey: String? {
        if !visibleStress.memoryCriticalIntervals.isEmpty {
            return "Memory constrained · \(compactStressDuration(visibleStress.memoryCriticalDuration))"
        }
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

    private var processorThermalKey: (text: String, color: Color)? {
        if thermalContext.criticalDuration > 0 {
            return (
                "Heat limited speed · \(compactStressDuration(thermalContext.criticalDuration))",
                TimelineColors.critical
            )
        }
        if thermalContext.seriousDuration > 0 {
            return (
                "Heat pressure · \(compactStressDuration(thermalContext.seriousDuration))",
                TimelineColors.critical
            )
        }
        if thermalContext.managedDuration > 0 {
            return (
                "Heat being managed · \(compactStressDuration(thermalContext.managedDuration))",
                TimelineColors.thermal
            )
        }
        return nil
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
                if let liveProcessorReading {
                    inlineProcessorReadout(liveProcessorReading, label: "LIVE · 2 MIN")
                }
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
            if let contextProcessorReading {
                Divider()
                    .frame(height: 26)
                    .opacity(0.55)
                inlineProcessorReadout(
                    contextProcessorReading,
                    label: contextProcessorLabel
                )
                .layoutPriority(1)
            }
            Group {
                if selectedTime != nil {
                    Button {
                        selectedTime = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Show current status")
                    .accessibilityLabel("Return to current status")
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 20, height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    compactSurfaceTint.opacity(0.13),
                                    compactSurfaceTint.opacity(0.045)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.82),
                                    compactSurfaceTint.opacity(0.32),
                                    Color.primary.opacity(0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                }
        }
        .shadow(color: compactSurfaceTint.opacity(0.07), radius: 9, y: 2)
        .shadow(color: Color.black.opacity(0.06), radius: 7, y: 2)
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
            return "Memory \(compactMemoryMeaning(sample)) · \(compactPowerMeaning(sample))"
        }
    }

    private var contextProcessorReading: TimelineLiveProcessorReading? {
        guard selectedTime != nil else { return liveProcessorReading }
        guard case .observed(let sample) = selectedState else { return nil }
        return TimelineLiveProcessorReading(
            cpuPercent: sample.cpuPercent.isFinite
                ? min(100, max(0, sample.cpuPercent))
                : 0,
            gpuPercent: sample.gpuPercent.flatMap {
                $0.isFinite ? min(100, max(0, $0)) : nil
            }
        )
    }

    private var contextProcessorLabel: String {
        guard selectedTime != nil else { return "LIVE · 2 MIN" }
        return "SELECTED"
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
        compactSurfaceTint
    }

    private var compactSurfaceTint: Color {
        guard selectedTime != nil else { return currentStatus.surfaceColor }
        switch selectedState {
        case .sleep, .unrecorded:
            return .secondary
        case .observed(let sample):
            if sample.memoryPressure != .low {
                return TimelineColors.memoryStatus
            }
            let processor = max(sample.cpuPercent, sample.gpuPercent ?? 0)
            if sample.thermalLevel == .serious || sample.thermalLevel == .critical
                || processor >= TimelineSemantics.criticalProcessorThreshold {
                return TimelineColors.critical
            }
            if sample.thermalLevel == .fair || processor >= 60 {
                return TimelineColors.active
            }
            return TimelineColors.normal
        }
    }

    private var compactTakeaway: String {
        currentStatus.message
    }

    private var compactTakeawaySymbol: String {
        currentStatus.symbol
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
                tone: .pressure,
                message: "Heat may be limiting speed. Let one heavy task finish before adding more work."
            )
        }
        if latest.memoryPressure == .high,
           isSustainedMemoryConstraint(at: latest.timestamp) {
            return TimelineCurrentStatus(
                urgency: .critical,
                tone: .memory,
                message: "Memory is constrained. App switching may feel slower; finish an unused heavy task only if this persists."
            )
        }
        if latest.memoryPressure == .high {
            return TimelineCurrentStatus(
                urgency: .elevated,
                tone: .memory,
                message: "Memory pressure rose briefly. The Mac should remain responsive; no action is needed unless it persists."
            )
        }
        if baseUrgency == .critical {
            return TimelineCurrentStatus(
                urgency: .critical,
                tone: .pressure,
                message: "\(estimate)\(source) is near capacity at \(Formatters.percent(usage)). Warmth or faster battery use is normal; act only if work slows."
            )
        }
        if latest.memoryPressure == .elevated || latest.thermalLevel == .fair {
            return TimelineCurrentStatus(
                urgency: .elevated,
                tone: latest.memoryPressure == .elevated ? .memory : .active,
                message: "Demand is elevated but manageable. The Mac should remain responsive; no action is needed unless slowdown repeats."
            )
        }
        if baseUrgency == .elevated {
            return TimelineCurrentStatus(
                urgency: .elevated,
                tone: .active,
                message: "\(estimate)\(source) is high at \(Formatters.percent(usage)), within a normal active-work range. No action is needed."
            )
        }
        return TimelineCurrentStatus(
            urgency: .normal,
            tone: .safe,
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
        if processor >= TimelineSemantics.criticalProcessorThreshold { return .critical }
        if sample.thermalLevel == .fair || sample.memoryPressure != .low
            || processor >= 60 {
            return .elevated
        }
        return .normal
    }

    private func urgency(for usage: Double) -> TimelineUrgency {
        if usage >= TimelineSemantics.criticalProcessorThreshold { return .critical }
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
            Color.clear.frame(width: usesCalmGraphOnlyLayout ? 0 : labelWidth, height: 1)
            GeometryReader { geometry in
                let plotWidth = max(1, geometry.size.width - UnifiedTimelineLayout.rightAxisWidth)
                ZStack(alignment: .topLeading) {
                    ForEach(timeMarks) { mark in
                        let tickLabelWidth: CGFloat = mark.kind == .clock
                            ? (mark.label.contains(" ") ? 58 : 46)
                            : 78
                        let fraction = min(1, max(
                            0,
                            mark.date.timeIntervalSince(interval.start) / max(1, interval.duration)
                        ))
                        let clockX = plotWidth * CGFloat(fraction)
                        let isTerminal = abs(mark.date.timeIntervalSince(interval.end)) < 1
                        let positionX = isTerminal
                            ? plotWidth + UnifiedTimelineLayout.rightAxisWidth / 2
                            : max(tickLabelWidth / 2, clockX)
                        VStack(spacing: 1) {
                            Capsule()
                                .fill(mark.kind.color.opacity(mark.kind == .wake ? 0.72 : 0.38))
                                .frame(width: 1, height: 3)
                            Text(mark.label)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(mark.kind.color)
                                .frame(width: tickLabelWidth)
                        }
                        .position(x: positionX, y: 8)
                    }
                }
            }
            .frame(height: 18)
        }
    }

    private func trackLabel(
        title: String,
        status: String,
        symbol: String,
        emphasis: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(emphasis ?? Color.primary)
            Text(status)
                .font(.caption2)
                .foregroundStyle(emphasis ?? Color.secondary)
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
        if snapshot.range == .twentyFourHours {
            return twentyFourHourTimeMarks
        }

        let marks: [(TimeInterval, String)]
        switch snapshot.range {
        case .oneHour:
            marks = [(-3_600, "−1h"), (-1_800, "−30m"), (-600, "−10m"), (0, "Now")]
        case .sixHours:
            marks = [(-21_600, "−6h"), (-7_200, "−2h"), (-3_600, "−1h"), (-1_800, "−30m"), (0, "Now")]
        case .twelveHours:
            marks = [(-43_200, "−12h"), (-21_600, "−6h"), (-10_800, "−3h"), (-3_600, "−1h"), (0, "Now")]
        case .twentyFourHours:
            marks = []
        }
        var resolved = marks.map { offset, label in
            TimelineAxisMark(
                date: interval.end.addingTimeInterval(offset),
                label: label
            )
        }
        guard let wake = leadingWakeBoundary else { return resolved }

        if let closeIndex = resolved.indices.min(by: {
            abs(resolved[$0].date.timeIntervalSince(wake))
                < abs(resolved[$1].date.timeIntervalSince(wake))
        }), abs(resolved[closeIndex].date.timeIntervalSince(wake)) <= 5 * 60 {
            resolved[closeIndex] = TimelineAxisMark(
                date: wake,
                label: relativeAxisLabel(for: wake)
            )
        } else if let precedingIndex = resolved.indices
            .filter({ $0 > resolved.startIndex && $0 < resolved.index(before: resolved.endIndex) })
            .filter({ resolved[$0].date < wake })
            .max(by: { resolved[$0].date < resolved[$1].date }) {
            resolved.remove(at: precedingIndex)
            resolved.append(TimelineAxisMark(date: wake, label: relativeAxisLabel(for: wake)))
        } else {
            resolved.append(TimelineAxisMark(date: wake, label: relativeAxisLabel(for: wake)))
        }
        return resolved.sorted { $0.date < $1.date }
    }

    /// A day view should read like a day, not a countdown. Real clock labels
    /// provide orientation while the longest confirmed sleep contributes the
    /// two session boundaries people actually care about: when the Mac went to
    /// sleep and when the next observed session could begin.
    private var twentyFourHourTimeMarks: [TimelineAxisMark] {
        let clockMarks = [0.0, 0.25, 0.5, 0.75].map { fraction in
            let date = interval.start.addingTimeInterval(interval.duration * fraction)
            return TimelineAxisMark(date: date, label: clockAxisLabel(for: date))
        } + [TimelineAxisMark(date: interval.end, label: "Now")]

        let boundaries = dominantSleepBoundaryMarks
        guard !boundaries.isEmpty else { return clockMarks }

        // Reserve enough horizontal room for the more useful event labels.
        let minimumClockSeparation: TimeInterval = 90 * 60
        let unclutteredClocks = clockMarks.filter { clock in
            clock.date == interval.end || !boundaries.contains {
                abs($0.date.timeIntervalSince(clock.date)) < minimumClockSeparation
            }
        }
        return (unclutteredClocks + boundaries).sorted { $0.date < $1.date }
    }

    private var dominantSleepBoundaryMarks: [TimelineAxisMark] {
        guard let sleep = sleepIntervals
            .filter({ $0.duration >= 90 * 60 })
            .max(by: { $0.duration < $1.duration }) else { return [] }

        let safeEdgeInset: TimeInterval = 12 * 60
        var marks: [TimelineAxisMark] = []
        if sleep.start > interval.start.addingTimeInterval(safeEdgeInset),
           sleep.start < interval.end.addingTimeInterval(-safeEdgeInset) {
            marks.append(TimelineAxisMark(
                date: sleep.start,
                label: "Sleep \(clockAxisLabel(for: sleep.start))",
                kind: .sleep
            ))
        }
        if sleep.end > interval.start.addingTimeInterval(safeEdgeInset),
           sleep.end < interval.end.addingTimeInterval(-safeEdgeInset) {
            marks.append(TimelineAxisMark(
                date: sleep.end,
                label: "Awake \(clockAxisLabel(for: sleep.end))",
                kind: .wake
            ))
        }
        return marks
    }

    private func clockAxisLabel(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private var leadingWakeBoundary: Date? {
        guard let leadingSleep = sleepIntervals.first(where: {
            $0.start <= interval.start.addingTimeInterval(60)
                && $0.end > interval.start.addingTimeInterval(15 * 60)
        }) else { return nil }
        let wake = min(interval.end, leadingSleep.end)
        guard wake < interval.end.addingTimeInterval(-2 * 60) else { return nil }
        return wake
    }

    private func relativeAxisLabel(for date: Date) -> String {
        let totalMinutes = max(1, Int((interval.end.timeIntervalSince(date) / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "−\(minutes)m" }
        if minutes == 0 { return "−\(hours)h" }
        return "−\(hours)h \(minutes)m"
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
            return "Longest heavy run · \(railDuration(windowUsageSummary.longestHeavyProcessorRun))"
        }
        if windowUsageSummary.heavyProcessorDuration >= 5 * 60 {
            return "Heavy time · \(railDuration(windowUsageSummary.heavyProcessorDuration)) total"
        }
        let average = max(snapshot.averageCPU, graphicsAverage ?? 0)
        if average >= TimelineSemantics.heavyProcessorThreshold {
            return "Busy on average"
        }
        if average >= 25 { return "Moderate on average · headroom left" }
        return "Light on average · ample headroom"
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
        if !visibleStress.memoryCriticalIntervals.isEmpty {
            return "Constrained · \(compactStressDuration(visibleStress.memoryCriticalDuration)); switching may slow"
        }
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
        visibleStress.memoryCriticalIntervals
    }

    private func isSustainedMemoryConstraint(at time: Date) -> Bool {
        visibleStress.memoryCriticalIntervals.contains {
            time >= $0.start && time <= $0.end
        }
    }

    private func railDuration(_ duration: TimeInterval) -> String {
        duration < 60 ? "under 1 min" : Formatters.duration(duration)
    }

    private var batteryStatus: String {
        if TimelineSemantics.latestSample(from: samples)?.powerSource == .adapter {
            return "Plugged in now · earlier battery use"
        }
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

    private func processorMeaning(normal: String, isCurrentlyCritical: Bool) -> String {
        isCurrentlyCritical ? "Near capacity now" : normal
    }

    private func compactStressDuration(_ duration: TimeInterval) -> String {
        if duration < 60 { return "<1 min" }
        let minutes = max(1, Int((duration / 60).rounded()))
        return minutes == 1 ? "1 min" : "\(minutes) min"
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
        range: MonitoringRange,
        displayMode: TimelineDisplayMode
    ) -> [ProcessorTrendPoint] {
        let bucketDuration = TimelineSemantics.processorTrendBucketDuration(
            for: range,
            displayMode: displayMode
        )

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

    private static func makeLiveProcessorReading(
        from samples: [SystemSample],
        endingAt end: Date,
        duration: TimeInterval = 2 * 60
    ) -> TimelineLiveProcessorReading? {
        guard let latest = samples.last(where: { $0.duration > 0 }) else { return nil }
        let freshness = max(120, latest.samplingInterval * 4)
        guard end.timeIntervalSince(latest.timestamp) <= freshness else { return nil }

        let start = end.addingTimeInterval(-duration)
        var cpuTotal = 0.0
        var cpuWeight = 0.0
        var gpuTotal = 0.0
        var gpuWeight = 0.0

        for sample in samples where sample.duration > 0 {
            let observedEnd = min(end, sample.timestamp)
            let observedStart = max(start, sample.timestamp.addingTimeInterval(-sample.duration))
            let overlap = observedEnd.timeIntervalSince(observedStart)
            guard overlap > 0, sample.cpuPercent.isFinite else { continue }
            cpuTotal += sample.cpuPercent * overlap
            cpuWeight += overlap
            if let gpu = sample.gpuPercent, gpu.isFinite {
                gpuTotal += gpu * overlap
                gpuWeight += overlap
            }
        }

        guard cpuWeight > 0 else { return nil }
        return TimelineLiveProcessorReading(
            cpuPercent: cpuTotal / cpuWeight,
            gpuPercent: gpuWeight > 0 ? gpuTotal / gpuWeight : nil
        )
    }

    private static func makeCurrentActivity(
        samples: [SystemSample],
        backgroundPoints: [BackgroundActivityPoint],
        lanes: [TimelineActivityLane],
        endingAt end: Date
    ) -> TimelineCurrentActivity? {
        if let latestBackgroundTime = backgroundPoints.map(\.timestamp).max() {
            let latestPoints = backgroundPoints.filter {
                abs($0.timestamp.timeIntervalSince(latestBackgroundTime)) < 1
            }
            let freshness = max(120, (latestPoints.map(\.duration).max() ?? 0) * 4)
            let agentCount = latestPoints.reduce(0) { $0 + $1.agentWorkerCount }
            if agentCount > 0, end.timeIntervalSince(latestBackgroundTime) <= freshness {
                let representative = latestPoints.max {
                    let lhs = Double($0.agentWorkerCount) * 100 + max(0, $0.cpuPercent)
                    let rhs = Double($1.agentWorkerCount) * 100 + max(0, $1.cpuPercent)
                    return lhs < rhs
                }
                let lane = lanes.first(where: { $0.source == .automatic })
                return TimelineCurrentActivity(
                    title: lane?.title ?? "Agentic development",
                    appName: representative?.ownerName ?? lane?.appName ?? "Background work",
                    bundleIdentifier: representative?.ownerBundleID ?? lane?.bundleIdentifier,
                    detail: agentCount == 1 ? "1 agent now" : "\(agentCount) agents now",
                    color: TimelineColors.automatic
                )
            }
        }

        guard let latest = samples.last(where: { $0.duration > 0 }) else { return nil }
        let freshness = max(120, latest.samplingInterval * 4)
        guard !latest.isIdle,
              end.timeIntervalSince(latest.timestamp) <= freshness else { return nil }
        return TimelineCurrentActivity(
            title: currentActivityTitle(for: latest.category),
            appName: latest.foregroundApp.isEmpty ? "Current app" : latest.foregroundApp,
            bundleIdentifier: latest.foregroundBundleID,
            detail: latest.foregroundApp.isEmpty ? "You now" : "You · \(latest.foregroundApp)",
            color: TimelineColors.handsOn
        )
    }

    private static func currentActivityTitle(for category: WorkCategory) -> String {
        switch category {
        case .coding: return "Development"
        case .research: return "Browser use"
        case .writing: return "Writing"
        case .communication: return "Communication"
        case .design: return "Design"
        case .meetings: return "Meetings"
        case .files: return "File work"
        case .media: return "Media"
        case .music: return "Music"
        case .administration: return "Administration"
        case .other: return "App use"
        case .idle: return "Idle"
        }
    }

}

private struct ContributorAppIcon: View {
    let bundleIdentifier: String?
    let ownerName: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: bundleIdentifier ?? ownerName) {
            // Let the panel draw first; Launch Services can take a moment on a
            // cold icon lookup, while every later render hits the memory cache.
            await Task.yield()
            image = ApplicationIconCache.shared.image(
                bundleIdentifier: bundleIdentifier,
                ownerName: ownerName
            )
        }
    }
}

private enum TimelineColors {
    static let processor = Color(nsColor: .systemBlue)
    static let handsOn = Color.indigo
    static let automatic = Color(nsColor: .systemPurple)
    static let graphics = Color(nsColor: .systemTeal)
    static let battery = Color(nsColor: .systemGreen)
    static let memory = Color(nsColor: .systemGray)
    static let memoryElevated = Color(nsColor: .systemOrange)
    static let memoryStatus = Color(nsColor: .systemYellow)
    static let thermal = Color(nsColor: .systemOrange)
    static let presence = Color(nsColor: .systemGreen)
    static let active = Color(nsColor: .systemCyan)
    static let normal = Color(nsColor: .systemGreen)
    static let critical = Color(nsColor: .systemRed)
}

private enum TimelineStatusTone {
    case safe
    case active
    case memory
    case pressure
    case unavailable

    var color: Color {
        switch self {
        case .safe: return TimelineColors.normal
        case .active: return TimelineColors.active
        case .memory: return TimelineColors.memoryStatus
        case .pressure: return TimelineColors.critical
        case .unavailable: return .secondary
        }
    }
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
    let tone: TimelineStatusTone
    let message: String

    var color: Color { tone.color }
    var surfaceColor: Color { tone.color }
    var symbol: String { urgency.symbol }

    static func unavailable(_ message: String) -> Self {
        Self(urgency: .unavailable, tone: .unavailable, message: message)
    }
}

private enum TimelineAxisMarkKind: String {
    case clock
    case wake
    case sleep

    var color: Color {
        switch self {
        case .clock: return .secondary
        case .wake: return TimelineColors.presence
        case .sleep: return .secondary
        }
    }
}

private struct TimelineAxisMark: Identifiable {
    let date: Date
    let label: String
    let kind: TimelineAxisMarkKind

    init(date: Date, label: String, kind: TimelineAxisMarkKind = .clock) {
        self.date = date
        self.label = label
        self.kind = kind
    }

    var id: String { "\(date.timeIntervalSinceReferenceDate)-\(kind.rawValue)" }
}

private struct UnifiedTimelineLayout: Equatable {
    static let rightAxisWidth: CGFloat = 38

    let showsBattery: Bool
    let showsMemory: Bool
    let cpuHeight: CGFloat
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
            cpuHeight = 236
            batteryHeight = 56
            memoryHeight = 36
            sectionGap = 12
        case .expanded:
            cpuHeight = min(520, max(320, expandedProcessorHeight ?? 320))
            batteryHeight = 60
            memoryHeight = 42
            sectionGap = 14
        case .menuBar:
            cpuHeight = 164
            batteryHeight = 42
            memoryHeight = 32
            sectionGap = 8
        }
    }

    var sectionCount: Int {
        1 + (showsBattery ? 1 : 0) + (showsMemory ? 1 : 0)
    }

    var totalHeight: CGFloat {
        cpuHeight
            + (showsBattery ? batteryHeight : 0)
            + (showsMemory ? memoryHeight : 0)
            + CGFloat(max(0, sectionCount - 1)) * sectionGap
    }

    func rects(in size: CGSize) -> UnifiedTimelineRects {
        let plotWidth = max(1, size.width - rightAxisWidth)
        var y: CGFloat = 0
        let cpu = CGRect(x: 0, y: y, width: plotWidth, height: cpuHeight)
        y += cpuHeight

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
            battery: battery,
            memory: memory
        )
    }
}

private struct UnifiedTimelineRects {
    let plotWidth: CGFloat
    let cpu: CGRect
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

private struct ProcessorRenderRun {
    let startTime: Date
    let endTime: Date
    let points: [CGPoint]
}

private struct TimelineLiveProcessorReading: Equatable {
    let cpuPercent: Double
    let gpuPercent: Double?
}

private struct TimelineCurrentActivity: Equatable {
    let title: String
    let appName: String
    let bundleIdentifier: String?
    let detail: String
    let color: Color
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
    let thermalContext: TimelineThermalContext
    let presenceContext: TimelinePresenceContext
    let visibleStress: TimelineVisibleStress
    let batteryRuns: [BatteryTimelineRun]
    let sleepIntervals: [DateInterval]
    let interval: DateInterval
    let processorScaleMaximum: Double
    let layout: UnifiedTimelineLayout
    let displayMode: TimelineDisplayMode

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.samples == rhs.samples
            && lhs.processorTrend == rhs.processorTrend
            && lhs.memoryConditions == rhs.memoryConditions
            && lhs.thermalContext == rhs.thermalContext
            && lhs.presenceContext == rhs.presenceContext
            && lhs.visibleStress == rhs.visibleStress
            && lhs.batteryRuns == rhs.batteryRuns
            && lhs.sleepIntervals == rhs.sleepIntervals
            && lhs.interval == rhs.interval
            && lhs.processorScaleMaximum == rhs.processorScaleMaximum
            && lhs.layout == rhs.layout
            && lhs.displayMode == rhs.displayMode
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            let rects = layout.rects(in: size)
            drawTrackBackgrounds(in: &context, rects: rects)
            drawProcessorGrid(in: &context, rect: rects.cpu, rightAxisX: rects.plotWidth)
            drawConfirmedSleep(in: &context, size: size, plotWidth: rects.plotWidth)
            drawThermalAtmosphere(in: &context, rect: rects.cpu)
            drawProcessorMemory(in: &context, rect: rects.cpu)
            drawProcessor(in: &context, rect: rects.cpu)
            drawPresenceBaseline(in: &context, rect: rects.cpu)
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

    /// A quiet light ribbon at the top of the processor plot communicates the
    /// supported macOS thermal state. Its different geometry keeps it distinct
    /// from the vertical amber memory markers and subordinate to CPU/GPU lines.
    private func drawThermalAtmosphere(in context: inout GraphicsContext, rect: CGRect) {
        let plot = rect.insetBy(dx: 0, dy: 6)
        drawThermalRuns(
            thermalContext.managedIntervals,
            in: &context,
            plot: plot,
            color: TimelineColors.thermal,
            bandOpacity: displayMode == .calm ? 0.016 : 0.028,
            rayOpacity: displayMode == .calm ? 0.20 : 0.34
        )
        drawThermalRuns(
            thermalContext.seriousIntervals + thermalContext.criticalIntervals,
            in: &context,
            plot: plot,
            color: TimelineColors.critical,
            bandOpacity: displayMode == .calm ? 0.028 : 0.045,
            rayOpacity: displayMode == .calm ? 0.46 : 0.66
        )
    }

    private func drawThermalRuns(
        _ runs: [DateInterval],
        in context: inout GraphicsContext,
        plot: CGRect,
        color: Color,
        bandOpacity: Double,
        rayOpacity: Double
    ) {
        for run in runs {
            let rawStart = xPosition(run.start, plotWidth: plot.width)
            let rawEnd = xPosition(run.end, plotWidth: plot.width)
            let center = (rawStart + rawEnd) / 2
            let width = min(plot.width, max(6, rawEnd - rawStart))
            let x = min(max(plot.minX, center - width / 2), max(plot.minX, plot.maxX - width))
            let band = CGRect(x: x, y: plot.minY, width: width, height: plot.height)
            let fade = min(0.42, max(0.12, 2.5 / max(1, width)))

            context.fill(
                Path(roundedRect: band, cornerRadius: 3),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(0), location: 0),
                        .init(color: color.opacity(bandOpacity), location: fade),
                        .init(color: color.opacity(bandOpacity * 0.58), location: 1 - fade),
                        .init(color: color.opacity(0), location: 1)
                    ]),
                    startPoint: CGPoint(x: band.minX, y: band.midY),
                    endPoint: CGPoint(x: band.maxX, y: band.midY)
                )
            )

            var ray = Path()
            ray.move(to: CGPoint(x: band.minX + 1, y: plot.minY + 1.5))
            ray.addLine(to: CGPoint(x: band.maxX - 1, y: plot.minY + 1.5))
            context.stroke(
                ray,
                with: .color(color.opacity(rayOpacity * 0.16)),
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
            context.stroke(
                ray,
                with: .color(color.opacity(rayOpacity)),
                style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
            )
        }
    }

    /// One quiet baseline separates human presence from machine availability
    /// without introducing another chart. Bright green is measured hands-on
    /// input, pale green is observed awake time, gray is confirmed sleep, and
    /// unrecorded time remains blank.
    private func drawPresenceBaseline(in context: inout GraphicsContext, rect: CGRect) {
        let y = rect.maxY - 2.5
        drawPresenceIntervals(
            sleepIntervals,
            y: y,
            color: .secondary,
            opacity: 0.30,
            lineWidth: 2.2,
            in: &context,
            plotWidth: rect.width
        )
        drawPresenceIntervals(
            presenceContext.awakeIntervals,
            y: y,
            color: TimelineColors.presence,
            opacity: 0.20,
            lineWidth: 2.2,
            in: &context,
            plotWidth: rect.width
        )
        drawPresenceIntervals(
            presenceContext.handsOnIntervals,
            y: y,
            color: TimelineColors.presence,
            opacity: 0.82,
            lineWidth: 2.7,
            glowOpacity: 0.10,
            in: &context,
            plotWidth: rect.width
        )
    }

    private func drawPresenceIntervals(
        _ intervals: [DateInterval],
        y: CGFloat,
        color: Color,
        opacity: Double,
        lineWidth: CGFloat,
        glowOpacity: Double = 0,
        in context: inout GraphicsContext,
        plotWidth: CGFloat
    ) {
        for interval in intervals {
            let start = xPosition(interval.start, plotWidth: plotWidth)
            let end = xPosition(interval.end, plotWidth: plotWidth)
            guard end > start else { continue }
            var line = Path()
            line.move(to: CGPoint(x: start, y: y))
            line.addLine(to: CGPoint(x: max(start + 1, end), y: y))
            if glowOpacity > 0 {
                context.stroke(
                    line,
                    with: .color(color.opacity(glowOpacity)),
                    style: StrokeStyle(lineWidth: lineWidth + 4, lineCap: .round)
                )
            }
            context.stroke(
                line,
                with: .color(color.opacity(opacity)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }
    }

    private func drawProcessor(in context: inout GraphicsContext, rect: CGRect) {
        let plot = rect.insetBy(dx: 0, dy: 6)
        let grouped = Dictionary(
            grouping: processorTrend.filter { $0.timestamp >= interval.start && $0.timestamp <= interval.end },
            by: \.segment
        )

        let orderedSegments = grouped.keys.sorted().compactMap { segment -> [ProcessorTrendPoint]? in
            guard let values = grouped[segment]?.sorted(by: { $0.timestamp < $1.timestamp }),
                  !values.isEmpty else { return nil }
            return values
        }
        let cpuRuns = orderedSegments.compactMap { values -> ProcessorRenderRun? in
            guard let first = values.first, let last = values.last else { return nil }
            return ProcessorRenderRun(
                startTime: first.timestamp,
                endTime: last.timestamp,
                points: smoothedProcessorPoints(values.map { point in
                    CGPoint(
                        x: xPosition(point.timestamp, plotWidth: plot.width),
                        y: processorYPosition(point.cpuPercent, in: plot)
                    )
                })
            )
        }
        let graphicsRuns = orderedSegments.flatMap { graphicsRenderRuns(from: $0, in: plot) }

        // Missing telemetry is not measured work. A neutral connector keeps the
        // visual thread intact without carrying CPU/GPU color or area through it.
        // Confirmed sleep is the one known absence: ease to zero, stay there,
        // then ease back after wake rather than drawing a hard vertical cut.
        drawProcessorGapBridges(cpuRuns, in: &context, plot: plot)
        drawProcessorGapBridges(graphicsRuns, in: &context, plot: plot)

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
                topOpacity: displayMode == .calm
                    ? 0.070
                    : (coreSplitRuns.isEmpty ? 0.095 : 0.048),
                in: &context,
                plot: plot
            )
            if displayMode == .precise {
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
            }
            for run in graphicsDisplayRuns {
                drawProcessorArea(
                    run,
                    color: TimelineColors.graphics,
                    topOpacity: displayMode == .calm ? 0.060 : 0.08,
                    in: &context,
                    plot: plot
                )
            }

            drawProcessorLine(
                cpuDisplayPoints,
                color: TimelineColors.processor,
                lineWidth: displayMode == .calm ? 2.15 : 1.9,
                in: &context,
                plot: plot
            )
            drawProcessorUrgency(
                cpuDisplayPoints,
                criticalIntervals: visibleStress.cpuCriticalIntervals,
                subdued: displayMode == .calm,
                in: &context,
                plot: plot
            )
            for run in graphicsDisplayRuns {
                drawProcessorLine(
                    run,
                    color: TimelineColors.graphics,
                    lineWidth: displayMode == .calm ? 2.05 : 1.8,
                    in: &context,
                    plot: plot
                )
                drawProcessorUrgency(
                    run,
                    criticalIntervals: visibleStress.gpuCriticalIntervals,
                    subdued: displayMode == .calm,
                    in: &context,
                    plot: plot
                )
            }
        }
    }

    private func graphicsRenderRuns(
        from values: [ProcessorTrendPoint],
        in plot: CGRect
    ) -> [ProcessorRenderRun] {
        var result: [ProcessorRenderRun] = []
        var current: [(timestamp: Date, point: CGPoint)] = []

        func finishRun() {
            guard let first = current.first, let last = current.last else { return }
            result.append(ProcessorRenderRun(
                startTime: first.timestamp,
                endTime: last.timestamp,
                points: smoothedProcessorPoints(current.map(\.point))
            ))
            current.removeAll(keepingCapacity: true)
        }

        for value in values {
            guard let gpu = value.gpuPercent else {
                finishRun()
                continue
            }
            current.append((
                timestamp: value.timestamp,
                point: CGPoint(
                    x: xPosition(value.timestamp, plotWidth: plot.width),
                    y: processorYPosition(gpu, in: plot)
                )
            ))
        }
        finishRun()
        return result
    }

    private func drawProcessorGapBridges(
        _ runs: [ProcessorRenderRun],
        in context: inout GraphicsContext,
        plot: CGRect
    ) {
        let ordered = runs.sorted { $0.startTime < $1.startTime }
        guard ordered.count >= 2 else { return }

        for index in 1..<ordered.count {
            let previous = ordered[index - 1]
            let next = ordered[index]
            guard next.startTime > previous.endTime,
                  let start = previous.points.last,
                  let end = next.points.first,
                  end.x - start.x > 1.5 else { continue }

            let containsConfirmedSleep = sleepIntervals.contains { sleep in
                sleep.end > previous.endTime && sleep.start < next.startTime
            }
            let path = containsConfirmedSleep
                ? processorSleepBridge(from: start, to: end, baselineY: plot.maxY)
                : processorCaptureBridge(from: start, to: end)
            let glowOpacity = displayMode == .calm ? 0.045 : 0.060
            let lineOpacity = displayMode == .calm ? 0.24 : 0.31
            let lineWidth: CGFloat = displayMode == .calm ? 1.15 : 1.05

            context.stroke(
                path,
                with: .color(.secondary.opacity(glowOpacity)),
                style: StrokeStyle(lineWidth: lineWidth + 3.2, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                path,
                with: .color(.secondary.opacity(lineOpacity)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func processorCaptureBridge(from start: CGPoint, to end: CGPoint) -> Path {
        let distance = max(1, end.x - start.x)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + distance * 0.34, y: start.y),
            control2: CGPoint(x: end.x - distance * 0.34, y: end.y)
        )
        return path
    }

    private func processorSleepBridge(
        from start: CGPoint,
        to end: CGPoint,
        baselineY: CGFloat
    ) -> Path {
        let distance = max(1, end.x - start.x)
        let ramp = min(18, max(5, distance * 0.16))
        let downX = min(start.x + ramp, start.x + distance * 0.48)
        let upX = max(end.x - ramp, start.x + distance * 0.52)

        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: CGPoint(x: downX, y: baselineY),
            control1: CGPoint(x: start.x + (downX - start.x) * 0.48, y: start.y),
            control2: CGPoint(x: downX - (downX - start.x) * 0.28, y: baselineY)
        )
        path.addLine(to: CGPoint(x: upX, y: baselineY))
        path.addCurve(
            to: end,
            control1: CGPoint(x: upX + (end.x - upX) * 0.28, y: baselineY),
            control2: CGPoint(x: end.x - (end.x - upX) * 0.48, y: end.y)
        )
        return path
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
        criticalIntervals: [DateInterval],
        subdued: Bool,
        in context: inout GraphicsContext,
        plot: CGRect
    ) {
        guard points.count >= 2, !criticalIntervals.isEmpty else { return }
        for interval in criticalIntervals {
            let startX = xPosition(interval.start, plotWidth: plot.width)
            let endX = xPosition(interval.end, plotWidth: plot.width)
            let range = startX...endX
            let run = clippedPolyline(points, to: range)
            if run.count == 1, let point = run.first {
                let radius: CGFloat = subdued ? 2 : 3
                let marker = CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(
                    Path(ellipseIn: marker),
                    with: .color(TimelineColors.critical.opacity(subdued ? 0.78 : 0.96))
                )
                continue
            }
            guard run.count >= 2 else { continue }
            var segment = Path()
            segment.move(to: run[0])
            for point in run.dropFirst() { segment.addLine(to: point) }
            context.stroke(
                segment,
                with: .color(TimelineColors.critical.opacity(subdued ? 0.07 : 0.16)),
                style: StrokeStyle(
                    lineWidth: subdued ? 3.4 : 5.2,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            context.stroke(
                segment,
                with: .color(TimelineColors.critical.opacity(subdued ? 0.80 : 0.96)),
                style: StrokeStyle(
                    lineWidth: subdued ? 1.55 : 2.3,
                    lineCap: .round,
                    lineJoin: .round
                )
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
        let sustained = visibleStress.memoryCriticalIntervals
        let brief = memoryConditions.constrained.filter { !sustained.contains($0) }
        drawProcessorMemoryRuns(
            memoryConditions.elevated + brief,
            in: &context,
            plot: plot,
            color: TimelineColors.memoryElevated,
            bandOpacity: displayMode == .calm ? 0.038 : 0.075,
            lineOpacity: displayMode == .calm ? 0.16 : 0.34
        )
        drawProcessorMemoryRuns(
            sustained,
            in: &context,
            plot: plot,
            color: TimelineColors.critical,
            bandOpacity: displayMode == .calm ? 0.052 : 0.085,
            lineOpacity: displayMode == .calm ? 0.18 : 0.30
        )
    }

    private func drawProcessorMemoryRuns(
        _ runs: [DateInterval],
        in context: inout GraphicsContext,
        plot: CGRect,
        color: Color,
        bandOpacity: Double,
        lineOpacity: Double
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
            var marker = Path()
            marker.move(to: CGPoint(x: band.midX, y: band.minY))
            marker.addLine(to: CGPoint(x: band.midX, y: band.maxY))
            context.stroke(
                marker,
                with: .color(color.opacity(lineOpacity)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
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
        let sustained = visibleStress.memoryCriticalIntervals
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
            color: TimelineColors.critical.opacity(0.95),
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

    private func xPosition(_ date: Date, plotWidth: CGFloat) -> CGFloat {
        let fraction = min(1, max(0, date.timeIntervalSince(interval.start) / max(1, interval.duration)))
        return plotWidth * CGFloat(fraction)
    }

    private func processorYPosition(_ value: Double, in rect: CGRect) -> CGFloat {
        rect.maxY - rect.height * CGFloat(min(processorScaleMaximum, max(0, value)) / processorScaleMaximum)
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
        var summary = "One graph shows whole-machine CPU demand and current work context."
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
        let sustainedMemory = visibleStress.memoryCriticalIntervals
        let briefMemory = memoryConditions.constrained.filter { !sustainedMemory.contains($0) }
        if !memoryConditions.elevated.isEmpty || !briefMemory.isEmpty {
            summary += " Amber markers show elevated or brief memory pressure that is worth watching but not constrained."
        }
        if !sustainedMemory.isEmpty {
            summary += " Red bands indicate memory constrained for at least two minutes, when slowdown is more likely."
        }
        if thermalContext.hasElevatedHeat {
            summary += " A quiet warm ribbon at the top of the processor plot marks periods when macOS reported reduced thermal headroom; it is not an exact temperature or fan-speed reading."
        }
        if !presenceContext.awakeIntervals.isEmpty || !sleepIntervals.isEmpty {
            summary += " A thin baseline below the processor plot is bright green for measured physical input, pale green while the Mac was observed awake, gray for confirmed sleep, and blank where no state was recorded."
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
            Label("Show current", systemImage: "arrow.uturn.backward.circle.fill")
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
        return "\(condition) · \(Formatters.percent(usedPercent)) used · existing swap stable"
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
