import Foundation

/// One measured whole-machine network rate. The counters are permission-free
/// byte deltas divided by the bounded interval that produced them.
public struct NetworkThroughputPoint: Equatable, Sendable {
    public let timestamp: Date
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double

    public init(
        timestamp: Date,
        receivedBytesPerSecond: Double,
        sentBytesPerSecond: Double
    ) {
        self.timestamp = timestamp
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
    }

    public var combinedBytesPerSecond: Double {
        receivedBytesPerSecond + sentBytesPerSecond
    }
}

/// Evidence-bounded network context for a visible monitoring window. Current
/// rates are nil when the latest measured run no longer reaches the window end.
public struct NetworkThroughputSummary: Equatable, Sendable {
    public let currentReceivedBytesPerSecond: Double?
    public let currentSentBytesPerSecond: Double?
    public let peakCombinedBytesPerSecond: Double
    public let totalReceivedBytes: UInt64
    public let totalSentBytes: UInt64
    public let observedDuration: TimeInterval

    public init(
        currentReceivedBytesPerSecond: Double?,
        currentSentBytesPerSecond: Double?,
        peakCombinedBytesPerSecond: Double,
        totalReceivedBytes: UInt64,
        totalSentBytes: UInt64,
        observedDuration: TimeInterval
    ) {
        self.currentReceivedBytesPerSecond = currentReceivedBytesPerSecond
        self.currentSentBytesPerSecond = currentSentBytesPerSecond
        self.peakCombinedBytesPerSecond = peakCombinedBytesPerSecond
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
        self.observedDuration = observedDuration
    }

    public var currentCombinedBytesPerSecond: Double? {
        guard let received = currentReceivedBytesPerSecond,
              let sent = currentSentBytesPerSecond else { return nil }
        return received + sent
    }
}

public struct NetworkThroughputSeries: Equatable, Sendable {
    public let runs: [[NetworkThroughputPoint]]
    public let summary: NetworkThroughputSummary

    public init(runs: [[NetworkThroughputPoint]], summary: NetworkThroughputSummary) {
        self.runs = runs
        self.summary = summary
    }
}

/// Pure preparation rules shared by the graph and validation executable. A
/// baseline reset is a hard run boundary, and display downsampling never changes
/// the raw peak or the latest-rate calculation.
public enum NetworkThroughputSemantics {
    public static func prepare(
        samples: [SystemSample],
        within interval: DateInterval,
        pointLimit: Int = 360
    ) -> NetworkThroughputSeries {
        let ordered = samples
            .filter { $0.timestamp > interval.start && $0.timestamp <= interval.end }
            .sorted { $0.timestamp < $1.timestamp }

        var rawRuns: [[NetworkThroughputPoint]] = []
        var currentRun: [NetworkThroughputPoint] = []
        var measuredSamples: [SystemSample] = []
        var previousMeasuredSample: SystemSample?
        var latestSampleWasMeasured = false

        func finishCurrent() {
            guard !currentRun.isEmpty else { return }
            rawRuns.append(currentRun)
            currentRun.removeAll(keepingCapacity: true)
        }

        for sample in ordered {
            let seconds = CoverageEvaluator.boundedDuration(of: sample)
            guard seconds.isFinite, seconds > 0 else {
                finishCurrent()
                previousMeasuredSample = nil
                latestSampleWasMeasured = false
                continue
            }

            if let previous = previousMeasuredSample {
                let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let expected = maximumExpectedInterval(previous, sample)
                if gap <= 0 || gap > expected * 2.2 {
                    finishCurrent()
                }
            }

            currentRun.append(NetworkThroughputPoint(
                timestamp: sample.timestamp,
                receivedBytesPerSecond: Double(sample.networkReceivedBytes) / seconds,
                sentBytesPerSecond: Double(sample.networkSentBytes) / seconds
            ))
            measuredSamples.append(sample)
            previousMeasuredSample = sample
            latestSampleWasMeasured = true
        }
        finishCurrent()

        let rawPoints = rawRuns.flatMap { $0 }
        let latestMeasuredSample = latestSampleWasMeasured ? ordered.last : nil
        let latestRun = latestSampleWasMeasured ? (rawRuns.last ?? []) : []
        let currentPoints: ArraySlice<NetworkThroughputPoint>
        if let latestMeasuredSample,
           let latestPoint = latestRun.last,
           isFresh(latestPoint, sample: latestMeasuredSample, at: interval.end) {
            currentPoints = latestRun.suffix(3)
        } else {
            currentPoints = []
        }

        let currentReceived = average(currentPoints.map(\.receivedBytesPerSecond))
        let currentSent = average(currentPoints.map(\.sentBytesPerSecond))
        let peak = rawPoints.map(\.combinedBytesPerSecond).max() ?? 0
        let totalReceived = saturatedSum(measuredSamples.map(\.networkReceivedBytes))
        let totalSent = saturatedSum(measuredSamples.map(\.networkSentBytes))
        let observedDuration = measuredDuration(of: measuredSamples, within: interval)
        let runs = rawRuns.map { downsample($0, limit: pointLimit) }

        return NetworkThroughputSeries(
            runs: runs,
            summary: NetworkThroughputSummary(
                currentReceivedBytesPerSecond: currentReceived,
                currentSentBytesPerSecond: currentSent,
                peakCombinedBytesPerSecond: peak,
                totalReceivedBytes: totalReceived,
                totalSentBytes: totalSent,
                observedDuration: observedDuration
            )
        )
    }

