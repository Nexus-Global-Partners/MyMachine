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

        let prepared = NetworkThroughputSemantics.prepare(samples: samples, within: interval)
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
            .frame(minHeight: presentation == .dashboard ? 150 : 105)

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
                Text(currentTotalLabel)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(primaryText)
                    .monospacedDigit()
            }
        }
    }

    private func rateLabel(symbol: String, value: Double?) -> some View {
        Label(value.map(rateString) ?? "—", systemImage: symbol)
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .foregroundStyle(secondaryText)
            .monospacedDigit()
    }

    private var currentTotalLabel: String {
        summary.currentCombinedBytesPerSecond.map { "Total \(rateString($0))" }
            ?? "No current reading"
    }

    private var timeAxis: some View {
        HStack {
            Text(relativeWindowStartLabel)
            Spacer()
            Text("Now")
        }
        .font(.caption2)
        .foregroundStyle(secondaryText)
    }

    private var relativeWindowStartLabel: String {
        let roundedMinutes = max(1, Int((interval.duration / 60).rounded()))
        if roundedMinutes >= 60, roundedMinutes.isMultiple(of: 60) {
            return "−\(roundedMinutes / 60)h"
        }
        return "−\(roundedMinutes)m"
    }

    private var primaryText: Color {
        presentation == .dashboard ? Color.white.opacity(0.94) : .primary
    }

    private var secondaryText: Color {
        presentation == .dashboard ? Color.white.opacity(0.58) : .secondary
    }

    private var accessibilitySummary: String {
        let current: String
        if let received = summary.currentReceivedBytesPerSecond,
           let sent = summary.currentSentBytesPerSecond {
            current = "Current download \(rateString(received)); current upload \(rateString(sent))."
        } else {
            current = "No fresh network reading is available now."
        }
        return "Network transfer over the selected window. \(current) \(summary.meaning) The graph uses measured whole-Mac bytes, not connection capacity. VPN or virtual interfaces can overlap; destinations and content are never inspected."
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

private extension NetworkThroughputSummary {
    var meaning: String {
        guard observedDuration >= CoverageEvaluator.narrativeMinimum else {
            return "Collecting enough history to judge transfer activity."
        }
        let (combined, overflow) = totalReceivedBytes.addingReportingOverflow(totalSentBytes)
        let total = overflow ? UInt64.max : combined
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
                let labelInset: CGFloat = presentation == .dashboard ? 9 : 7
                let labelY = min(plot.maxY - labelInset, max(plot.minY + labelInset, y))
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(grid, with: .color(gridColor), lineWidth: 1)

                let value = scaleMaximum * fraction
                context.draw(
                    Text(NetworkThroughputGraph.rateString(value))
                        .font(.system(size: presentation == .dashboard ? 12 : 10, weight: .medium, design: .rounded))
                        .foregroundStyle(presentation == .dashboard ? Color.white.opacity(0.48) : Color.secondary),
                    at: CGPoint(x: plot.maxX + axisWidth / 2, y: labelY),
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
