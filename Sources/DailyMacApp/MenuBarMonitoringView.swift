import AppKit
import DailyMacCore
import SwiftUI

struct MenuBarMonitoringView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(TimelineDisplayMode.storageKey)
    private var timelineDisplayMode = TimelineDisplayMode.precise.rawValue

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if let content = model.menuBarMonitoringContent {
                    VStack(spacing: 0) {
                        if content.snapshot.sampleCount > 0
                            || (model.menuBarSelectedDayStart != nil && !content.events.isEmpty) {
                            MonitoringTimelineView(
                                snapshot: content.snapshot,
                                samples: content.samples,
                                backgroundPoints: content.backgroundPoints,
                                events: content.events,
                                appContributors: content.appContributors,
                                appResourceSamples: content.appResourceSamples,
                                presentation: .menuBar,
                                displayMode: selectedTimelineDisplayMode,
                                historical: model.menuBarSelectedDayStart != nil
                            )
                            .equatable()
                        } else if model.menuBarSelectedDayStart != nil {
                            historicalEmptyState
                        } else {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                } else if model.menuBarIsRefreshing {
                    loadingState
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else if model.menuBarSelectedDayStart != nil {
                    historicalEmptyState
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    emptyState
                }
            }
        }
        .frame(width: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Monitoring")
                    .font(.headline)
                if let day = model.menuBarSelectedDayStart {
                    Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    MenuBarActivitySummaryLabel(
                        activeTodayDuration: model.todayReport?.activeDuration,
                        currentSessionDuration: model.currentSessionDuration
                    )
                }
            }

            Spacer(minLength: 12)

            HStack(alignment: .center, spacing: 9) {
                HStack(spacing: 8) {
                    if model.menuBarIsRefreshing {
                        Text("Updating")
                            .foregroundStyle(.secondary)
                    } else if model.menuBarRefreshMessage != nil {
                        Label("Cached", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                            .help(model.menuBarRefreshMessage ?? "")
                    } else if let staleReadingLabel {
                        Text(staleReadingLabel)
                            .foregroundStyle(.secondary)
                            .help("The graph stays available, but no fresh machine reading is being claimed.")
                    }
                }
                .font(.caption)

                if model.menuBarSelectedDayStart != nil {
                    historicalDayControl
                } else {
                    MenuBarMonitoringRangeControl(
                        preference: model.menuBarMonitoringRangePreference,
                        effectiveRange: model.menuBarMonitoringContent?.snapshot.range
                            ?? model.menuBarMonitoringRange,
                        effectiveInterval: model.menuBarMonitoringContent?.snapshot.interval,
                        onSelectSmart: model.selectSmartMenuBarMonitoringRange,
                        onSelectRange: model.selectMenuBarMonitoringRange
                    )
                    Button(action: model.browsePreviousMenuBarDay) {
                        Image(systemName: "calendar.badge.clock")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canBrowsePreviousMenuBarDay)
                    .help("Browse yesterday")
                    .accessibilityLabel("Browse yesterday")
                }

                TimelineDisplayModeControl()

                DiagnosisIconButton()

                Button {
                    model.refreshMenuBarNow()
                } label: {
                    if model.menuBarIsRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh monitoring")
                .accessibilityLabel("Refresh monitoring")
                .disabled(model.menuBarIsRefreshing)

                moreOptionsMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            Text("No detailed readings for this day")
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
            Text(model.menuBarSelectedDayStart == nil ? "Opening live view…" : "Opening day…")
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
            if model.collectionState == .paused {
                Button("Resume Monitoring") { model.startMonitoring() }
            } else {
                Button("Pause for One Hour") { model.pauseForOneHour() }
                Button("Pause Until Tomorrow") { model.pauseUntilTomorrow() }
                Button("Pause Until I Resume") { model.pauseIndefinitely() }
            }
            Divider()
            Menu("Appearance") {
                ForEach(AppAppearance.allCases) { option in
                    Button {
                        appearance = option.rawValue
                    } label: {
                        Label(option.label, systemImage: appearance == option.rawValue ? "checkmark" : option.symbol)
                    }
                }
            }
            Divider()
            SettingsLink {
                Text("Settings & Privacy…")
            }
            Divider()
            Button("Quit MY MACHINE") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 14, height: 14)
        }
        .menuStyle(.borderlessButton)
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
