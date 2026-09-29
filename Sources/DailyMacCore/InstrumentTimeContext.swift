import Foundation

public struct InstrumentTimeRegion: Equatable, Sendable {
    public enum Kind: String, Sendable { case away, sleep, missing }
    public let interval: DateInterval
    public let kind: Kind
}

public enum InstrumentTimeContext {
    /// Clock-aligned marks, with enough space left for the exact endpoints.
    public static func ticks(in window: DateInterval, width: Double, calendar: Calendar = .current) -> [Date] {
        guard window.duration > 0 else { return [window.start] }
        let desired = window.duration / max(2, floor(width / 110))
        let step = [300.0, 600, 900, 1800, 3600, 7200, 10800, 14400, 21600, 43200, 86400]
            .first(where: { $0 >= desired }) ?? 86400
        let origin = calendar.startOfDay(for: window.start)
        var tick = origin.addingTimeInterval(ceil(window.start.timeIntervalSince(origin) / step) * step)
        let clearance = window.duration * min(0.3, 75 / max(1, width))
        var result = [window.start]
        while tick < window.end {
            if tick.timeIntervalSince(window.start) >= clearance && window.end.timeIntervalSince(tick) >= clearance {
                result.append(tick)
            }
            tick = tick.addingTimeInterval(step)
        }
        result.append(window.end)
        return result
    }

    /// Sensor gaps never become absence. Sleep needs recorded lifecycle evidence.
    public static func regions(presence: TimelinePresenceContext, sleeps: [DateInterval], in window: DateInterval) -> [InstrumentTimeRegion] {
        func clipped(_ intervals: [DateInterval]) -> [DateInterval] {
            intervals.compactMap { span in
                let start = max(span.start, window.start), end = min(span.end, window.end)
                return end > start ? DateInterval(start: start, end: end) : nil
            }
        }
        func subtract(_ exclusions: [DateInterval], from intervals: [DateInterval]) -> [DateInterval] {
            exclusions.reduce(intervals) { remaining, exclusion in
                remaining.flatMap { span -> [DateInterval] in
                    guard span.start < exclusion.end, span.end > exclusion.start else { return [span] }
                    var parts: [DateInterval] = []
                    if span.start < exclusion.start { parts.append(DateInterval(start: span.start, end: exclusion.start)) }
                    if span.end > exclusion.end { parts.append(DateInterval(start: exclusion.end, end: span.end)) }
                    return parts
                }
            }
        }
        let sleep = clipped(sleeps)
        let away = TimelineSemantics.humanAwayIntervals(presence: presence, sleepIntervals: [], within: window)
        let missing = subtract(clipped(presence.awakeIntervals) + sleep, from: [window])
        return (subtract(sleep, from: away).map { InstrumentTimeRegion(interval: $0, kind: .away) }
            + sleep.map { InstrumentTimeRegion(interval: $0, kind: .sleep) }
            + missing.map { InstrumentTimeRegion(interval: $0, kind: .missing) })
            .sorted { $0.interval.start < $1.interval.start }
    }
}
