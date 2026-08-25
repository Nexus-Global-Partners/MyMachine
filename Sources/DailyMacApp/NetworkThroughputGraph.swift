import DailyMacCore
import SwiftUI

/// A single, honest line for actual whole-Mac network transfer over time.
/// The line is received + sent bytes per second. The label keeps the latest
/// download and upload quantities separate so the combined line stays simple.
struct NetworkThroughputGraph: View, Equatable {
    enum Presentation: Equatable {
        case expanded
        case dashboard
    }

    let samples: [SystemSample]
    let interval: DateInterval
    let presentation: Presentation

    private let runs: [[NetworkThroughputPoint]]
    private let summary: NetworkThroughputSummary
    private let scaleMaximum: Double

    init(
        samples: [SystemSample],
        interval: DateInterval,
        presentation: Presentation = .dashboard
    ) {
        self.samples = samples
        self.interval = interval
        self.presentation = presentation

        let prepared = Self.prepare(samples: samples, within: interval)
        runs = prepared.runs
        summary = prepared.summary
        scaleMaximum = Self.niceScaleMaximum(for: prepared.summary.peakCombinedBytesPerSecond)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.samples == rhs.samples
            && lhs.interval == rhs.interval
            && lhs.presentation == rhs.presentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .dashboard ? 12 : 10) {
            header

            NetworkThroughputCanvas(
                runs: runs,
                interval: interval,
                scaleMaximum: scaleMaximum,
                presentation: presentation
            )
            .equatable()
            .frame(minHeight: presentation == .dashboard ? 150 : 120)

            if presentation == .expanded {
                timeAxis
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Network transfer")
                    .font(presentation == .dashboard ? .title3.weight(.semibold) : .headline)
                    .foregroundStyle(primaryText)

                Text(summary.meaning)
                    .font(presentation == .dashboard ? .subheadline : .caption)
                    .foregroundStyle(secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 18)

            HStack(spacing: presentation == .dashboard ? 20 : 14) {
                rateLabel(symbol: "arrow.down", value: summary.currentReceivedBytesPerSecond)
                rateLabel(symbol: "arrow.up", value: summary.currentSentBytesPerSecond)
                Text("Total (rateString(summary.currentCombinedBytesPerSecond))")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(primaryText)
                    .monospacedDigit()
            }
        }
    }

    private func rateLabel(symbol: String, value: Double) -> some View {
        Label(rateString(value), systemImage: symbol)
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .foregroundStyle(secondaryText)
            .monospacedDigit()
    }

    private var timeAxis: some View {
        HStack {
            Text(interval.start.formatted(date: .omitted, time: .shortened))
            Spacer()
            Text(interval.end.formatted(date: .omitted, time: .shortened))
        }
        .font(.caption2)
        .foregroundStyle(secondaryText)
    }

    private var primaryText: Color {
        presentation == .dashboard ? Color.white.opacity(0.94) : .primary
    }

    private var secondaryText: Color {
        presentation == .dashboard ? Color.white.opacity(0.58) : .secondary
    }

    private var accessibilitySummary: String {
        "Network transfer over the selected window. Current download (rateString(summary.currentReceivedBytesPerSecond)); current upload (rateString(summary.currentSentBytesPerSecond)). (summary.meaning) The graph uses measured whole-Mac bytes, not connection capacity."
    }

    private func rateString(_ bytesPerSecond: Double) -> String {
        Self.rateString(bytesPerSecond)
    }

    static func rateString(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_000_000_000 {
            return String(format: "%.1f GB/s", value / 1_000_000_000)
        }
        if value >= 10_000_000 {
            return String(format: "%.0f MB/s", value / 1_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1f MB/s", value / 1_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.0f KB/s", value / 1_000)
        }
        if value >= 1_000 {
            return String(format: "%.1f KB/s", value / 1_000)
        }
        return "\(Int(value.rounded())) B/s"
    }

    private static func prepare(
        samples: [SystemSample],
        within interval: DateInterval
    ) -> (runs: [[NetworkThroughputPoint]], summary: NetworkThroughputSummary) {
        let ordered = samples
            .filter { interval.contains($0.timestamp) && $0.duration > 0 }
            .sorted { $0.timestamp < $1.timestamp }

        var rawRuns: [[NetworkThroughputPoint]] = []
        var current: [NetworkThroughputPoint] = []
        var previous: SystemSample?

        func finishCurrent() {
            guard !current.isEmpty else { return }
            rawRuns.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for sample in ordered {
            if let previous {
                let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let expected = max(previous.samplingInterval, sample.samplingInterval)
                if gap <= 0 || gap > max(120, expected * 2.2) {
                    finishCurrent()
                }
            }

            let seconds = max(1, CoverageEvaluator.boundedDuration(of: sample))
            let received = Double(sample.networkReceivedBytes) / seconds
            let sent = Double(sample.networkSentBytes) / seconds
            current.append(NetworkThroughputPoint(
                timestamp: sample.timestamp,
                receivedBytesPerSecond: received,
                sentBytesPerSecond: sent
            ))
            previous = sample
        }
        finishCurrent()

        let runs = rawRuns.map { downsample($0, limit: 360) }
        let points = runs.flatMap { $0 }
        let recent = Array(points.suffix(3))
        let currentReceived = recent.isEmpty
            ? 0
            : recent.reduce(0) { $0 + $1.receivedBytesPerSecond } / Double(recent.count)
        let currentSent = recent.isEmpty
            ? 0
            : recent.reduce(0) { $0 + $1.sentBytesPerSecond } / Double(recent.count)
        let peak = points.map(\.combinedBytesPerSecond).max() ?? 0
        let totalReceived = ordered.reduce(UInt64(0)) { $0 &+ $1.networkReceivedBytes }
        let totalSent = ordered.reduce(UInt64(0)) { $0 &+ $1.networkSentBytes }
        let observedDuration = ordered.reduce(0.0) {
            $0 + CoverageEvaluator.boundedDuration(of: $1)
        }

        return (
            runs,
            NetworkThroughputSummary(
                currentReceivedBytesPerSecond: currentReceived,
                currentSentBytesPerSecond: currentSent,
                peakCombinedBytesPerSecond: peak,
                totalReceivedBytes: totalReceived,
                totalSentBytes: totalSent,
                observedDuration: observedDuration
            )
        )
    }

    private static func downsample(
        _ points: [NetworkThroughputPoint],
        limit: Int
    ) -> [NetworkThroughputPoint] {
        guard points.count > limit, limit >= 4 else { return points }
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

    private static func niceScaleMaximum(for peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return 100_000 }
        let magnitude = pow(10, floor(log10(peak)))
        let normalized = peak / magnitude
        let nice: Double
        switch normalized {
        case ...1: nice = 1
        case ...2: nice = 2
        case ...5: nice = 5
        default: nice = 10
        }
        return max(100_000, nice * magnitude)
    }
}

private struct NetworkThroughputPoint: Equatable {
    let timestamp: Date
    let receivedBytesPerSecond: Double
    let sentBytesPerSecond: Double

