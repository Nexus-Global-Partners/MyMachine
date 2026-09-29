import DailyMacCore
import SwiftUI

/// One shared coordinate system for traces, grid, labels, and inspection.
/// A run ends at every recording/sensor gap. The canvas never bridges it.
struct InstrumentHistoryView: View {
    let content: MonitoringDisplayState
    let selected: Set<MachineInstrument>
    let mode: TimelineDisplayMode
    @State private var inspectionX: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    private let series: [MachineInstrument: [InstrumentPoint]]
    private let presence: TimelinePresenceContext

    init(content: MonitoringDisplayState, selected: Set<MachineInstrument>, mode: TimelineDisplayMode) {
        self.content = content
        self.selected = selected
        self.mode = mode
        series = Dictionary(uniqueKeysWithValues: MachineInstrument.allCases.filter { selected.contains($0) }.map {
            ($0, InstrumentHistory.points($0, samples: content.samples, in: content.snapshot.interval,
                                          range: content.snapshot.range, mode: mode))
        })
        presence = TimelineSemantics.presenceContext(from: content.samples, within: content.snapshot.interval)
    }

    private var interval: DateInterval { content.snapshot.interval }
    private var ticks: [Date] { (0...4).map { interval.start.addingTimeInterval(interval.duration * Double($0) / 4) } }
    private var shown: [MachineInstrument] { MachineInstrument.allCases.filter { selected.contains($0) } }

    var body: some View {
        VStack(spacing: 9) {
            GeometryReader { geometry in
                let plot = CGRect(x: 16, y: 23, width: max(1, geometry.size.width - 57), height: max(1, geometry.size.height - 65))
                Canvas { context, _ in
                    drawGrid(context: &context, rect: plot)
                    for metric in shown {
                        let runs = Dictionary(grouping: series[metric] ?? [], by: \.run)
                        for key in runs.keys.sorted() {
                            let points = (runs[key] ?? []).map {
                                CGPoint(x: x($0.date, plot), y: plot.maxY - $0.value / 100 * plot.height)
                            }
                            guard let first = points.first else { continue }
                            let path = trace(points)
                            var glow = context
                            glow.addFilter(.blur(radius: 1.1))
                            glow.stroke(path, with: .color(metric.tint.opacity(colorScheme == .dark ? 0.22 : 0.12)),
                                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                            context.stroke(path, with: .color(metric.tint),
                                           style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                            if points.count == 1 {
                                context.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)),
                                             with: .color(metric.tint))
                            }
                        }
                    }
                    // Quiet presence rail: observed awake time, then hands-on time.
                    // Unknown coverage stays empty, including overnight gaps.
                    for run in presence.awakeIntervals {
                        rail(run, rect: plot, y: plot.maxY + 10, color: .secondary.opacity(0.14), context: &context)
                    }
                    for run in presence.handsOnIntervals {
                        rail(run, rect: plot, y: plot.maxY + 10, color: MachinePalette.human.opacity(0.7), context: &context)
                    }
                    if let inspectionX {
                        let position = min(plot.maxX, max(plot.minX, inspectionX))
                        var line = Path()
                        line.move(to: CGPoint(x: position, y: plot.minY))
                        line.addLine(to: CGPoint(x: position, y: plot.maxY))
                        context.stroke(line, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    }
                }
                .accessibilityLabel("Machine history. \(shown.map(\.title).joined(separator: ", ")). \(interval.start.formatted()) to \(interval.end.formatted()). Blank sections mean no recorded readings.")
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): inspectionX = point.x
                    case .ended: inspectionX = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { inspectionX = $0.location.x })
                .onTapGesture(count: 2) { inspectionX = nil }
                if let inspectionX {
                    inspection(at: date(min(plot.maxX, max(plot.minX, inspectionX)), plot))
                        .padding(.horizontal, 16).padding(.top, 5)
                        .allowsHitTesting(false)
                }
                if shown.allSatisfy({ series[$0]?.isEmpty != false }) {
                    VStack(spacing: 6) {
                        Text("No readings for this signal").font(.system(size: 13, weight: .medium))
                        Text(selected == [.fan] ? "Fan history starts with this update." : "Choose another signal or time range.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: plot.width, height: plot.height).offset(x: plot.minX, y: plot.minY)
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.018 : 0.02), in: RoundedRectangle(cornerRadius: 19, style: .continuous))

        }
        .help("Click the instrument cards to choose the graph's signals. Blank sections mean no recorded reading. The thin bottom rail marks recorded awake time; darker sections indicate recent physical input, not focus.")
        .onChange(of: content.snapshot.interval) { _, _ in inspectionX = nil }
        .onChange(of: selected) { _, _ in inspectionX = nil }
    }

    private func inspection(at date: Date) -> some View {
        HStack(spacing: 9) {
            Text(date.formatted(date: interval.duration > 86400 ? .abbreviated : .omitted, time: .shortened))
                .foregroundStyle(.secondary)
            ForEach(shown) { metric in
                let points = series[metric] ?? []
                let runs = Dictionary(grouping: points, by: \.run).values
                let containing = runs.first { points in
                    guard let first = points.first, let last = points.last else { return false }
                    return date >= first.date && date <= last.date
                }
                let nearest = containing?.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                Text("\(metric.title) \(nearest.map { "\(Int($0.value.rounded()))%" } ?? "—")")
                    .foregroundStyle(metric.tint)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1)
    }

    private func drawGrid(context: inout GraphicsContext, rect: CGRect) {
        for value in [0, 50, 100] {
            let y = rect.maxY - CGFloat(value) / 100 * rect.height
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: y))
            line.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(line, with: .color(.primary.opacity(0.055)), lineWidth: 0.5)
            context.draw(Text("\(value)%").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: rect.maxX + 8, y: y), anchor: .leading)
        }
        for (index, tick) in ticks.enumerated() {
            let position = x(tick, rect)
            var line = Path()
            line.move(to: CGPoint(x: position, y: rect.minY))
            line.addLine(to: CGPoint(x: position, y: rect.maxY))
            context.stroke(line, with: .color(.primary.opacity(0.055)), lineWidth: 0.5)
            let isNow = index == 4 && abs(interval.end.timeIntervalSinceNow) < 150
            let label = isNow ? "Now" : tick.formatted(.dateTime
                .hour().minute())
            context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: position, y: rect.maxY + 28),
                         anchor: index == 0 ? .leading : index == 4 ? .trailing : .center)
            if interval.duration >= 23 * 3600 {
                context.draw(Text(tick.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 8)).foregroundStyle(.tertiary),
                             at: CGPoint(x: position, y: rect.maxY + 39),
                             anchor: index == 0 ? .leading : index == 4 ? .trailing : .center)
            }
        }
    }

    private func rail(_ interval: DateInterval, rect: CGRect, y: CGFloat, color: Color, context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: x(interval.start, rect), y: y))
        path.addLine(to: CGPoint(x: x(interval.end, rect), y: y))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func x(_ date: Date, _ rect: CGRect) -> CGFloat {
        rect.minX + max(0, min(1, date.timeIntervalSince(interval.start) / max(1, interval.duration))) * rect.width
    }
    private func date(_ x: CGFloat, _ rect: CGRect) -> Date {
        interval.start.addingTimeInterval(Double((x - rect.minX) / rect.width) * interval.duration)
    }
    private func trace(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            if mode == .calm {
                let midpoint = (previous.x + point.x) / 2
                path.addCurve(to: point, control1: CGPoint(x: midpoint, y: previous.y),
                              control2: CGPoint(x: midpoint, y: point.y))
            } else { path.addLine(to: point) }
        }
        return path
    }
}
