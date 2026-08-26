import Foundation

/// A battery reading that is safe to place on the shared monitoring timeline.
public struct BatteryTimelineReading: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let percent: Double

    public init(id: UUID, timestamp: Date, percent: Double) {
        self.id = id
        self.timestamp = timestamp
        self.percent = percent
    }
}

/// One uninterrupted period on battery power. Adapter readings, unsupported
/// readings, sleep, collection restarts, and recording gaps always split runs.
public struct BatteryTimelineRun: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let readings: [BatteryTimelineReading]

    public init(readings: [BatteryTimelineReading]) {
        self.id = readings.first?.id ?? UUID()
        self.readings = readings
    }

    public var interval: DateInterval? {
        guard let first = readings.first, let last = readings.last else { return nil }
        return DateInterval(start: first.timestamp, end: last.timestamp)
    }

    public var change: Double? {
        guard let first = readings.first, let last = readings.last, readings.count >= 2 else { return nil }
        return last.percent - first.percent
    }
}

/// A backward-looking, continuous discharge measurement. An equivalent pace is
/// explicitly distinguished from an actually observed ten-point drop.
public enum BatteryTenPointTiming: Equatable, Sendable {
    case observed(TimeInterval)
    case equivalent(TimeInterval)
    case collecting
}

public enum TimelineSelection: Equatable, Sendable {
    case sleep(DateInterval)
    case observed(SystemSample)
    case unrecorded
}

/// A compact, evidence-bounded reading of the currently visible timeline.
/// Durations include only intervals that were actually recorded; missing time is
/// never relabeled as quiet use, heavy work, or hands-on activity.
public struct TimelineWindowUsageSummary: Equatable, Sendable {
    public let observedDuration: TimeInterval
    public let heavyProcessorDuration: TimeInterval
    public let longestHeavyProcessorRun: TimeInterval
    public let manualActivityObservedDuration: TimeInterval
    public let handsOnDuration: TimeInterval
    public let longestHandsOnRun: TimeInterval

    public init(
        observedDuration: TimeInterval,
        heavyProcessorDuration: TimeInterval,
        longestHeavyProcessorRun: TimeInterval,
        manualActivityObservedDuration: TimeInterval,
        handsOnDuration: TimeInterval,
        longestHandsOnRun: TimeInterval
    ) {
        self.observedDuration = observedDuration
        self.heavyProcessorDuration = heavyProcessorDuration
        self.longestHeavyProcessorRun = longestHeavyProcessorRun
        self.manualActivityObservedDuration = manualActivityObservedDuration
        self.handsOnDuration = handsOnDuration
        self.longestHandsOnRun = longestHandsOnRun
    }

    public var handsOnShare: Double? {
        guard manualActivityObservedDuration >= CoverageEvaluator.narrativeMinimum else { return nil }
        return min(1, max(0, handsOnDuration / manualActivityObservedDuration))
    }
}

/// Immutable red-state evidence for the currently visible timeline. Each run is
/// both what the Canvas paints red and what the left rail summarizes in red.
public struct TimelineVisibleStress: Equatable, Sendable {
    public let cpuCriticalIntervals: [DateInterval]
    public let gpuCriticalIntervals: [DateInterval]
    public let memoryCriticalIntervals: [DateInterval]

    public init(
        cpuCriticalIntervals: [DateInterval],
        gpuCriticalIntervals: [DateInterval],
        memoryCriticalIntervals: [DateInterval]
    ) {
        self.cpuCriticalIntervals = cpuCriticalIntervals
        self.gpuCriticalIntervals = gpuCriticalIntervals
        self.memoryCriticalIntervals = memoryCriticalIntervals
    }

    public var cpuCriticalDuration: TimeInterval {
        cpuCriticalIntervals.reduce(0) { $0 + $1.duration }
    }

    public var gpuCriticalDuration: TimeInterval {
        gpuCriticalIntervals.reduce(0) { $0 + $1.duration }
    }

    public var memoryCriticalDuration: TimeInterval {
        memoryCriticalIntervals.reduce(0) { $0 + $1.duration }
    }
}

