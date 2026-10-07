import DailyMacCore
import SwiftUI

/// One time control: pick a span, move through it, return to now.
/// Native menus retain keyboard navigation and familiar selection marks.
struct InstrumentTimeControl: View {
    @EnvironmentObject private var model: AppModel

    private var title: String {
        if let window = model.menuBarPannedInterval, model.menuBarMonitoringRangePreference.isSmart {
            return window.start.formatted(.dateTime.month(.abbreviated).day())
        }
        if let day = model.menuBarSelectedDayStart {
            return Calendar.autoupdatingCurrent.isDateInYesterday(day)
                ? "Yesterday" : day.formatted(.dateTime.month(.abbreviated).day())
        }
        return model.menuBarMonitoringRangePreference.isSmart ? "Today" : model.menuBarMonitoringRangePreference.compactLabel
    }

    var body: some View {
        HStack(spacing: 5) {
            if model.menuBarIsHistorical {
                Button("Now", action: model.returnToLiveMenuBarDay)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).frame(height: 29)
                    .background(InstrumentGlassSurface(radius: 10))
                    .buttonStyle(InstrumentControlStyle())
                    .accessibilityLabel("Return to live readings")
            }
            HStack(spacing: 0) {
                step(-1, symbol: "chevron.left", title: "Earlier")
                Menu {
                    Button(action: model.selectSmartMenuBarMonitoringRange) {
                        item("Today", selected: model.menuBarMonitoringRangePreference.isSmart && !model.menuBarIsHistorical)
                    }
                    Divider()
                    ForEach(MonitoringRange.selectableRanges) { range in
                        Button { model.selectMenuBarMonitoringRange(range) } label: {
                            item(range.label, selected: model.menuBarMonitoringRangePreference == .fixed(range))
                        }
                    }
                    Divider()
                    Button("Yesterday") {
                        model.selectSmartMenuBarMonitoringRange()
                        model.browsePreviousMenuBarDay()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 58, minHeight: 29).padding(.horizontal, 4)
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(InstrumentControlStyle())
                .accessibilityLabel("Time range: \(title)")
                .help("Today follows your observed waking day, including work across midnight. Other durations show the latest hours. Arrows move through history.")
                step(1, symbol: "chevron.right", title: "Later")
            }
            .background(InstrumentGlassSurface(radius: 10))
        }
        .fixedSize()
    }

    private func step(_ direction: Int, symbol: String, title: String) -> some View {
        Button { model.browseMenuBarWindow(direction) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 27, height: 29).contentShape(Rectangle())
        }
        .buttonStyle(InstrumentControlStyle())
        .disabled(model.menuBarIsRefreshing || (direction < 0 ? !model.canBrowsePreviousMenuBarWindow : !model.menuBarIsHistorical))
        .accessibilityLabel("\(title) time window")
        .help(direction < 0 ? "Previous period, same scale" : "Next period, same scale")
    }

    @ViewBuilder private func item(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
