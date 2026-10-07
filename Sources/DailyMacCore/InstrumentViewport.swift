import Foundation

/// Direct manipulation uses elapsed time, never a compressed or inferred clock.
public enum InstrumentViewport {
    public static func panned(_ window: DateInterval, translation: Double, width: Double,
                              earliest: Date, latest: Date) -> DateInterval {
        guard translation.isFinite, width.isFinite, width > 0, window.duration > 0,
              latest.timeIntervalSince(earliest) >= window.duration else { return window }
        let offset = -translation / width * window.duration
        let start = min(latest.addingTimeInterval(-window.duration),
                        max(earliest, window.start.addingTimeInterval(offset)))
        return DateInterval(start: start, duration: window.duration)
    }

    public static func ticks(in window: DateInterval, width: Double, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        let base = InstrumentTimeContext.ticks(in: window, width: width, calendar: calendar)
        guard window.duration > 0 else { return base }
        var boundaries: [Date] = []
        var day = calendar.startOfDay(for: window.start)
        while day <= window.end {
            if day >= window.start { boundaries.append(day) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        let clearance = window.duration * 65 / max(1, width)
        // Exact endpoints stay. Midnight replaces nearby interior ticks, not time.
        let interiorBoundaries = boundaries.filter {
            $0 == window.start || $0 == window.end ||
                ($0.timeIntervalSince(window.start) >= clearance && window.end.timeIntervalSince($0) >= clearance)
        }
        return Array(Set(base.filter { tick in
            tick == window.start || tick == window.end ||
                !interiorBoundaries.contains { abs($0.timeIntervalSince(tick)) < clearance }
        } + interiorBoundaries)).sorted()
    }

    public static func isDayBoundary(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        abs(date.timeIntervalSince(calendar.startOfDay(for: date))) < 0.5
    }
}
