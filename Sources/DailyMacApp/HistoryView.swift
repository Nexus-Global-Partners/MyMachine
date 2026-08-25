import Charts
import DailyMacCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var range = 7
    @State private var selectedDay: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "History",
                    subtitle: "See how work and machine strain changed from day to day"
                )

                HStack {
                    Picker("Range", selection: $range) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)

                    Spacer()

                    if !visibleReports.isEmpty {
                        Text(dayCountLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if visibleReports.isEmpty {
                    emptyHistory
                } else {
                    patternOverview
                    dailyHistory
                }
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(30)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("")
        .onChange(of: range) {
            selectedDay = nil
        }
    }

    private var visibleReports: [DailyReport] {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(byAdding: .day, value: -(range - 1), to: start) ?? start
        let cutoffKey = DayBoundaries.key(for: cutoff)
        let todayKey = DayBoundaries.key(for: Date())
        return model.reports.filter { $0.dayKey >= cutoffKey && $0.dayKey < todayKey }
    }

    private var chronologicalReports: [DailyReport] {
        visibleReports.sorted { $0.dayKey < $1.dayKey }
    }

    private var dayCountLabel: String {
        let count = visibleReports.count
        return "\(count) recorded \(count == 1 ? "day" : "days")"
    }

    private var currentTrend: TrendSummary {
        range == 7 ? model.trend7 : model.trend30
    }

    private var patternOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(range == 7 ? "The week at a glance" : "The month at a glance")
                    .font(.headline)
                Text(patternTakeaway)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(patternColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HistoryTrendChart(reports: chronologicalReports)

            HStack(alignment: .top, spacing: 30) {
                HistorySummaryMetric(
                    title: "Active use",
                    value: Formatters.duration(averageActiveDuration),
                    detail: "average per recorded day"
                )
                HistorySummaryMetric(
                    title: "Processor",
                    value: Formatters.percent(currentTrend.averageDailyCPU),
                    detail: processorSummary
                )
                HistorySummaryMetric(
                    title: "Memory",
                    value: memoryTrendValue,
                    detail: memoryTrendDetail,
                    tint: memoryTrendColor
                )
                HistorySummaryMetric(
                    title: "Heat",
                    value: heatTrendValue,
                    detail: heatTrendDetail,
                    tint: heatTrendColor
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Bars show observed active-app time. The blue line shows whole-Mac processor demand; orange dots mark days when memory pressure became noticeable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dailyHistory: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Day by day")
                    .font(.headline)
                Spacer()
                Text("Select a day for its full briefing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            ForEach(visibleReports) { report in
                HistoryDayRow(
                    report: report,
                    maximumActiveDuration: maximumActiveDuration,
                    isExpanded: selectedDay == report.dayKey,
                    takeaway: dayTakeaway(report),
                    apps: foregroundSummary(report),
                    statusColor: statusColor(report)
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedDay = selectedDay == report.dayKey ? nil : report.dayKey
                    }
                }

                if selectedDay == report.dayKey {
                    expandedDay(report)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if report.id != visibleReports.last?.id {
                    Divider()
                }
            }

            Text("Active use means time when an app was frontmost. It describes how the Mac was used, not attention, output, or productivity.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
        }
    }

    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("No completed day yet", systemImage: "calendar.badge.clock")
                .font(.headline)
            Text("The first day appears after midnight or the next time the Mac wakes. Monitoring continues quietly in the meantime.")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    private func expandedDay(_ report: DailyReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 28) {
                ExpandedDayMetric(
                    title: "Active use",
                    value: Formatters.duration(report.activeDuration),
                    meaning: activeUseMeaning(report)
                )
                ExpandedDayMetric(
                    title: "Processor",
                    value: Formatters.percent(report.averageCPU),
                    meaning: processorMeaning(report.averageCPU)
                )
                ExpandedDayMetric(
                    title: "Memory",
                    value: memoryLabel(report),
                    meaning: memoryMeaning(report),
                    tint: memoryColor(report)
                )
                ExpandedDayMetric(
                    title: "Heat",
                    value: thermalLabel(report.thermalPeak),
                    meaning: thermalMeaning(report.thermalPeak),
                    tint: thermalColor(report.thermalPeak)
                )
            }

            if !report.applications.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("In the foreground")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(report.applications.prefix(4))) { app in
                        HistoryAppBar(
                            name: app.name,
                            duration: app.activeDuration,
                            maximumDuration: report.applications.first?.activeDuration ?? app.activeDuration
                        )
                    }
                }
            }

            if let insight = primaryInsight(report) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: insightSymbol(insight.kind))
                        .foregroundStyle(insightColor(insight.kind))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(insight.title)
                            .font(.subheadline.weight(.semibold))
                        Text(insight.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            DisclosureGroup("Full briefing and exact readings") {
                fullBriefing(report)
                    .padding(.top, 10)
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.045))
        )
        .padding(.bottom, 8)
    }

    private func fullBriefing(_ report: DailyReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.overview)
                .textSelection(.enabled)

            if supportsNarrative(report) {
                if !report.importantMoments.isEmpty {
                    Text("What stood out")
                        .font(.subheadline.weight(.semibold))
                    ForEach(report.importantMoments.prefix(5)) { InsightRow(insight: $0) }
                }

                if !report.correlations.isEmpty {
                    Text("Work and machine patterns")
                        .font(.subheadline.weight(.semibold))
                    ForEach(report.correlations) { InsightRow(insight: $0) }
                }

                Text("Useful next step")
                    .font(.subheadline.weight(.semibold))
                if report.recommendations.isEmpty {
                    Text("Nothing needs changing based on this day.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(report.recommendations) { InsightRow(insight: $0) }
                }

                DisclosureGroup("Exact readings and limitations") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Whole-machine CPU averaged \(Formatters.percent(report.averageCPU)) and peaked at \(Formatters.percent(report.peakCPU)). Peak active, wired, and compressed memory was \(Formatters.bytes(report.peakMemoryBytes)); ending swap allocation was \(Formatters.bytes(report.endingSwapBytes)).")
                        ForEach(report.limitations, id: \.self) { limitation in
                            Text("• \(limitation)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                }
            } else {
                Text("The recorded fragments are visible, but they were too short to support a reliable conclusion about performance, battery, heat, or workflow.")
                    .foregroundStyle(.secondary)
                DisclosureGroup("Coverage and limitations") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Longest uninterrupted recorded stretch: \(Formatters.duration(report.longestContinuousCoverage ?? 0)).")
                        ForEach(report.limitations, id: \.self) { limitation in
                            Text("• \(limitation)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                }
            }
        }
        .font(.callout)
    }

    private var averageActiveDuration: TimeInterval {
        guard !visibleReports.isEmpty else { return 0 }
        return visibleReports.reduce(0) { $0 + $1.activeDuration } / Double(visibleReports.count)
    }

    private var maximumActiveDuration: TimeInterval {
        max(visibleReports.map(\.activeDuration).max() ?? 1, 1)
    }

    private var constrainedDays: Int {
        visibleReports.filter { $0.peakMemoryPressure == .high }.count
    }

    private var noticeableMemoryDays: Int {
        visibleReports.filter {
            $0.peakMemoryPressure == .elevated || $0.peakMemoryPressure == .high
        }.count
    }

    private var hotDays: Int {
        visibleReports.filter {
            $0.thermalPeak == .serious || $0.thermalPeak == .critical
        }.count
    }

    private var patternTakeaway: String {
        let reliable = visibleReports.filter(supportsNarrative)
        guard reliable.count >= 2 else {
            return "A reliable pattern needs a few more complete days."
        }
        if let change = currentTrend.notableChange, !change.isEmpty {
            return change
        }
        if hotDays > 0 {
            return "Heat was high enough to affect performance on \(dayWord(hotDays))."
        }
        if constrainedDays > 0 {
            return "Memory pressure likely affected responsiveness on \(dayWord(constrainedDays))."
        }
        if noticeableMemoryDays > 0 {
            return "Memory demand became noticeable on \(dayWord(noticeableMemoryDays)), but no repeated serious strain appeared."
        }
        return "Workload stayed steady without a repeated processor, memory, or heat concern."
    }

    private var patternColor: Color {
        if hotDays > 0 || constrainedDays > 0 { return .orange }
        return .primary
    }

    private var processorSummary: String {
        switch currentTrend.averageDailyCPU {
        case 60...: return "heavy across the period"
        case 35..<60: return "moderate across the period"
        default: return "light across the period"
        }
    }

    private var memoryTrendValue: String {
        if constrainedDays > 0 { return "\(constrainedDays) constrained" }
        if noticeableMemoryDays > 0 { return "\(noticeableMemoryDays) noticeable" }
        return "Comfortable"
    }

    private var memoryTrendDetail: String {
        if constrainedDays > 0 { return "may have slowed app switching" }
        if noticeableMemoryDays > 0 { return "macOS had less spare headroom" }
        return "no pressure days recorded"
    }

    private var memoryTrendColor: Color {
        noticeableMemoryDays > 0 ? .orange : .primary
    }

    private var heatTrendValue: String {
        hotDays > 0 ? "\(hotDays) hot" : "Normal"
    }

    private var heatTrendDetail: String {
        hotDays > 0 ? "performance may have been limited" : "no thermal slowdown recorded"
    }

    private var heatTrendColor: Color {
        hotDays > 0 ? .orange : .primary
    }

    private func dayTakeaway(_ report: DailyReport) -> String {
        guard supportsNarrative(report) else { return "Partial record — no reliable conclusion" }
        if report.thermalPeak == .critical || report.thermalPeak == .serious {
            return "Heat likely reduced performance"
        }
        if report.peakMemoryPressure == .high {
            return "Memory pressure likely affected responsiveness"
        }
        if report.averageCPU >= 60 {
            return "Sustained processor load may have raised heat and battery use"
        }
        if report.peakMemoryPressure == .elevated {
            return "Memory became noticeable, but remained manageable"
        }
        if report.thermalPeak == .fair {
            return "The Mac ran warmer, without a likely slowdown"
        }
        return "Normal working day — no sustained machine strain"
    }

    private func foregroundSummary(_ report: DailyReport) -> String {
        let apps = report.applications.prefix(2).map {
            "\($0.name) \(Formatters.duration($0.activeDuration))"
        }
        if apps.isEmpty { return report.headline }
        return apps.joined(separator: " · ")
    }

    private func statusColor(_ report: DailyReport) -> Color {
        guard supportsNarrative(report) else { return .secondary }
        if report.thermalPeak == .critical || report.thermalPeak == .serious { return .red }
        if report.peakMemoryPressure == .high || report.averageCPU >= 60 { return .orange }
        if report.peakMemoryPressure == .elevated || report.thermalPeak == .fair { return .yellow }
        return .green
    }

    private func primaryInsight(_ report: DailyReport) -> ReportInsight? {
        report.recommendations.first ?? report.importantMoments.first ?? report.correlations.first
    }

    private func activeUseMeaning(_ report: DailyReport) -> String {
        if report.activeDuration < 60 * 60 { return "a lighter recorded day" }
        if report.activeDuration < 5 * 60 * 60 { return "a typical active stretch" }
        return "a long active stretch"
    }

    private func processorMeaning(_ value: Double) -> String {
        switch value {
        case 60...: return "heavy overall"
        case 35..<60: return "moderate overall"
        default: return "light overall"
        }
    }

    private func memoryLabel(_ report: DailyReport) -> String {
        switch report.peakMemoryPressure {
        case .high: return "Constrained"
        case .elevated: return "Noticeable"
        case .low: return "Comfortable"
        case nil: return "Unknown"
        }
    }

    private func memoryMeaning(_ report: DailyReport) -> String {
        switch report.peakMemoryPressure {
        case .high: return "responsiveness may have slowed"
        case .elevated: return "less spare headroom"
        case .low: return "app switching should feel normal"
        case nil: return "not enough evidence"
        }
    }

    private func memoryColor(_ report: DailyReport) -> Color {
        switch report.peakMemoryPressure {
        case .high, .elevated: return .orange
        case .low, nil: return .primary
        }
    }

    private func thermalLabel(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        case .unknown: return "Unknown"
        }
    }

    private func thermalMeaning(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: return "full thermal headroom"
        case .fair: return "slowdown was unlikely"
        case .serious, .critical: return "performance may have been limited"
        case .unknown: return "no thermal reading"
        }
    }

    private func thermalColor(_ level: ThermalLevel) -> Color {
        switch level {
        case .serious, .critical: return .orange
        default: return .primary
        }
    }

    private func insightSymbol(_ kind: InsightKind) -> String {
        switch kind {
        case .observation: return "sparkle.magnifyingglass"
        case .efficient: return "checkmark.circle"
        case .caution: return "exclamationmark.triangle"
        case .recommendation: return "arrow.right.circle"
        }
    }

    private func insightColor(_ kind: InsightKind) -> Color {
        switch kind {
        case .caution: return .orange
        case .efficient: return .green
        case .observation, .recommendation: return .accentColor
        }
    }

    private func supportsNarrative(_ report: DailyReport) -> Bool {
        (report.longestContinuousCoverage ?? 0) >= CoverageEvaluator.narrativeMinimum
    }

    private func dayWord(_ count: Int) -> String {
        "\(count) \(count == 1 ? "day" : "days")"
    }
}

