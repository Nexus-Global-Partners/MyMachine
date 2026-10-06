import Foundation

/// A time arrow moves the window, never changes its scale. Day browsing uses
/// calendar arithmetic so daylight-saving days are not forced into 24 hours.
public enum HistoryNavigation {
    public static func shifted(_ window: DateInterval, by direction: Int,
                               range: MonitoringRange?, now: Date,
                               calendar: Calendar = .autoupdatingCurrent) -> DateInterval? {
        guard direction == -1 || direction == 1 else { return nil }
        if let range, range != .today {
            let end = window.end.addingTimeInterval(Double(direction) * range.duration)
            // The last window is live, including time elapsed while browsing.
            guard end < now, direction < 0 || end <= now.addingTimeInterval(-range.duration) else { return nil }
            return range.interval(endingAt: end)
        }
        let day = calendar.startOfDay(for: window.start)
        guard let start = calendar.date(byAdding: .day, value: direction, to: day),
              start < calendar.startOfDay(for: now),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }
}
