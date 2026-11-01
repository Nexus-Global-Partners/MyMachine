import Foundation

/// A conditional forecast from a recent measured discharge, never an OS runtime
/// promise. Its range describes sensitivity to observed pace and battery-level
/// granularity; it is not a statistical confidence interval.
public struct BatteryDischargeEstimate: Equatable, Sendable {
    public let reachesTenPercentAt: Date
    public let minutesRemaining: Double
    public let percentagePointsPerHour: Double
    public let observedDuration: TimeInterval
    public let observedDrop: Double
    public let observedCoverageFraction: Double
    public let earliestTenPercentAt: Date
    public let latestTenPercentAt: Date
    public let lastSampleAt: Date

    public var explanation: String {
        "Estimated time to 10% if the recent discharge pace continues: "
            + String(format: "%.1f percentage points/hour over %.0f minutes (%.1f-point drop). ",
                     percentagePointsPerHour, observedDuration / 60, observedDrop)
            + "Changing workload or power settings can move this time. The estimate is sensitive to recent pace and battery-level rounding; it is not a guaranteed runtime."
    }

    public static func estimate(samples: [SystemSample], now: Date = Date()) -> Self? {
        guard now.timeIntervalSince1970.isFinite,
              samples.allSatisfy({ $0.timestamp.timeIntervalSince1970.isFinite }) else { return nil }
        // Repeated records must not improve coverage. Conflicting observations
        // at one timestamp break continuity instead of arbitrarily winning.
        let observations = Dictionary(grouping: samples, by: \.timestamp)
            .sorted { $0.key < $1.key }
            .map { timestamp, readings -> Observation in
                let first = readings[0]
                let agrees = readings.allSatisfy {
                    $0.batteryPercent == first.batteryPercent && $0.powerSource == first.powerSource
                        && $0.isCharging == first.isCharging && $0.duration == first.duration
                        && $0.samplingInterval == first.samplingInterval
                }
                return Observation(timestamp: timestamp, sample: agrees ? first : nil)
            }
        guard let lastObservation = observations.last, let latest = lastObservation.sample,
              valid(latest), latest.duration > 0, latest.timestamp <= now,
              MachineStatusSignal.isFresh(latest, at: now),
              let level = latest.batteryPercent, level > 10 else { return nil }

        let cutoff = latest.timestamp.addingTimeInterval(-60 * 60)
        var descending = [latest]
        for observation in observations.dropLast().reversed() {
            guard observation.timestamp >= cutoff else { break }
            guard let earlier = observation.sample, valid(earlier), let later = descending.last,
                  let earlierLevel = earlier.batteryPercent, let laterLevel = later.batteryPercent else { break }
            let elapsed = later.timestamp.timeIntervalSince(earlier.timestamp)
            let maximumGap = min(180, max(2, max(earlier.samplingInterval, later.samplingInterval) * 2.2))
            let drop = earlierLevel - laterLevel
            // A rise, long gap, or sudden multi-point jump can be a power-state
            // change/recalibration. Start a new history after that boundary.
            guard elapsed > 0, elapsed <= maximumGap,
                  !(earlier.duration == 0 && later.duration == 0),
                  drop >= 0, drop <= max(2, elapsed / 60 * 2) else { break }
            descending.append(earlier)
        }
        let history = Array(descending.reversed())
        guard let first = history.first, let firstLevel = first.batteryPercent,
              history.count >= 20 else { return nil }
        let duration = latest.timestamp.timeIntervalSince(first.timestamp)
        let drop = firstLevel - level
        guard duration >= 20 * 60, drop >= 3 else { return nil }

        var covered: TimeInterval = 0
        for index in 1..<history.count {
            let elapsed = history[index].timestamp.timeIntervalSince(history[index - 1].timestamp)
            covered += min(elapsed, history[index].duration)
        }
        guard covered / duration >= 0.9 else { return nil }

        // Compare two long portions, not adjacent percentage readings: normal
        // integer battery levels plateau for several samples before dropping.
        let midpoint = first.timestamp.addingTimeInterval(duration / 2)
        guard let middle = history.min(by: {
            abs($0.timestamp.timeIntervalSince(midpoint)) < abs($1.timestamp.timeIntervalSince(midpoint))
        }), let middleLevel = middle.batteryPercent else { return nil }
        let firstDuration = middle.timestamp.timeIntervalSince(first.timestamp)
        let secondDuration = latest.timestamp.timeIntervalSince(middle.timestamp)
        guard firstDuration >= 9 * 60, secondDuration >= 9 * 60 else { return nil }
        let firstDrop = firstLevel - middleLevel
        let secondDrop = middleLevel - level
        guard firstDrop > 0, secondDrop > 0 else { return nil }
        let expectedFirstDrop = drop * firstDuration / duration
        guard abs(firstDrop - expectedFirstDrop) <= max(1, drop * 0.15) else { return nil }

        let rate = drop / duration
        let firstRate = firstDrop / firstDuration
        let secondRate = secondDrop / secondDuration
        // One percentage point across the measured span accounts for endpoint
        // rounding; the two half-window rates also widen this sensitivity range.
        let slowRate = min((drop - 1) / duration, min(firstRate, secondRate))
        let fastRate = max((drop + 1) / duration, max(firstRate, secondRate))
        guard rate > 0, slowRate > 0, fastRate.isFinite else { return nil }
        let target = latest.timestamp.addingTimeInterval((level - 10) / rate)
        let earliest = latest.timestamp.addingTimeInterval(max(0, level - 10 - 0.5) / fastRate)
        let latestTarget = latest.timestamp.addingTimeInterval((level - 10 + 0.5) / slowRate)
        let remaining = target.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0, remaining <= 12 * 60 * 60,
              latestTarget.timeIntervalSince(now) <= 24 * 60 * 60 else { return nil }
        return Self(reachesTenPercentAt: target, minutesRemaining: remaining / 60,
                    percentagePointsPerHour: rate * 3_600, observedDuration: duration,
                    observedDrop: drop, observedCoverageFraction: covered / duration,
                    earliestTenPercentAt: earliest, latestTenPercentAt: latestTarget,
                    lastSampleAt: latest.timestamp)
    }

    private struct Observation {
        let timestamp: Date
        let sample: SystemSample?
    }

    private static func valid(_ sample: SystemSample) -> Bool {
        guard sample.powerSource == .battery, sample.isCharging == false,
              let level = sample.batteryPercent, level.isFinite, (0...100).contains(level),
              sample.samplingInterval.isFinite, sample.samplingInterval > 0, sample.samplingInterval <= 120,
              // A historical CPU baseline still has an observed battery level
              // and source. It contributes zero interval coverage. Only isolated
              // baselines with normal adjacent gaps can preserve continuity.
              sample.duration.isFinite, sample.duration >= 0,
              sample.duration <= max(2, sample.samplingInterval * 2.2) else { return false }
        return true
    }
}
