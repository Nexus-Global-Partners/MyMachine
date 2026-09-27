import AppKit
import DailyMacCore
import SwiftUI

/// Chart contract: compare days, not interpolated sleep curves. CPU/GPU dots
/// show time-weighted observed means, stems end at observed peaks (0...100%).
/// A separate, common-scale pink bar shows human-use duration. Missing values
/// have no mark. Saved daily summaries never masquerade as intraday readings.
/// Native SwiftUI, same blue/cyan/pink palette as the live graph; GPU uses an
/// open marker as a second distinction. Selecting a day reveals retained detail.
struct LongRangeMonitoringView: View {
    let content: MonitoringDisplayState
    let displayMode: TimelineDisplayMode
    @State private var focusedDayID: String?

    private let cpu = Color(nsColor: .systemBlue)
    private let gpu = Color(nsColor: .systemTeal)
    private let you = Color(.displayP3, red: 1, green: 0.17, blue: 0.84)

    private var days: [MonitoringDaySummary] { content.dailySummaries }
    private var focusedDay: MonitoringDaySummary? { days.first { $0.id == focusedDayID } }
    private var title: String { content.snapshot.range == .oneWeek ? "7 days at a glance" : "48 hours at a glance" }
    private var activeTotal: TimeInterval { days.reduce(0) { $0 + $1.humanActiveDuration } }
    private var activeMaximum: TimeInterval { max(3600, days.map(\.humanActiveDuration).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MonitoringTimelineView(
                    snapshot: content.snapshot,
                    samples: content.samples.filter { $0.timestamp >= content.snapshot.interval.end.addingTimeInterval(-900) },
                    backgroundPoints: [], events: content.events,
                    presentation: .menuBar, displayMode: displayMode
                ).liveStatusPill
                Spacer(minLength: 0)
                if focusedDay == nil {
                    Text("You · \(Formatters.duration(activeTotal))")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .help("Observed human use across the displayed days. Unknown time is not counted.")
                }
            }

            if let day = focusedDay {
                dayDetail(day)
            } else {
                overview
            }
        }
        .onChange(of: content.snapshot.range) { focusedDayID = nil }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 10) {
                    Label("CPU", systemImage: "circle.fill").foregroundStyle(cpu)
                    Label("GPU est.", systemImage: "circle").foregroundStyle(gpu)
                    Text("Average → peak").foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .medium))
            }

            GeometryReader { geometry in
                let axis: CGFloat = 34
                let plotWidth = max(1, geometry.size.width - axis)
                ZStack(alignment: .topLeading) {
                    overviewGrid(width: plotWidth)
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(days) { day in
                            dayColumn(day)
                                .frame(width: plotWidth / CGFloat(max(1, days.count)))
                        }
                    }
                }
            }
            .frame(height: displayMode == .precise ? 235 : 221)

            HStack(alignment: .top, spacing: 8) {
                Text(overviewFootnote)
                Spacer(minLength: 0)
                Text("Select a day to explore")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    private func overviewGrid(width: CGFloat) -> some View {
        ForEach([0, 50, 100], id: \.self) { value in
            let y = 120 * (1 - CGFloat(value) / 100) + 8
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
            .stroke(.secondary.opacity(value == 50 ? 0.13 : 0.07), lineWidth: 0.75)
            Text("\(value)%")
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                .offset(x: width + 7, y: y - 6)
        }
    }

    private func dayColumn(_ day: MonitoringDaySummary) -> some View {
        Button {
            focusedDayID = day.id
        } label: {
            VStack(spacing: 7) {
                HStack(spacing: 14) {
                    demandMark(mean: day.averageCPU, peak: day.peakCPU, color: cpu, open: false)
                    demandMark(mean: day.averageGPU, peak: day.peakGPU, color: gpu, open: true)
                }
                .frame(height: 120)
                .padding(.top, 8)
                .padding(.bottom, 3)

                Text(day.start.formatted(.dateTime.weekday(.abbreviated).day()))
                    .font(.system(size: 11, weight: Calendar.current.isDateInToday(day.start) ? .semibold : .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Text(day.isPartialDay
                     ? (Calendar.current.isDateInToday(day.start) ? "So far" : "From \(day.interval.start.formatted(date: .omitted, time: .shortened))")
                     : "Full day")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                VStack(spacing: 5) {
                    Text(day.observedDuration > 0 ? Formatters.duration(day.humanActiveDuration) : "—")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(day.humanActiveDuration > 0 ? you : .secondary)
                    GeometryReader { proxy in
                        Capsule().fill(.secondary.opacity(0.08))
                        Capsule().fill(you.opacity(0.75))
                            .frame(width: proxy.size.width * min(1, day.humanActiveDuration / activeMaximum))
                    }.frame(height: 3)
                }
                .padding(.horizontal, 12)
                if displayMode == .precise {
                    Text(day.source == .retained ? "Saved summary" : (day.observedDuration > 0 ? "\(Formatters.duration(day.observedDuration)) recorded" : "No readings"))
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(DayOverviewButtonStyle())
        .help(dayHelp(day))
        .accessibilityLabel(dayHelp(day))
        .accessibilityHint("Opens this day's available detail")
    }

    private func demandMark(mean: Double?, peak: Double?, color: Color, open: Bool) -> some View {
        GeometryReader { proxy in
            if let mean, let peak {
                let averageY = proxy.size.height * (1 - min(100, max(0, mean)) / 100)
                let peakY = proxy.size.height * (1 - min(100, max(mean, peak)) / 100)
                Capsule().fill(color.opacity(0.19))
                    .frame(width: 5, height: max(2, averageY - peakY))
                    .position(x: proxy.size.width / 2, y: (averageY + peakY) / 2)
                Capsule().fill(color.opacity(0.65))
                    .frame(width: 9, height: 1.5)
                    .position(x: proxy.size.width / 2, y: peakY)
                Circle()
                    .fill(open ? Color(nsColor: .windowBackgroundColor) : color)
                    .overlay(Circle().strokeBorder(color, lineWidth: 1.8))
                    .frame(width: 7, height: 7)
                    .position(x: proxy.size.width / 2, y: averageY)
            } else {
                Text("—").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }.frame(width: 12)
    }

    @ViewBuilder private func dayDetail(_ day: MonitoringDaySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { focusedDayID = nil } label: {
                    Label(title, systemImage: "chevron.left")
                        .font(.caption.weight(.medium))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text(day.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 18) {
                metric("You", value: duration(day.humanActiveDuration, known: day.observedDuration > 0), color: you)
                metric("Background", value: duration(day.backgroundDuration, known: day.observedDuration > 0))
                metric("Asleep", value: day.confirmedSleepDuration > 0 ? duration(day.confirmedSleepDuration) : "Not confirmed")
                Spacer(minLength: 0)
                metric("CPU avg / peak", value: pair(day.averageCPU, day.peakCPU), color: cpu)
                metric("GPU est. avg / peak", value: pair(day.averageGPU, day.peakGPU), color: gpu)
            }
            .padding(.vertical, 4)

            if !daySamples(day).isEmpty {
                let samples = daySamples(day)
                let focus = inspectionInterval(day, samples: samples)
                let detailedDuration = MonitoringHistory.resourceSummary(from: samples, within: focus).observedDuration
                let snapshot = InsightEngine().makeMonitoringSnapshot(
                    range: focus.duration <= 3600 ? .oneHour : (focus.duration <= 6 * 3600 ? .sixHours : .twentyFourHours),
                    endingAt: focus.end, samples: samples, appResourceSamples: [], intervalOverride: focus
                )
                MonitoringTimelineView(
                    snapshot: snapshot, samples: samples, backgroundPoints: [],
                    events: content.events, presentation: .menuBar,
                    displayMode: displayMode, historical: true
                )
                .equatable()
                .id(day.id)
                HStack {
                    Text("Available detail · \(Formatters.duration(detailedDuration)) · drag for exact readings")
                    Spacer()
                    if day.peakMemoryPressure == .high {
                        Label("Memory pressure", systemImage: "memorychip")
                    }
                    if day.thermalPeak == .serious || day.thermalPeak == .critical {
                        Label("Thermal pressure", systemImage: "thermometer.high")
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: day.source == .retained ? "archivebox" : "clock.badge.questionmark")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(day.source == .retained ? "The day is saved. Its detailed readings have expired." : "No processor readings were recorded for this period.")
                        .font(.subheadline.weight(.medium))
                    Text(day.source == .retained
                         ? "Daily totals and CPU peaks remain available. Older summaries may not include GPU readings."
                         : "Confirmed sleep is kept separately. Missing readings are never treated as zero load.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if day.peakMemoryPressure == .high {
                        Label("Memory pressure was recorded", systemImage: "memorychip")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if day.thermalPeak == .serious || day.thermalPeak == .critical {
                        Label("Thermal pressure was recorded", systemImage: "thermometer.high")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
    }

    private func metric(_ label: String, value: String, color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(color)
        }.fixedSize()
    }

    private func daySamples(_ day: MonitoringDaySummary) -> [SystemSample] {
        content.samples.filter { $0.duration > 0 && $0.timestamp > day.interval.start && $0.timestamp <= day.interval.end }
    }

    private func inspectionInterval(_ day: MonitoringDaySummary, samples: [SystemSample]) -> DateInterval {
        let valid = samples.filter { $0.duration > 0 }
        guard let first = valid.first, let last = valid.last else { return day.interval }
        let start = max(day.interval.start, first.timestamp.addingTimeInterval(-CoverageEvaluator.boundedDuration(of: first)))
        let end = min(day.interval.end, max(start.addingTimeInterval(1), last.timestamp))
        return DateInterval(start: start, end: end)
    }

    private func pair(_ mean: Double?, _ peak: Double?) -> String {
        guard let mean, let peak else { return "—" }
        return "\(Int(mean.rounded())) / \(Int(peak.rounded()))%"
    }

    private func duration(_ value: TimeInterval, known: Bool = true) -> String {
        guard known else { return "—" }
        return value <= 0 ? "0 min" : (value < 60 ? "<1 min" : Formatters.duration(value))
    }

    private var overviewFootnote: String {
        let partial = days.contains { $0.source == .unavailable }
        let legacy = days.contains { $0.source == .retained && $0.averageGPU == nil }
        if legacy { return "Time with you in pink · older GPU readings unavailable" }
        if partial { return "Time with you in pink · — means no readings" }
        return "Time with you in pink · load averages exclude sleep"
    }

    private func dayHelp(_ day: MonitoringDaySummary) -> String {
        "\(day.start.formatted(date: .abbreviated, time: .omitted)). You \(Formatters.duration(day.humanActiveDuration)). Background \(Formatters.duration(day.backgroundDuration)). Confirmed sleep \(Formatters.duration(day.confirmedSleepDuration)). CPU average and peak \(pair(day.averageCPU, day.peakCPU)). GPU estimate average and peak \(pair(day.averageGPU, day.peakGPU)). \(Formatters.duration(day.observedDuration)) observed."
    }
}

private struct DayOverviewButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 8))
    }
}