/// Pure rules shared by the native timeline and validation executable. They keep
/// the interface honest: absent telemetry is never relabeled as sleep or activity.
public enum TimelineSemantics {
    public static let sustainedMemoryConstraintMinimum: TimeInterval = 2 * 60
    public static let heavyProcessorThreshold = 60.0
    public static let criticalProcessorThreshold = 85.0
    public static let handsOnIntensityThreshold = 0.04

    /// Returns the chronologically newest reading. Storage and refresh work may
    /// deliver otherwise valid samples in a different array order, which must
    /// never change what the UI calls "current."
    public static func latestSample(from samples: [SystemSample]) -> SystemSample? {
        samples.max { lhs, rhs in lhs.timestamp < rhs.timestamp }
    }

    public static func sustainedMemoryConstraints(in intervals: [DateInterval]) -> [DateInterval] {
        intervals.filter { $0.duration >= sustainedMemoryConstraintMinimum }
    }

    public static func isSustainedMemoryConstraint(
        at time: Date,
        in intervals: [DateInterval]
    ) -> Bool {
        sustainedMemoryConstraints(in: intervals).contains {
            time >= $0.start && time <= $0.end
        }
    }

    public static func visibleStress(
        samples: [SystemSample],
        within window: DateInterval,
        constrainedMemoryIntervals: [DateInterval]
    ) -> TimelineVisibleStress {
        TimelineVisibleStress(
            cpuCriticalIntervals: criticalProcessorIntervals(
                in: samples,
                within: window,
                value: { $0.cpuPercent }
            ),
            gpuCriticalIntervals: criticalProcessorIntervals(
                in: samples,
                within: window,
                value: { $0.gpuPercent }
            ),
            memoryCriticalIntervals: sustainedMemoryConstraints(
                in: constrainedMemoryIntervals
            )
        )
    }

    public static func windowUsageSummary(
        from samples: [SystemSample],
        within window: DateInterval
    ) -> TimelineWindowUsageSummary {
        var observed: [DateInterval] = []
        var heavyProcessor: [DateInterval] = []
        var manualActivityObserved: [DateInterval] = []
        var handsOn: [DateInterval] = []

        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let interval = observedInterval(for: sample, within: window) else { continue }
            observed.append(interval)

            let processorDemand = max(sample.cpuPercent, sample.gpuPercent ?? 0)
            if processorDemand.isFinite, processorDemand >= heavyProcessorThreshold {
                heavyProcessor.append(interval)
            }

            if let activity = sample.manualActivity {
                manualActivityObserved.append(interval)
                if activity.intensity(over: sample.duration) >= handsOnIntensityThreshold {
                    handsOn.append(interval)
                }
            }
        }

