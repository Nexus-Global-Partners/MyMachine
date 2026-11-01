import Foundation

/// Independent of the history viewport: these windows always end at now.
public enum MachineReadingMode: String, CaseIterable, Identifiable, Sendable {
    case live, average5Minutes, average30Minutes, average1Hour, average4Hours
    public static let storageKey = "machineReadingMode"
    public var id: String { rawValue }
    public var duration: TimeInterval? {
        switch self {
        case .live: nil
        case .average5Minutes: 300
        case .average30Minutes: 1800
        case .average1Hour: 3600
        case .average4Hours: 14400
        }
    }
    public var shortLabel: String {
        switch self {
        case .live: "Live"
        case .average5Minutes: "5m"
        case .average30Minutes: "30m"
        case .average1Hour: "1h"
        case .average4Hours: "4h"
        }
    }
    public var label: String { self == .live ? "Live" : "Average · \(shortLabel)" }
}

/// Shared numerical contract for cards and icon. Battery remains a current
/// level; thermal and health always describe the latest fresh measurement.
public struct MachineReadingSnapshot: Equatable, Sendable {
    public let mode: MachineReadingMode
    public let interval: DateInterval
    public let values: [MachineInstrument: Double]
    public let signal: MachineStatusSignal?
    public let demand: MachineDemandAverage?

    public init(mode: MachineReadingMode, latest: SystemSample?, samples: [SystemSample],
                liveFanPercent: Double? = nil, at now: Date = Date()) {
        self.mode = mode
        interval = DateInterval(start: now.addingTimeInterval(-(mode.duration ?? max(0, latest?.duration ?? 0))), end: now)
        guard let latest, let current = MachineStatusSignal.current(sample: latest, recentSamples: samples, at: now) else {
            values = [:]; signal = nil; demand = nil
            return
        }
        var measured: [MachineInstrument: Double] = [:]
        for metric in MachineInstrument.allCases {
            if metric == .battery || mode == .live {
                measured[metric] = metric.value(in: latest)
            } else {
                measured[metric] = InstrumentHistory.average(metric, samples: samples, in: interval)
            }
        }
        if mode == .live {
            // The faster fan poll is itself a measured sensor value. Nil means
            // unavailable, rather than reusing a stale preceding fan poll.
            measured[.fan] = liveFanPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        }
        values = measured
        if let cpu = measured[.cpu] {
            let gpu = measured[.gpu]
            let effort = max(cpu, gpu ?? 0)
            signal = MachineStatusSignal(effort: effort < 25 ? .low : effort < 50 ? .moderate : effort < 75 ? .high : .nearCapacity,
                                         health: current.health, cpuPercent: Int(cpu.rounded()), gpuPercent: gpu.map { Int($0.rounded()) })
            demand = MachineDemandAverage(cpuPercent: Int(cpu.rounded()), gpuPercent: gpu.map { Int($0.rounded()) })
        } else { signal = nil; demand = nil }
    }

    /// Share of observed app CPU core-seconds, never whole-machine or GPU
    /// attribution. Newer intervals own overlapping time for each app.
    public static func appContributors(samples: [AppResourceSample], in interval: DateInterval) -> [AppComputeContribution] {
        let invalidCollections = Set(samples.filter { $0.cpuMeasurementVersion != 1 }.map(\.timestamp))
        let groups = Dictionary(grouping: samples.filter {
            !invalidCollections.contains($0.timestamp) && $0.duration.isFinite && $0.duration > 0
                && $0.cpuPercent.isFinite && $0.cpuPercent >= 0
        }, by: { $0.ownerBundleID ?? $0.ownerName })
        var rows: [(AppResourceSample, Double, Double)] = []
        for group in groups.values {
            var boundary = interval.end, seconds = 0.0, coverage = 0.0
            let ordered = group.sorted { $0.timestamp > $1.timestamp }
            for sample in ordered {
                let start = max(interval.start, sample.timestamp.addingTimeInterval(-sample.duration))
                let end = min(boundary, min(interval.end, sample.timestamp))
                guard end > start else { continue }
                let duration = end.timeIntervalSince(start)
                seconds += sample.cpuPercent / 100 * duration
                coverage += duration
                boundary = start
            }
            if let latest = ordered.first, seconds > 0, seconds.isFinite { rows.append((latest, seconds, coverage)) }
        }
        let total = rows.reduce(0) { $0 + $1.1 }
        guard total > 0, total.isFinite else { return [] }
        return rows.map {
            AppComputeContribution(ownerName: $0.0.ownerName, ownerBundleID: $0.0.ownerBundleID,
                                   observedCPUSharePercent: $0.1 / total * 100, cpuCoreSeconds: $0.1, observedDuration: $0.2)
        }.sorted { $0.cpuCoreSeconds > $1.cpuCoreSeconds }
    }
}