    private static func maximumExpectedInterval(_ lhs: SystemSample, _ rhs: SystemSample) -> TimeInterval {
        let candidates = [lhs.samplingInterval, rhs.samplingInterval]
            .filter { $0.isFinite && $0 > 0 }
        return max(2, candidates.max() ?? 2)
    }

    private static func isFresh(
        _ point: NetworkThroughputPoint,
        sample: SystemSample,
        at end: Date
    ) -> Bool {
        let age = end.timeIntervalSince(point.timestamp)
        let expected = sample.samplingInterval.isFinite && sample.samplingInterval > 0
            ? sample.samplingInterval
            : max(2, sample.duration)
        return age >= 0 && age <= max(2, expected * 2.2)
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func saturatedSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }

    private static func measuredDuration(
        of samples: [SystemSample],
        within interval: DateInterval
    ) -> TimeInterval {
        var intervals: [DateInterval] = []
        for sample in samples {
            let duration = CoverageEvaluator.boundedDuration(of: sample)
            guard duration.isFinite, duration > 0 else { continue }
            let start = max(interval.start, sample.timestamp.addingTimeInterval(-duration))
            let end = min(interval.end, sample.timestamp)
            guard end > start else { continue }
            intervals.append(DateInterval(start: start, end: end))
        }

        var merged: [DateInterval] = []
        for measured in intervals.sorted(by: { $0.start < $1.start }) {
            if let previous = merged.last, measured.start <= previous.end {
                merged[merged.count - 1] = DateInterval(
                    start: previous.start,
                    end: max(previous.end, measured.end)
                )
            } else {
                merged.append(measured)
            }
        }
        return merged.reduce(0) { $0 + $1.duration }
    }

    private static func downsample(
        _ points: [NetworkThroughputPoint],
        limit: Int
    ) -> [NetworkThroughputPoint] {
        guard limit > 0 else { return [] }
        guard points.count > limit else { return points }
        let stride = Double(points.count) / Double(limit)
        return (0..<limit).compactMap { index in
            let lower = Int((Double(index) * stride).rounded(.down))
            let upper = min(points.count, Int((Double(index + 1) * stride).rounded(.down)))
            guard lower < upper else { return nil }
            let bucket = points[lower..<upper]
            let count = Double(bucket.count)
            return NetworkThroughputPoint(
                timestamp: bucket.last?.timestamp ?? points[lower].timestamp,
                receivedBytesPerSecond: bucket.reduce(0) { $0 + $1.receivedBytesPerSecond } / count,
                sentBytesPerSecond: bucket.reduce(0) { $0 + $1.sentBytesPerSecond } / count
            )
        }
    }
}
