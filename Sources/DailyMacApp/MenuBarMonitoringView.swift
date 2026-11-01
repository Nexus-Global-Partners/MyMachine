import AppKit
import DailyMacCore
import SwiftUI

struct MenuBarMonitoringView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(TimelineDisplayMode.storageKey)
    private var timelineDisplayMode = TimelineDisplayMode.precise.rawValue
    @State private var selectedInstruments: Set<MachineInstrument> = [.cpu, .gpu, .battery]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(alignment: .top, spacing: 19) {
            InstrumentPanel(selected: $selectedInstruments, followsRange: model.menuBarIsHistorical)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(0.065)).frame(width: 1)
            VStack(spacing: 13) {
                header
                if let message = model.menuBarRefreshMessage, model.menuBarMonitoringContent != nil {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Group {
                if let content = model.menuBarMonitoringContent {
                    VStack(spacing: 0) {
                        if content.snapshot.sampleCount > 0 || model.menuBarIsHistorical {
                            InstrumentHistoryView(content: content, selected: selectedInstruments,
                                                  mode: selectedTimelineDisplayMode,
                                                  navigationBounds: model.menuBarNavigationBounds,
                                                  batteryEstimate: model.menuBarIsHistorical ? nil : model.currentBatteryDischargeEstimate,
                                                  onPan: model.panMenuBar,
                                                  onPanStateChange: model.setMenuBarPanning,
                                                  onJumpToActivity: model.jumpMenuBarToRecordedActivity)
                        } else if model.menuBarIsHistorical {
                            historicalEmptyState
                        } else {
                            emptyState
                        }
                    }
                } else if model.menuBarIsRefreshing {
                    loadingState
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else if model.menuBarIsHistorical {
                    historicalEmptyState
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    emptyState
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: min(980, (NSScreen.main?.visibleFrame.width ?? 1020) - 40), height: 480)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                InstrumentGlassBackdrop()
                    .overlay(colorScheme == .dark ? Color.black.opacity(0.12) : Color.white.opacity(0.52))
            }
        }
    }

    private var header: some View {
            HStack(spacing: 12) {
                dayActivitySummary
                    .frame(height: 29)
                Spacer(minLength: 2)

                HStack(alignment: .center, spacing: 9) {
                    InstrumentTimeControl()
                    Button(action: model.refreshMenuBarNow) {
                        Group {
                            if model.menuBarIsRefreshing { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.clockwise") }
                        }.frame(width: 14, height: 14)
                    }
                    .buttonStyle(GlassyIconButtonStyle())
                    .disabled(model.menuBarIsRefreshing)
                    .help("Refresh readings")
                    .accessibilityLabel("Refresh readings")
                    moreOptionsMenu
                }
            }
    }

    private var dayActivitySummary: some View {
        let historical = model.menuBarIsHistorical
        let content = model.menuBarMonitoringContent
        let totals = historical ? content.map {
            RecordedActivityTotals.measure($0.samples, in: $0.snapshot.interval)
        } : model.todayActivityTotals
        let period = activityPeriodTitle
        let you = totals.flatMap { $0.lastReading == nil ? nil : compactDuration($0.you) } ?? "—"
        let mac = totals.flatMap { $0.lastReading == nil ? nil : compactDuration($0.machine) } ?? "—"
        return HStack(spacing: 12) {
            Text(period)
                .foregroundStyle(.secondary)
            Label(you, systemImage: "person.fill")
                .help("You: recorded non-idle time. Not attention or productivity.")
                .accessibilityLabel("You, \(you)")
            Label(mac, systemImage: "laptopcomputer")
                .help("Mac: recorded awake time, including background work. Sleep and missing readings are excluded.")
                .accessibilityLabel("Mac awake, \(mac)")
        }
        .font(.system(size: 10, weight: .medium))
        .labelStyle(ActivityDurationLabelStyle())
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .help(historical
            ? "Recorded activity in the displayed graph period. Sleep and missing readings are excluded."
            : "Recorded today, refreshed with every saved reading. Sleep and missing readings are excluded.")
    }

    private var activityPeriodTitle: String {
        guard model.menuBarIsHistorical else { return "Today" }
        guard let interval = model.menuBarMonitoringContent?.snapshot.interval else {
            return model.menuBarSelectedDayStart.map(activityDayTitle) ?? "History"
        }
        // An exact midnight end belongs to the preceding displayed day.
        let lastDay = interval.end.addingTimeInterval(-0.001)
        if Calendar.autoupdatingCurrent.isDate(interval.start, inSameDayAs: lastDay) {
            return activityDayTitle(interval.start)
        }
        return "\(interval.start.formatted(.dateTime.day().month(.abbreviated)))–\(lastDay.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func activityDayTitle(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private struct ActivityDurationLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) {
                configuration.icon.foregroundStyle(.secondary)
                configuration.title.foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var liveMachineSummary: some View {
        if model.collectionState == .monitoring,
           model.menuBarSelectedDayStart == nil,
           let signal = MachineStatusSignal.current(
                sample: model.latestSystem,
                recentSamples: model.recentSystemSamples
           ) {
            let average = MachineDemandAverage.current(
                sample: model.latestSystem,
                recentSamples: model.recentSystemSamples
            )
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(for: signal))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(statusLabel(for: signal))
                    .foregroundStyle(.primary)
                Text("CPU \(average?.cpuPercent ?? signal.cpuPercent)%")
                    .foregroundStyle(MachinePalette.processor)
                if let gpu = average?.gpuPercent ?? signal.gpuPercent {
                    Text("GPU \(gpu)%")
                        .foregroundStyle(MachinePalette.graphics)
                }
                if selectedTimelineDisplayMode == .precise {
                    FanSpeedGauge()
                }
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .help("Live machine status and latest two-minute average demand. CPU and GPU are whole-machine readings, not a measure of your focus.")
        } else if model.menuBarSelectedDayStart == nil {
            Text(model.collectionState == .paused
                 ? "Monitoring paused"
                 : model.menuBarIsRefreshing ? "Updating" : (staleReadingLabel ?? "Waiting for live reading"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func compactDuration(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int(duration / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes)m" }
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private func statusLabel(for signal: MachineStatusSignal) -> String {
        if signal.health != .comfortable { return signal.health.label }
        return signal.effort == .nearCapacity || signal.effort == .high ? "Busy" : "Comfortable"
    }

    private func statusColor(for signal: MachineStatusSignal) -> Color {
        switch signal.health {
        case .critical: MachinePalette.critical
        case .pressured: .orange
        case .watch: .yellow
        case .comfortable: .green
        }
    }

    private var staleReadingLabel: String? {
        guard model.menuBarSelectedDayStart == nil,
              model.collectionState == .monitoring,
              let latest = model.menuBarMonitoringContent?.samples.last,
              !MachineStatusSignal.isFresh(latest) else { return nil }
        let age = max(0, Date().timeIntervalSince(latest.timestamp))
        return age < 60 ? "Last reading <1m ago" : "Last reading \(Int(age / 60))m ago"
    }

    private var menuBarRangeTitle: String {
        let displayedRange = model.menuBarMonitoringContent?.snapshot.range
            ?? model.menuBarMonitoringRange
        switch displayedRange {
        case .today: return "Today"
        case .oneHour: return "Last hour"
        case .fourHours: return "Last 4 hours"
        case .sixHours: return "Last 6 hours"
        case .twelveHours: return "Last 12 hours"
        case .twentyFourHours: return "Last 24 hours"
        case .fortyEightHours: return "Last 48 hours"
        case .oneWeek: return "Last 7 days"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.menuBarIsRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: emptyStateSymbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text(emptyStateTitle)
                .font(.subheadline.weight(.medium))
            Text(emptyStateDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .padding(20)
    }

    private var historicalEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No readings for this period")
                .font(.subheadline.weight(.medium))
            Text("MY MACHINE keeps detailed readings for \(settingsRetentionDays) days. Unrecorded time isn't treated as sleep or zero activity.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, minHeight: 188)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(model.menuBarIsHistorical ? "Opening history…" : "Opening live view…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 188)
    }

    private var settingsRetentionDays: Int { max(1, model.settings.rawRetentionDays) }

    private var historicalDayControl: some View {
        HStack(spacing: 2) {
            Button(action: model.browsePreviousMenuBarDay) {
                Image(systemName: "chevron.left")
                    .frame(width: 20, height: 28)
            }
            .disabled(!model.canBrowsePreviousMenuBarDay)
            .help("Previous day")
            .accessibilityLabel("Previous day")

            if let day = model.menuBarSelectedDayStart {
                Text(day.formatted(.dateTime.weekday(.abbreviated).day()))
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 48)
                    .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            }

            Button(action: model.browseNextMenuBarDay) {
                Image(systemName: "chevron.right")
                    .frame(width: 20, height: 28)
            }
            .help("Next day")
            .accessibilityLabel("Next day")

            Button("Live", action: model.returnToLiveMenuBarDay)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .help("Return to today's live view")
                .accessibilityLabel("Return to today's live view")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .background(.thinMaterial, in: Capsule())
    }

    private var moreOptionsMenu: some View {
        Menu {
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
            Button {
                model.diagnoseMachine()
            } label: {
                Label("Diagnose My Machine", systemImage: "stethoscope")
            }
            .disabled(model.diagnosisState.isPreparing)
            Divider()
            Button("Quit MY MACHINE") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 14, height: 14)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(GlassyIconButtonStyle())
        .fixedSize()
        .help("More options")
        .accessibilityLabel("More options")
    }

    private var selectedTimelineDisplayMode: TimelineDisplayMode {
        TimelineDisplayMode(rawValue: timelineDisplayMode) ?? .precise
    }

    private var emptyStateSymbol: String {
        switch model.collectionState {
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "clock"
        }
    }

    private var emptyStateTitle: String {
        if model.menuBarIsRefreshing { return "Preparing \(menuBarRangeTitle.lowercased())" }
        switch model.collectionState {
        case .paused: return "Monitoring is paused"
        case .failed: return "Recent history is unavailable"
        default: return "No readings in \(menuBarRangeTitle.lowercased()) yet"
        }
    }

    private var emptyStateDetail: String {
        if let message = model.menuBarRefreshMessage { return message }
        switch model.collectionState {
        case .paused:
            return "Nothing new is being recorded. Resume when you want the timeline to continue."
        case .failed:
            return "MY MACHINE could not prepare recent monitoring. Refresh once; reopen it if this continues."
        default:
            return "MY MACHINE will fill this view automatically as it observes the Mac."
        }
    }
}