private struct HistoryTrendChart: View {
    let reports: [DailyReport]

    private var points: [HistoryTrendPoint] {
        reports.compactMap { report in
            guard let date = DayBoundaries.interval(for: report.dayKey)?.start else { return nil }
            return HistoryTrendPoint(report: report, date: date)
        }
    }

    private var maximumHours: Double {
        max(points.map(\.activeHours).max() ?? 1, 1)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                trackLabel(
                    title: "Active use",
                    value: averageActiveLabel,
                    symbol: "person.crop.circle"
                )
                activeUseChart
            }

            HStack(alignment: .center, spacing: 14) {
                trackLabel(
                    title: "Processor",
                    value: averageCPULabel,
                    symbol: "cpu"
                )
                processorChart
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var activeUseChart: some View {
        Chart(points) { point in
            BarMark(
                x: .value("Day", point.date),
                y: .value("Active hours", point.activeHours)
            )
            .foregroundStyle(Color.accentColor.opacity(0.28))
            .cornerRadius(3)
        }
        .chartYScale(domain: 0...(maximumHours * 1.12))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text("\(hours, format: .number.precision(.fractionLength(0)))h")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .frame(height: 104)
        .accessibilityLabel("Daily active app use")
    }

    private var processorChart: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Day", point.date),
                    y: .value("Average CPU", point.averageCPU)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Day", point.date),
                    y: .value("Average CPU", point.averageCPU)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                if point.memoryPressure == .elevated || point.memoryPressure == .high {
                    PointMark(
                        x: .value("Memory pressure day", point.date),
                        y: .value("Average CPU", point.averageCPU)
                    )
                    .foregroundStyle(.orange)
                    .symbolSize(point.memoryPressure == .high ? 44 : 28)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: reports.count <= 7 ? reports.count : 6)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.08))
                AxisValueLabel(format: reports.count <= 7 ? .dateTime.weekday(.narrow) : .dateTime.month().day())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 126)
        .accessibilityLabel("Daily whole-machine processor demand and memory pressure")
    }

    private func trackLabel(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 108, alignment: .leading)
    }

    private var averageActiveLabel: String {
        guard !reports.isEmpty else { return "No data" }
        let duration = reports.reduce(0) { $0 + $1.activeDuration } / Double(reports.count)
        return "\(Formatters.duration(duration)) average"
    }

    private var averageCPULabel: String {
        guard !reports.isEmpty else { return "No data" }
        let average = reports.reduce(0) { $0 + $1.averageCPU } / Double(reports.count)
        return "\(Formatters.percent(average)) average"
    }
}