    var combinedBytesPerSecond: Double {
        receivedBytesPerSecond + sentBytesPerSecond
    }
}

private struct NetworkThroughputSummary: Equatable {
    let currentReceivedBytesPerSecond: Double
    let currentSentBytesPerSecond: Double
    let peakCombinedBytesPerSecond: Double
    let totalReceivedBytes: UInt64
    let totalSentBytes: UInt64
    let observedDuration: TimeInterval

    var currentCombinedBytesPerSecond: Double {
        currentReceivedBytesPerSecond + currentSentBytesPerSecond
    }

    var meaning: String {
        guard observedDuration >= CoverageEvaluator.narrativeMinimum else {
            return "Collecting enough history to judge transfer activity."
        }
        let total = totalReceivedBytes &+ totalSentBytes
        let average = Double(total) / max(1, observedDuration)
        if peakCombinedBytesPerSecond >= 10_000_000 || average >= 2_000_000 {
            return "Large transfers stood out. They can add battery use and compete with calls or sync, but destinations are never inspected."
        }
        if peakCombinedBytesPerSecond >= 1_000_000 || average >= 200_000 {
            return "Transfer activity was steady and normal for sync, browsing, or remote agent work."
        }
        return "Network activity was light and should not have affected battery life or other online work."
    }
}

private struct NetworkThroughputCanvas: View, Equatable {
    let runs: [[NetworkThroughputPoint]]
    let interval: DateInterval
    let scaleMaximum: Double
    let presentation: NetworkThroughputGraph.Presentation

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.runs == rhs.runs
            && lhs.interval == rhs.interval
            && lhs.scaleMaximum == rhs.scaleMaximum
            && lhs.presentation == rhs.presentation
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            let axisWidth: CGFloat = presentation == .dashboard ? 86 : 74
            let plot = CGRect(x: 0, y: 0, width: max(1, size.width - axisWidth), height: size.height)
            let gridColor = presentation == .dashboard
                ? Color.white.opacity(0.10)
                : Color.secondary.opacity(0.16)
            let lineColor = presentation == .dashboard
                ? Color.white.opacity(0.92)
                : Color.primary.opacity(0.78)

            for fraction in [0.0, 0.5, 1.0] {
                let y = plot.maxY - plot.height * CGFloat(fraction)
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(grid, with: .color(gridColor), lineWidth: 1)

                let value = scaleMaximum * fraction
                context.draw(
                    Text(NetworkThroughputGraph.rateString(value))
                        .font(.system(size: presentation == .dashboard ? 12 : 10, weight: .medium, design: .rounded))
                        .foregroundStyle(presentation == .dashboard ? Color.white.opacity(0.48) : Color.secondary),
                    at: CGPoint(x: plot.maxX + axisWidth / 2, y: y),
                    anchor: .center
                )
            }

            for run in runs where run.count >= 2 {
                var line = Path()
                var fill = Path()
                for (index, point) in run.enumerated() {
                    let x = xPosition(point.timestamp, in: plot)
                    let y = yPosition(point.combinedBytesPerSecond, in: plot)
                    if index == 0 {
                        line.move(to: CGPoint(x: x, y: y))
                        fill.move(to: CGPoint(x: x, y: plot.maxY))
                        fill.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        line.addLine(to: CGPoint(x: x, y: y))
                        fill.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                if let last = run.last {
                    fill.addLine(to: CGPoint(x: xPosition(last.timestamp, in: plot), y: plot.maxY))
                    fill.closeSubpath()
                }
                context.fill(
                    fill,
                    with: .linearGradient(
                        Gradient(colors: [lineColor.opacity(0.18), lineColor.opacity(0.015)]),
                        startPoint: CGPoint(x: plot.midX, y: plot.minY),
                        endPoint: CGPoint(x: plot.midX, y: plot.maxY)
                    )
                )
                context.stroke(line, with: .color(lineColor), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func xPosition(_ timestamp: Date, in rect: CGRect) -> CGFloat {
        let fraction = timestamp.timeIntervalSince(interval.start) / max(1, interval.duration)
        return rect.minX + rect.width * CGFloat(min(1, max(0, fraction)))
    }

    private func yPosition(_ value: Double, in rect: CGRect) -> CGFloat {
        let fraction = value / max(1, scaleMaximum)
        return rect.maxY - rect.height * CGFloat(min(1, max(0, fraction)))
    }
}
