import Foundation

/// Small, content-free measurements retained with a daily report after detailed
/// samples expire. Optional on DailyReport so previously saved days stay readable.
public struct DailyResourceSummary: Codable, Equatable, Sendable {
    public let observedDuration: TimeInterval
    public let humanActiveDuration: TimeInterval
    public let backgroundDuration: TimeInterval
    public let physicalInputDuration: TimeInterval
    public let averageCPU: Double?
    public let peakCPU: Double?
    public let averageGPU: Double?
    public let peakGPU: Double?
    public let gpuObservedDuration: TimeInterval
    public let elevatedMemoryDuration: TimeInterval
    public let highMemoryDuration: TimeInterval
    public let seriousThermalDuration: TimeInterval
}

public struct MonitoringDaySummary: Identifiable, Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case detail
        case retained
        case unavailable
    }

    public var id: String { dayKey }
    public let dayKey: String
    /// Calendar midnight, for a stable day label even in the first partial slot.
    public let start: Date
    public let interval: DateInterval
    public let source: Source
    public let humanActiveDuration: TimeInterval
    public let backgroundDuration: TimeInterval
    public let confirmedSleepDuration: TimeInterval
    public let observedDuration: TimeInterval
    public let averageCPU: Double?
    public let peakCPU: Double?
    public let averageGPU: Double?
    public let peakGPU: Double?
    public let elevatedMemoryDuration: TimeInterval?
    public let highMemoryDuration: TimeInterval?
    public let seriousThermalDuration: TimeInterval?
    public let peakMemoryPressure: MemoryPressureLevel?
    public let thermalPeak: ThermalLevel?
    public let isPartialDay: Bool

    public var unobservedDuration: TimeInterval {
        max(0, interval.duration - observedDuration - confirmedSleepDuration)
    }
}

/// Long views compare observed days; they never manufacture within-day curves
/// from daily means or reinterpret missing history as a sleeping Mac.
public enum MonitoringHistory {
    public static func overviewInterval(
        for range: MonitoringRange,
        endingAt end: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DateInterval? {
        switch range {
        case .oneWeek:
            let today = calendar.startOfDay(for: end)
            guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return nil }
            return DateInterval(start: start, end: end)
        default:
            return nil
        }
    }

