import Foundation

/// The selectable instruments use measured percentages, not inferred health.
/// Thermal pressure remains categorical and is deliberately not on this axis.
public enum MachineInstrument: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, fan
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .fan: "Fan"
        }
    }

    public func value(in sample: SystemSample) -> Double? {
        let value: Double?
        switch self {
        case .cpu: value = sample.cpuPercent
        case .gpu: value = sample.gpuPercent
        case .memory:
            value = sample.memoryTotalBytes > 0
                ? Double(sample.memoryUsedBytes) / Double(sample.memoryTotalBytes) * 100 : nil
        case .fan:
            value = sample.fanRPM.flatMap { rpm in
                sample.fanMaximumRPM.flatMap { FanReading(index: 0, rpm: rpm, maximumRPM: $0)?.percentOfMaximum }
            }
        }
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

public struct InstrumentPoint: Equatable, Sendable {
    public let date: Date
    public let value: Double
    public let run: Int
}

public enum InstrumentHistory {
    /// Duration-weighted means over actual coverage. No zero fill, no duplicate
    /// interval weighting, and no interpolation across unknown sensor readings.
    public static func average(_ metric: MachineInstrument, samples: [SystemSample], in window: DateInterval) -> Double? {
        var total = 0.0, duration = 0.0
        var end = window.start
        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let value = metric.value(in: sample),
                  let interval = TimelineSemantics.observedInterval(for: sample, within: window) else { continue }
            let start = max(end, interval.start)
            guard interval.end > start else { continue }
            let weight = interval.end.timeIntervalSince(start)
            total += value * weight
            duration += weight
            end = interval.end
        }
        return duration > 0 ? total / duration : nil
    }

    public static func points(_ metric: MachineInstrument, samples: [SystemSample], in window: DateInterval,
                              range: MonitoringRange, mode: TimelineDisplayMode,
                              displayedDuration: TimeInterval? = nil) -> [InstrumentPoint] {
        guard window.duration > 0, window.duration.isFinite else { return [] }
        // A missing GPU must not split a continuous CPU run. Each signal has
        // its own coverage and uses the same duration-weighted curve builder.
        let normalBucket = TimelineSemantics.processorTrendBucketDuration(for: range, displayMode: mode, windowDuration: window.duration)
        let visible = displayedDuration ?? window.duration
        let bucket = mode == .calm && visible.isFinite && visible > 0
            ? min(normalBucket, max(120, visible / 48)) : normalBucket
        var result: [InstrumentPoint] = []
        var runBounds: [Int: DateInterval] = [:]
        var run = 0
        var previousEnd: Date?
        var bucketIndex: Int?
        var weight = 0.0, sum = 0.0
        var start = window.start, end = window.start
        func flush() {
            guard weight > 0 else { return }
            // One value at the bucket's temporal center, not two adjacent
            // plateaus sharing a timestamp (which force vertical stair steps).
            result.append(InstrumentPoint(date: start.addingTimeInterval(end.timeIntervalSince(start) / 2),
                                          value: sum / weight, run: run))
            runBounds[run] = DateInterval(start: runBounds[run]?.start ?? start, end: end)
            weight = 0; sum = 0
        }
        for sample in samples.filter({ $0.timestamp.timeIntervalSinceReferenceDate.isFinite }).sorted(by: { $0.timestamp < $1.timestamp }) {
            guard sample.duration.isFinite, sample.samplingInterval.isFinite,
                  let value = metric.value(in: sample),
                  let measured = TimelineSemantics.observedInterval(for: sample, within: window) else {
                if sample.timestamp >= window.start && sample.timestamp <= window.end {
                    flush(); run += 1; previousEnd = nil; bucketIndex = nil
                }
                continue
            }
            if let previousEnd, measured.start.timeIntervalSince(previousEnd) > 1.5 {
                flush(); run += 1; bucketIndex = nil
            }
            var cursor = max(measured.start, previousEnd ?? measured.start)
            while cursor < measured.end {
                let index = Int(floor(cursor.timeIntervalSince(window.start) / bucket))
                if bucketIndex != index { flush(); bucketIndex = index; start = cursor }
                let next = min(measured.end, window.start.addingTimeInterval(Double(index + 1) * bucket))
                guard next > cursor else { break }
                let duration = next.timeIntervalSince(cursor)
                sum += value * duration; weight += duration; end = next; cursor = next
            }
            previousEnd = max(previousEnd ?? measured.end, measured.end)
        }
        flush()
        let runs = Dictionary(grouping: result, by: \.run)
        return runs.keys.sorted().flatMap { key -> [InstrumentPoint] in
            guard let points = runs[key], let first = points.first, let last = points.last,
                  let bounds = runBounds[key] else { return [] }
            // Retain true observed endpoints and never extend into a gap.
            return [InstrumentPoint(date: bounds.start, value: first.value, run: key)]
                + points + [InstrumentPoint(date: bounds.end, value: last.value, run: key)]
        }
    }
}