        let observedRuns = mergeMeasuredIntervals(observed)
        let heavyRuns = mergeMeasuredIntervals(heavyProcessor)
        let manualRuns = mergeMeasuredIntervals(manualActivityObserved)
        let handsOnRuns = mergeMeasuredIntervals(handsOn)
        return TimelineWindowUsageSummary(
            observedDuration: observedRuns.reduce(0) { $0 + $1.duration },
            heavyProcessorDuration: heavyRuns.reduce(0) { $0 + $1.duration },
            longestHeavyProcessorRun: heavyRuns.map(\.duration).max() ?? 0,
            manualActivityObservedDuration: manualRuns.reduce(0) { $0 + $1.duration },
            handsOnDuration: handsOnRuns.reduce(0) { $0 + $1.duration },
            longestHandsOnRun: handsOnRuns.map(\.duration).max() ?? 0
        )
    }

    public static func batteryTenPointTiming(for run: BatteryTimelineRun) -> BatteryTenPointTiming {
        let readings = run.readings
        guard readings.count >= 3,
              let first = readings.first,
              let last = readings.last else { return .collecting }

        let target = last.percent + 10
        if target <= 100,
           let crossingIndex = (0..<(readings.count - 1)).last(where: { index in
               let upper = readings[index]
               let lower = readings[index + 1]
               return upper.percent >= target
                   && lower.percent <= target
                   && upper.percent > lower.percent
           }) {
            let upper = readings[crossingIndex]
            let lower = readings[crossingIndex + 1]
            let suffix = readings[crossingIndex...]
            let denominator = upper.percent - lower.percent
            let fraction = (upper.percent - target) / denominator
            let crossing = upper.timestamp.addingTimeInterval(
                lower.timestamp.timeIntervalSince(upper.timestamp) * fraction
            )
            let elapsed = last.timestamp.timeIntervalSince(crossing)
            if suffix.count >= 3,
               elapsed >= 120,
               credibleDischarge(suffix) {
                return .observed(elapsed)
            }
        }

        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        let drop = first.percent - last.percent
        guard duration >= 20 * 60,
              drop >= 3,
              drop < 10,
              credibleDischarge(readings[...]) else { return .collecting }
        return .equivalent(duration * 10 / drop)
    }

    public static func sleepIntervals(
        from events: [ActivityEvent],
        within window: DateInterval,
        extendOpenSleepThroughWindowEnd: Bool = false
    ) -> [DateInterval] {
        var result: [DateInterval] = []
        var sleepingSince: Date?

        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch event.type {
            case .sleep:
                if sleepingSince == nil { sleepingSince = event.timestamp }
            case .wake:
                guard let start = sleepingSince else { continue }
                appendIntersection(start: start, end: event.timestamp, window: window, to: &result)
                sleepingSince = nil
            default:
                continue
            }
        }

        if extendOpenSleepThroughWindowEnd, let start = sleepingSince {
            appendIntersection(start: start, end: window.end, window: window, to: &result)
        }
        return result
    }

    public static func batteryRuns(
        from samples: [SystemSample],
        within window: DateInterval,
        sleepIntervals: [DateInterval],
        pointLimit: Int = 480
    ) -> [BatteryTimelineRun] {
        var rawRuns: [[BatteryTimelineReading]] = []
        var current: [BatteryTimelineReading] = []
        var previousValidSample: SystemSample?

        func finishCurrent() {
            guard !current.isEmpty else { return }
            rawRuns.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard sample.timestamp >= window.start, sample.timestamp <= window.end else { continue }
            guard isValidBatterySample(sample) else {
                finishCurrent()
                previousValidSample = nil
                continue
            }

            if let previous = previousValidSample {
                let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let expected = max(previous.samplingInterval, sample.samplingInterval)
                let maximumContinuousGap = max(2, expected * 2.2)
                let crossesSleep = sleepIntervals.contains {
                    $0.start < sample.timestamp && $0.end > previous.timestamp
                }
                if gap <= 0 || gap > maximumContinuousGap || crossesSleep || sample.duration <= 0 {
                    finishCurrent()
                }
            } else if sample.duration <= 0 {
                finishCurrent()
            }

            current.append(BatteryTimelineReading(
                id: sample.id,
                timestamp: sample.timestamp,
                percent: sample.batteryPercent ?? 0
            ))
            previousValidSample = sample
        }
        finishCurrent()

        let total = rawRuns.reduce(0) { $0 + $1.count }
        guard total > pointLimit, pointLimit > 0 else {
            return rawRuns.map(BatteryTimelineRun.init)
        }

        return rawRuns.map { readings in
            let share = max(4, Int((Double(readings.count) / Double(total) * Double(pointLimit)).rounded(.up)))
            return BatteryTimelineRun(readings: preserveExtremes(readings, limit: share))
        }
    }

    public static func selection(
        at time: Date,
        samples: [SystemSample],
        sleepIntervals: [DateInterval],
        within window: DateInterval,
        samplesAreChronological: Bool = false
    ) -> TimelineSelection {
        guard time >= window.start, time <= window.end else { return .unrecorded }
        if let sleep = sleepIntervals.first(where: { time >= $0.start && time < $0.end }) {
            return .sleep(sleep)
        }

        let ordered = samplesAreChronological ? samples : samples.sorted(by: { $0.timestamp < $1.timestamp })
        guard !ordered.isEmpty else { return .unrecorded }
        var low = 0
        var high = ordered.count
        while low < high {
            let middle = (low + high) / 2
            if ordered[middle].timestamp < time {
                low = middle + 1
            } else {
                high = middle
            }
        }

        let candidates = [low - 1, low, low + 1]
            .filter { ordered.indices.contains($0) }
            .map { ordered[$0] }
        if let sample = candidates.first(where: { observedInterval(for: $0, within: window)?.containsClosed(time) == true }) {
            return .observed(sample)
        }
        return .unrecorded
    }

    public static func observedInterval(for sample: SystemSample, within window: DateInterval) -> DateInterval? {
        guard sample.duration > 0 else { return nil }
        let boundedDuration = CoverageEvaluator.boundedDuration(of: sample)
        let start = max(window.start, sample.timestamp.addingTimeInterval(-boundedDuration))
        let end = min(window.end, sample.timestamp)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func isValidBatterySample(_ sample: SystemSample) -> Bool {
        guard sample.powerSource == .battery,
              sample.isCharging != true,
              let value = sample.batteryPercent,
              value.isFinite,
              (0...100).contains(value) else { return false }
        return true
    }

    private static func mergeMeasuredIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            guard let previous = result.last else {
                result.append(interval)
                continue
            }
            if interval.start.timeIntervalSince(previous.end) <= 1.5 {
                result[result.count - 1] = DateInterval(
                    start: previous.start,
                    end: max(previous.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func criticalProcessorIntervals(
        in samples: [SystemSample],
        within window: DateInterval,
        value: (SystemSample) -> Double?
    ) -> [DateInterval] {
        var intervals: [DateInterval] = []
        for sample in samples {
            guard let readingValue = value(sample),
                  readingValue.isFinite,
                  readingValue >= criticalProcessorThreshold,
                  let interval = observedInterval(for: sample, within: window) else { continue }
            intervals.append(interval)
        }

        return exactIntervalUnion(intervals)
    }

    /// Forms a true set union of measured time. Unlike the continuity-oriented
    /// merge used by narrative summaries, this must never bridge even a small
    /// unrecorded seam because its duration is shown as exact red evidence.
    private static func exactIntervalUnion(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals
            .filter({ $0.duration > 0 })
            .sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }) {
            guard let previous = result.last else {
                result.append(interval)
                continue
            }
            if interval.start <= previous.end {
                result[result.count - 1] = DateInterval(
                    start: previous.start,
                    end: max(previous.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func credibleDischarge(_ readings: ArraySlice<BatteryTimelineReading>) -> Bool {
        guard var lowest = readings.first?.percent else { return false }
        for reading in readings.dropFirst() {
            if reading.percent > lowest + 1 { return false }
            lowest = min(lowest, reading.percent)
        }
        return true
    }

    private static func appendIntersection(
        start: Date,
        end: Date,
        window: DateInterval,
        to result: inout [DateInterval]
    ) {
        let clippedStart = max(start, window.start)
        let clippedEnd = min(end, window.end)
        guard clippedEnd > clippedStart else { return }
        result.append(DateInterval(start: clippedStart, end: clippedEnd))
    }

    private static func preserveExtremes(
        _ readings: [BatteryTimelineReading],
        limit: Int
    ) -> [BatteryTimelineReading] {
        guard readings.count > limit, limit >= 4 else { return readings }
        let interior = Array(readings.dropFirst().dropLast())
        let bucketCount = max(1, limit / 2 - 1)
        let bucketSize = max(1, Int(ceil(Double(interior.count) / Double(bucketCount))))
        var selected: [BatteryTimelineReading] = [readings[0]]

        var index = 0
        while index < interior.count {
            let end = min(interior.count, index + bucketSize)
            let bucket = Array(interior[index..<end])
            if let minimum = bucket.min(by: { $0.percent < $1.percent }),
               let maximum = bucket.max(by: { $0.percent < $1.percent }) {
                if minimum.timestamp <= maximum.timestamp {
                    selected.append(minimum)
                    if maximum.id != minimum.id { selected.append(maximum) }
                } else {
                    selected.append(maximum)
                    if maximum.id != minimum.id { selected.append(minimum) }
                }
            }
            index = end
        }
        selected.append(readings[readings.count - 1])
        return selected.sorted(by: { $0.timestamp < $1.timestamp })
    }
}

private extension DateInterval {
    func containsClosed(_ date: Date) -> Bool {
        date >= start && date <= end
    }
}
