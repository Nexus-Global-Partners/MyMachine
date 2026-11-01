import DailyMacCore
import SwiftUI

/// Day navigation and scale are independent: arrows always move a calendar day.
struct InstrumentTimeControl: View {
    @EnvironmentObject private var model: AppModel
    @State private var calendarPresented = false

    private var title: String {
        let day = model.menuBarNavigationDay
        if Calendar.autoupdatingCurrent.isDateInToday(day) { return "Today" }
        if Calendar.autoupdatingCurrent.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    private var range: MonitoringRange {
        if case .fixed(let range) = model.menuBarMonitoringRangePreference { return range }
        return .today
    }

    var body: some View {
        HStack(spacing: 7) {
            if model.menuBarIsHistorical {
                Button("Today", action: model.returnToLiveMenuBarDay)
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(InstrumentControlStyle())
                    .accessibilityLabel("Return to today and live readings")
            }
            HStack(spacing: 0) {
                step(-1, symbol: "chevron.left", title: "Previous day")
                Button { calendarPresented.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        Image(systemName: "calendar").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 65, minHeight: 29).padding(.horizontal, 3)
                }
                .buttonStyle(InstrumentControlStyle())
                .accessibilityLabel("Choose history date, \(title)")
                .help("Pick any day in retained history. Arrows move one day at the same scale.")
                .popover(isPresented: $calendarPresented, arrowEdge: .bottom) {
                    DatePicker("History date", selection: Binding(
                        get: { model.menuBarNavigationDay },
                        set: { model.selectMenuBarDay($0); calendarPresented = false }),
                        in: model.menuBarNavigationBounds.start...model.menuBarNavigationBounds.end,
                        displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                }
                step(1, symbol: "chevron.right", title: "Next day")
            }
            .background(InstrumentGlassSurface(radius: 10))
            Picker("Graph scale", selection: Binding(get: { range }, set: model.selectMenuBarMonitoringRange)) {
                Text("1h").tag(MonitoringRange.oneHour)
                Text("6h").tag(MonitoringRange.sixHours)
                Text("Day").tag(MonitoringRange.today)
                if ![MonitoringRange.oneHour, .sixHours, .today].contains(range) {
                    Text(range.compactLabel).tag(range)
                }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small)
            .frame(width: [MonitoringRange.oneHour, .sixHours, .today].contains(range) ? 111 : 148)
            .help("Graph scale. Changing scale keeps the selected day.")
        }
        .fixedSize()
    }

    private func step(_ direction: Int, symbol: String, title: String) -> some View {
        Button { model.browseMenuBarDay(direction) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .frame(width: 24, height: 29).contentShape(Rectangle())
        }
        .buttonStyle(InstrumentControlStyle())
        .disabled(direction < 0 ? !model.canBrowsePreviousMenuBarDay : Calendar.autoupdatingCurrent.isDateInToday(model.menuBarNavigationDay))
        .accessibilityLabel(title)
        .help(title)
    }
}