    public static func daySummaries(
        in window: DateInterval,
        samples: [SystemSample],
        reports: [DailyReport],
        events: [ActivityEvent],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MonitoringDaySummary] {
        guard window.duration > 0 else { return [] }
        let ordered = chronological(samples)
        let sleep = TimelineSemantics.sleepIntervals(from: events, within: window)
        let reportsByKey = Dictionary(grouping: reports, by: \.dayKey)
        var result: [MonitoringDaySummary] = []
        var dayStart = calendar.startOfDay(for: window.start)
        while dayStart < window.end {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart), dayEnd > dayStart else { break }
            let day = DateInterval(start: dayStart, end: dayEnd)
            let interval = DateInterval(start: max(dayStart, window.start), end: min(dayEnd, window.end))
            let key = DayBoundaries.key(for: dayStart, timezone: calendar.timeZone)
            let values = measurements(from: ordered, within: interval)
            let resource = resourceSummary(from: values)
            // A whole-day report cannot be sliced at a rolling-window boundary.
            // Nor can a report from a different local-day boundary be relabeled.
            let report = reportsByKey[key]?.filter { candidate in
                guard day.start >= window.start, day.end <= window.end,
                      let zone = TimeZone(identifier: candidate.timezoneIdentifier),
                      let savedDay = DayBoundaries.interval(for: key, timezone: zone) else { return false }
                return savedDay == day && candidate.sampleCount > 0
            }.max { $0.generatedAt < $1.generatedAt }
            let reportObserved = report.map { $0.resourceSummary?.observedDuration ?? ($0.activeDuration + $0.idleDuration) } ?? 0
            let useReport = report != nil && reportObserved > 0 &&
                (values.isEmpty || reportObserved > resource.observedDuration + 1)
            let source: MonitoringDaySummary.Source = useReport ? .retained : (values.isEmpty ? .unavailable : .detail)
            let observed = min(interval.duration, max(0, useReport ? reportObserved : resource.observedDuration))
            let rawSleepDuration = sleep.reduce(0.0) { total, span in
                let start = max(interval.start, span.start)
                let end = min(interval.end, span.end)
                guard end > start else { return total }
                let measuredOverlap = values.reduce(0.0) { sum, value in
                    sum + max(0, min(end, value.interval.end).timeIntervalSince(max(start, value.interval.start)))
                }
                return total + max(0, end.timeIntervalSince(start) - measuredOverlap)
            }
            let saved = useReport ? report?.resourceSummary : nil
            let active = useReport ? (saved?.humanActiveDuration ?? report?.activeDuration ?? 0) : resource.humanActiveDuration
            let background = useReport ? (saved?.backgroundDuration ?? report?.idleDuration ?? 0) : resource.backgroundDuration
            result.append(MonitoringDaySummary(
                dayKey: key, start: dayStart, interval: interval, source: source,
                humanActiveDuration: min(observed, max(0, active)),
                backgroundDuration: min(max(0, observed - active), max(0, background)),
                confirmedSleepDuration: min(max(0, interval.duration - observed), rawSleepDuration),
                observedDuration: observed,
                averageCPU: useReport ? (saved?.averageCPU ?? validPercent(report?.averageCPU)) : resource.averageCPU,
                peakCPU: useReport ? (saved?.peakCPU ?? validPercent(report?.peakCPU)) : resource.peakCPU,
                averageGPU: useReport ? saved?.averageGPU : resource.averageGPU,
                peakGPU: useReport ? saved?.peakGPU : resource.peakGPU,
                elevatedMemoryDuration: useReport ? saved?.elevatedMemoryDuration : (values.isEmpty ? nil : resource.elevatedMemoryDuration),
                highMemoryDuration: useReport ? saved?.highMemoryDuration : (values.isEmpty ? nil : resource.highMemoryDuration),
                seriousThermalDuration: useReport ? saved?.seriousThermalDuration : (values.isEmpty ? nil : resource.seriousThermalDuration),
                peakMemoryPressure: useReport ? report?.peakMemoryPressure : memoryPeak(values),
                thermalPeak: useReport ? report?.thermalPeak : heatPeak(values),
                isPartialDay: interval != day
            ))
            dayStart = dayEnd
        }
        return result
    }

    public static func resourceSummary(
        from samples: [SystemSample],
        within interval: DateInterval
    ) -> DailyResourceSummary {
        resourceSummary(from: measurements(from: chronological(samples), within: interval))
    }

    private struct Measurement {
        let sample: SystemSample
        let interval: DateInterval
        var duration: TimeInterval { interval.duration }
    }

    private static func chronological(_ samples: [SystemSample]) -> [SystemSample] {
        samples.sorted {
            $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp
        }
    }

    private static func measurements(from ordered: [SystemSample], within window: DateInterval) -> [Measurement] {
        var coveredThrough = window.start
        return ordered.compactMap { sample in
            let duration = CoverageEvaluator.boundedDuration(of: sample)
            guard duration.isFinite, duration > 0 else { return nil }
            let start = max(coveredThrough, sample.timestamp.addingTimeInterval(-duration))
            let end = min(window.end, sample.timestamp)
            guard end > start else { return nil }
            coveredThrough = end
            return Measurement(sample: sample, interval: DateInterval(start: start, end: end))
        }
    }

    private static func resourceSummary(from values: [Measurement]) -> DailyResourceSummary {
        func duration(where predicate: (SystemSample) -> Bool) -> TimeInterval {
            values.reduce(0) { $0 + (predicate($1.sample) ? $1.duration : 0) }
        }
        func metric(_ value: (SystemSample) -> Double?) -> (average: Double?, peak: Double?, duration: TimeInterval) {
            let measured = values.compactMap { item -> (Double, TimeInterval)? in
                guard let percent = validPercent(value(item.sample)) else { return nil }
                return (percent, item.duration)
            }
            let duration = measured.reduce(0) { $0 + $1.1 }
            guard duration > 0 else { return (nil, nil, 0) }
            return (measured.reduce(0) { $0 + $1.0 * $1.1 } / duration, measured.map(\.0).max(), duration)
        }
        let cpu = metric { $0.cpuPercent }
        let gpu = metric { $0.gpuPercent }
        return DailyResourceSummary(
            observedDuration: values.reduce(0) { $0 + $1.duration },
            humanActiveDuration: duration { !$0.isIdle },
            backgroundDuration: duration { $0.isIdle },
            physicalInputDuration: duration { sample in
                sample.manualActivity.map { $0.intensity(over: sample.duration) >= TimelineSemantics.handsOnIntensityThreshold } ?? !sample.isIdle
            },
            averageCPU: cpu.average, peakCPU: cpu.peak,
            averageGPU: gpu.average, peakGPU: gpu.peak, gpuObservedDuration: gpu.duration,
            elevatedMemoryDuration: duration { $0.memoryPressure != .low },
            highMemoryDuration: duration { $0.memoryPressure == .high },
            seriousThermalDuration: duration { $0.thermalLevel == .serious || $0.thermalLevel == .critical }
        )
    }

    private static func validPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func memoryPeak(_ values: [Measurement]) -> MemoryPressureLevel? {
        guard !values.isEmpty else { return nil }
        return values.contains { $0.sample.memoryPressure == .high } ? .high : (values.contains { $0.sample.memoryPressure == .elevated } ? .elevated : .low)
    }

    private static func heatPeak(_ values: [Measurement]) -> ThermalLevel? {
        let levels = values.map { $0.sample.thermalLevel }
        return [ThermalLevel.critical, .serious, .fair, .nominal].first { levels.contains($0) }
    }
}
