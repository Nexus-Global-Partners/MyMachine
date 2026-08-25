import Foundation

public enum BriefingNotificationPolicy {
    public static let dailyHour = 18

    public static func privateNotificationCopy(for report: DailyReport) -> (title: String, body: String)? {
        guard (report.longestContinuousCoverage ?? 0) >= CoverageEvaluator.narrativeMinimum else { return nil }
        return ("Daily report ready", "Your private MY MACHINE briefing is available.")
    }

    public static func nextDailyDelivery(after now: Date, calendar input: Calendar = .autoupdatingCurrent) -> Date? {
        var calendar = input
        calendar.timeZone = input.timeZone
        var components = DateComponents()
        components.hour = dailyHour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}
