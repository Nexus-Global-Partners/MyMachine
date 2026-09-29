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
                              range: MonitoringRange, mode: TimelineDisplayMode) -> [InstrumentPoint] {
        if metric == .cpu || metric == .gpu {
            return TimelineSemantics.processorTrend(from: samples, within: window, range: range, displayMode: mode)
                .compactMap { point in
                    let value = metric == .cpu ? point.cpuPercent : point.gpuPercent
                    return value.map { InstrumentPoint(date: point.timestamp, value: $0, run: point.segment) }
                }
        }
        let bucket = TimelineSemantics.processorTrendBucketDuration(for: range, displayMode: mode, windowDuration: window.duration)
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
        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let value = metric.value(in: sample),
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
