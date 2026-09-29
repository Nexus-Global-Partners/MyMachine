import Foundation

/// Recorded time only. Does not extrapolate through sleep, pauses, or lost samples.
public struct RecordedActivityTotals: Equatable, Sendable {
    public let you: TimeInterval
    public let machine: TimeInterval
    public let lastReading: Date?

    public static func measure(_ samples: [SystemSample], in window: DateInterval) -> Self {
        func unionDuration(_ intervals: [DateInterval]) -> TimeInterval {
            var total: TimeInterval = 0
            var coveredUntil = window.start
            for span in intervals.sorted(by: { $0.start < $1.start }) {
                total += max(0, span.end.timeIntervalSince(max(coveredUntil, span.start)))
                coveredUntil = max(coveredUntil, span.end)
            }
            return total
        }
        let observed = samples.compactMap { sample -> (SystemSample, DateInterval)? in
            guard let span = TimelineSemantics.observedInterval(for: sample, within: window) else { return nil }
            return (sample, span)
        }
        return Self(
            you: unionDuration(observed.filter { !$0.0.isIdle && $0.0.category != .idle }.map(\.1)),
            machine: unionDuration(observed.map(\.1)),
            lastReading: observed.map { $0.1.end }.max())
    }
}