/// Calm may shorten long sleep / unrecorded spans, never recorded background
/// work. All dates, inspection and grid marks share this invertible time map.
public struct InstrumentTimeScale: Sendable {
    public struct Segment: Sendable {
        public let interval: DateInterval
        public let displayedDuration: TimeInterval
        public let condensed: InstrumentTimeRegion?
    }
    public let window: DateInterval
    public let segments: [Segment]
    public var displayedDuration: TimeInterval { segments.reduce(0) { $0 + $1.displayedDuration } }
    public var condensedRegions: [InstrumentTimeRegion] { segments.compactMap(\.condensed) }

    public init(window: DateInterval, regions: [InstrumentTimeRegion], mode: TimelineDisplayMode) {
        self.window = window
        let candidates = regions.filter {
            $0.kind != .away && $0.interval.duration >= max(1800, window.duration * 0.04)
                && $0.interval.start >= window.start && $0.interval.end <= window.end
        }.sorted { $0.interval.duration > $1.interval.duration }.prefix(4)
            .sorted { $0.interval.start < $1.interval.start }
        // Reject overlapping input rather than double-removing elapsed time.
        let disjoint = zip(candidates, candidates.dropFirst()).allSatisfy { $0.interval.end <= $1.interval.start }
        let remaining = window.duration - candidates.reduce(0) { $0 + $1.interval.duration }
        guard mode == .calm, !candidates.isEmpty, disjoint, remaining >= 60 else {
            segments = [Segment(interval: window, displayedDuration: window.duration, condensed: nil)]
            return
        }
        // Each break receives at most 6.5% of chart width. Active time keeps
        // one common scale on both sides, with enough room to read the break.
        let cap = remaining * 0.065 / (1 - Double(candidates.count) * 0.065)
        var parts: [Segment] = []
        var cursor = window.start
        for region in candidates where region.interval.duration > cap {
            if cursor < region.interval.start {
                let span = DateInterval(start: cursor, end: region.interval.start)
                parts.append(Segment(interval: span, displayedDuration: span.duration, condensed: nil))
            }
            parts.append(Segment(interval: region.interval, displayedDuration: cap, condensed: region))
            cursor = region.interval.end
        }
        if cursor < window.end {
            let span = DateInterval(start: cursor, end: window.end)
            parts.append(Segment(interval: span, displayedDuration: span.duration, condensed: nil))
        }
        segments = parts
    }

    public func fraction(at date: Date) -> Double {
        guard displayedDuration > 0 else { return 0 }
        var offset = 0.0
        for part in segments {
            if date <= part.interval.end {
                let position = max(0, min(1, date.timeIntervalSince(part.interval.start) / max(0.001, part.interval.duration)))
                return (offset + position * part.displayedDuration) / displayedDuration
            }
            offset += part.displayedDuration
        }
        return 1
    }

    public func date(at fraction: Double) -> Date {
        var offset = max(0, min(1, fraction)) * displayedDuration
        for part in segments {
            if offset <= part.displayedDuration {
                return part.interval.start.addingTimeInterval(part.interval.duration * offset / max(0.001, part.displayedDuration))
            }
            offset -= part.displayedDuration
        }
        return window.end
    }
}