private struct HistoryTrendPoint: Identifiable {
    let report: DailyReport
    let date: Date

    var id: String { report.dayKey }
    var activeHours: Double { report.activeDuration / 3_600 }
    var averageCPU: Double { report.averageCPU }
    var memoryPressure: MemoryPressureLevel? { report.peakMemoryPressure }
}

private struct HistorySummaryMetric: View {
    let title: String
    let value: String
    let detail: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryDayRow: View {
    let report: DailyReport
    let maximumActiveDuration: TimeInterval
    let isExpanded: Bool
    let takeaway: String
    let apps: String
    let statusColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(dayName)
                        .font(.subheadline.weight(.semibold))
                    Text(dayDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 82, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(takeaway)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(apps)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HistoryRowBarMetric(
                    title: "Active",
                    value: compactDuration(report.activeDuration),
                    progress: report.activeDuration / max(maximumActiveDuration, 1),
                    tint: .accentColor
                )

                HistoryRowBarMetric(
                    title: "CPU",
                    value: Formatters.percent(report.averageCPU),
                    progress: report.averageCPU / 100,
                    tint: report.averageCPU >= 60 ? .orange : .accentColor
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(memoryTint)
                            .frame(width: 6, height: 6)
                        Text(memoryText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(memoryTint == .secondary ? Color.primary : memoryTint)
                    }
                }
                .frame(width: 78, alignment: .leading)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(dayName), \(takeaway), \(apps)")
        .accessibilityHint(isExpanded ? "Collapse daily briefing" : "Show daily briefing")
    }

    private var dayName: String {
        guard let interval = DayBoundaries.interval(for: report.dayKey) else { return report.dayKey }
        return interval.start.formatted(.dateTime.weekday(.wide))
    }

    private var dayDate: String {
        guard let interval = DayBoundaries.interval(for: report.dayKey) else { return "" }
        return interval.start.formatted(.dateTime.month(.abbreviated).day())
    }

    private var memoryText: String {
        switch report.peakMemoryPressure {
        case .high: return "High"
        case .elevated: return "Raised"
        case .low: return "Normal"
        case nil: return "Unknown"
        }
    }

    private var memoryTint: Color {
        switch report.peakMemoryPressure {
        case .high, .elevated: return .orange
        case .low: return .green
        case nil: return .secondary
        }
    }

    private func compactDuration(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int(duration / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }
}

private struct HistoryRowBarMetric: View {
    let title: String
    let value: String
    let progress: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.13))
                    Capsule()
                        .fill(tint.opacity(0.78))
                        .frame(width: proxy.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: 3)
        }
        .frame(width: 76)
    }
}

private struct ExpandedDayMetric: View {
    let title: String
    let value: String
    let meaning: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(meaning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryAppBar: View {
    let name: String
    let duration: TimeInterval
    let maximumDuration: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(width: 105, alignment: .leading)

            GeometryReader { proxy in
                Capsule()
                    .fill(Color.accentColor.opacity(0.2))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.72))
                            .frame(width: proxy.size.width * min(max(duration / max(maximumDuration, 1), 0), 1))
                    }
            }
            .frame(height: 5)

            Text(Formatters.duration(duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 92, alignment: .trailing)
        }
    }
}
