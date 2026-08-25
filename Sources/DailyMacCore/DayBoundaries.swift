import Foundation

public enum DayBoundaries {
    public static func key(for date: Date, timezone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func interval(for dayKey: String, timezone: TimeZone = .autoupdatingCurrent) -> DateInterval? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: dayKey) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    public static func previousDayKey(from date: Date = Date(), timezone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let previous = calendar.date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-86_400)
        return key(for: previous, timezone: timezone)
    }
}
