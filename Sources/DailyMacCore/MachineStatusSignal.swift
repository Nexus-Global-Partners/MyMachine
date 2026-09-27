import Foundation

/// A compact, permission-free reading for the menu-bar icon. Effort describes
/// machine demand, never a person's attention or productivity.
public enum MachineSignalLevel: Int, CaseIterable, Equatable, Sendable {
    case low = 1
    case moderate
    case high
    case nearCapacity

    public var label: String {
        switch self {
        case .low: "Light"
        case .moderate: "Moderate"
        case .high: "High"
        case .nearCapacity: "Near capacity"
        }
    }
}

public enum MachineHealthSignal: Equatable, Sendable {
    case comfortable
    case watch
    case pressured
    case critical

    public var label: String {
        switch self {
        case .comfortable: "Comfortable"
        case .watch: "Watch"
        case .pressured: "Under pressure"
        case .critical: "Needs attention"
        }
    }
}

public struct MachineStatusSignal: Equatable, Sendable {
    public let effort: MachineSignalLevel
    public let health: MachineHealthSignal
    public let cpuPercent: Int
    public let gpuPercent: Int?

    public static func current(
        sample: SystemSample?,
        recentSamples: [SystemSample] = [],
        at now: Date = Date()
    ) -> Self? {
        guard let sample, sample.duration > 0,
              sample.cpuPercent.isFinite,
              sample.cpuPercent >= 0,
              isFresh(sample, at: now) else {
            return nil
        }

        let cpu = min(100, sample.cpuPercent)
        let gpu = sample.gpuPercent.flatMap { value -> Double? in
            value.isFinite && value >= 0 ? min(100, value) : nil
        }
        let demand = max(cpu, gpu ?? 0)
        let effort: MachineSignalLevel
        switch demand {
        case ..<25: effort = .low
        case ..<50: effort = .moderate
        case ..<75: effort = .high
        default: effort = .nearCapacity
        }

        let health: MachineHealthSignal
        if sample.thermalLevel == .serious || sample.thermalLevel == .critical
            || (sample.memoryPressure == .high
                && sustainedHighMemory(endingAt: sample, recentSamples: recentSamples)) {
            health = .critical
        } else if sample.memoryPressure == .high {
            health = .pressured
        } else if sample.memoryPressure == .elevated || sample.thermalLevel == .fair {
            health = .watch
        } else {
            health = .comfortable
        }

        return Self(
            effort: effort,
            health: health,
            cpuPercent: Int(cpu.rounded()),
            gpuPercent: gpu.map { Int($0.rounded()) }
        )
    }

    /// A reading stops being live after roughly two missed sampling intervals.
    /// Adaptive sampling may run as slowly as one minute, so the bound follows
    /// the interval actually attached to the sample rather than a fixed age.
    public static func isFresh(_ sample: SystemSample, at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(sample.timestamp)
        let maximumAge = max(40, min(150, sample.samplingInterval * 2.25 + 10))
        return age >= -30 && age <= maximumAge
    }

    private static func sustainedHighMemory(
        endingAt latest: SystemSample,
        recentSamples: [SystemSample]
    ) -> Bool {
        let window = DateInterval(start: latest.timestamp.addingTimeInterval(-240), end: latest.timestamp)
        let readings = (recentSamples + [latest])
            .filter { $0.memoryPressure == .high && $0.duration > 0 }
            .compactMap { TimelineSemantics.observedInterval(for: $0, within: window) }
            .sorted { $0.end > $1.end }
        var start = latest.timestamp
        for reading in readings {
            // A missing sample must break the claim of sustained pressure.
            guard reading.end >= start.addingTimeInterval(-5) else { break }
            start = min(start, reading.start)
            if latest.timestamp.timeIntervalSince(start) >= TimelineSemantics.sustainedMemoryConstraintMinimum {
                return true
            }
        }
        return false
    }
}

/// Measured, duration-weighted demand in the latest two-minute window. Missing
/// time never counts as zero, and an unavailable GPU stays unavailable.
public struct MachineDemandAverage: Equatable, Sendable {
    public let cpuPercent: Int
    public let gpuPercent: Int?

    public static func current(
        sample: SystemSample?,
        recentSamples: [SystemSample],
        at now: Date = Date()
    ) -> Self? {
        guard MachineStatusSignal.current(sample: sample, at: now) != nil,
              let sample else { return nil }
        let window = DateInterval(start: now.addingTimeInterval(-120), end: now)
        let readings = (recentSamples + [sample]).reduce(into: [UUID: SystemSample]()) { result, reading in
            result[reading.id] = reading
        }.values.sorted { $0.timestamp > $1.timestamp }
        var earliestCovered = window.end
        var cpuTotal = 0.0
        var cpuDuration = 0.0
        var gpuTotal = 0.0
        var gpuDuration = 0.0
        for reading in readings {
            guard reading.cpuPercent.isFinite, reading.cpuPercent >= 0,
                  let interval = TimelineSemantics.observedInterval(for: reading, within: window) else { continue }
            // Newer readings own overlapping time; gaps contribute nothing.
            let duration = max(0, min(interval.end, earliestCovered).timeIntervalSince(interval.start))
            guard duration > 0 else { continue }
            earliestCovered = min(earliestCovered, interval.start)
            cpuTotal += min(100, reading.cpuPercent) * duration
            cpuDuration += duration
            if let value = reading.gpuPercent, value.isFinite, value >= 0 {
                gpuTotal += min(100, value) * duration
                gpuDuration += duration
            }
        }
        guard cpuDuration > 0 else { return nil }
        return Self(
            cpuPercent: Int((cpuTotal / cpuDuration).rounded()),
            gpuPercent: gpuDuration > 0 ? Int((gpuTotal / gpuDuration).rounded()) : nil
        )
    }
}
