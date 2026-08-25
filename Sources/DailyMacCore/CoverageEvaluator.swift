import Foundation

public enum CoverageEvaluator {
    public static let narrativeMinimum: TimeInterval = 120

    public static func boundedDuration(of sample: SystemSample) -> TimeInterval {
        guard sample.duration > 0 else { return 0 }
        return min(sample.duration, max(2, sample.samplingInterval * 2.2))
    }

    /// System samples describe the interval ending at `timestamp`. This returns only the
    /// portion of that measured interval which overlaps a rolling monitoring window.
    public static func effectiveDuration(of sample: SystemSample, within interval: DateInterval) -> TimeInterval {
        let duration = boundedDuration(of: sample)
        guard duration > 0 else { return 0 }
        let sampleStart = sample.timestamp.addingTimeInterval(-duration)
        let overlapStart = max(sampleStart, interval.start)
        let overlapEnd = min(sample.timestamp, interval.end)
        return max(0, overlapEnd.timeIntervalSince(overlapStart))
    }

    public static func longestContinuousDuration(in samples: [SystemSample]) -> TimeInterval {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        var longest: TimeInterval = 0
        var current: TimeInterval = 0
        var previous: SystemSample?

        for sample in ordered {
            guard sample.duration > 0 else {
                current = 0
                previous = nil
                continue
            }

            if let previous {
                let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let expected = max(sample.samplingInterval, previous.samplingInterval)
                if gap < 0 || gap > max(2, expected * 2.2) {
                    current = 0
                }
            }

            let bounded = boundedDuration(of: sample)
            current += max(0, bounded)
            longest = max(longest, current)
            previous = sample
        }

        return longest
    }

    public static func longestContinuousDuration(in samples: [SystemSample], within interval: DateInterval) -> TimeInterval {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        var longest: TimeInterval = 0
        var current: TimeInterval = 0
        var previous: SystemSample?

        for sample in ordered {
            guard sample.timestamp > interval.start, sample.timestamp <= interval.end else { continue }
            let duration = effectiveDuration(of: sample, within: interval)
            guard duration > 0 else {
                current = 0
                previous = nil
                continue
            }

            if let previous {
                let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let expected = max(sample.samplingInterval, previous.samplingInterval)
                if gap < 0 || gap > max(2, expected * 2.2) {
                    current = 0
                }
            }

            current += duration
            longest = max(longest, current)
            previous = sample
        }

        return longest
    }

    public static func supportsNarrative(_ samples: [SystemSample]) -> Bool {
        longestContinuousDuration(in: samples) >= narrativeMinimum
    }

    public static func supportsNarrative(_ samples: [SystemSample], within interval: DateInterval) -> Bool {
        longestContinuousDuration(in: samples, within: interval) >= narrativeMinimum
    }
}
