import DailyMacCore
import SwiftUI

/// One shared coordinate system for traces, grid, labels, and inspection.
/// A run ends at every recording/sensor gap. The canvas never bridges it.
struct InstrumentHistoryView: View {
    let content: MonitoringDisplayState
    let selected: Set<MachineInstrument>
    let mode: TimelineDisplayMode
    @State private var inspectionX: CGFloat?
    @AppStorage(SolarPreferences.key) private var solarLocation = ""
    @State private var solarBands: [SolarBand] = []
    @Environment(\.colorScheme) private var colorScheme

    private let series: [MachineInstrument: [InstrumentPoint]]
    private let presence: TimelinePresenceContext
    private let timeRegions: [InstrumentTimeRegion]
    private let timeScale: InstrumentTimeScale

    init(content: MonitoringDisplayState, selected: Set<MachineInstrument>, mode: TimelineDisplayMode) {
        self.content = content
        self.selected = selected
        self.mode = mode
        let presence = TimelineSemantics.presenceContext(from: content.samples, within: content.snapshot.interval)
        let regions = InstrumentTimeContext.regions(
            presence: presence,
            sleeps: TimelineSemantics.sleepIntervals(from: content.events, within: content.snapshot.interval),
            in: content.snapshot.interval)
        let scale = InstrumentTimeScale(window: content.snapshot.interval, regions: regions, mode: mode)
        self.presence = presence
        timeRegions = regions
        timeScale = scale
        series = Dictionary(uniqueKeysWithValues: MachineInstrument.allCases.filter { selected.contains($0) }.map {
            ($0, InstrumentHistory.points($0, samples: content.samples, in: content.snapshot.interval,
                                          range: content.snapshot.range, mode: mode,
                                          displayedDuration: scale.displayedDuration))
        })
    }

    private var interval: DateInterval { content.snapshot.interval }
    private var shown: [MachineInstrument] { MachineInstrument.allCases.filter { selected.contains($0) } }
    // Supporting signals sit behind demand, including at crossings.
    private var paintOrder: [MachineInstrument] { [.fan, .memory, .cpu, .gpu].filter { selected.contains($0) } }
    private var hasDemandSignal: Bool { selected.contains(.cpu) || selected.contains(.gpu) }

    private func strokeOpacity(_ metric: MachineInstrument) -> Double {
        switch metric {
        case .cpu, .gpu: 1
        case .memory: hasDemandSignal ? 0.55 : 0.9
        case .fan: hasDemandSignal ? 0.32 : 0.75
        }
    }

    private func strokeWidth(_ metric: MachineInstrument) -> CGFloat {
        switch metric {
        case .cpu, .gpu: 2.6
        case .memory: hasDemandSignal ? 1.8 : 2.2
        case .fan: hasDemandSignal ? 1.5 : 2
        }
    }

    private func fillOpacity(_ metric: MachineInstrument) -> Double {
        let opacity = metric == .memory ? 0.045 : 0.025
        return opacity * (hasDemandSignal ? 1 : 2) * (colorScheme == .dark ? 1 : 0.7)
    }

    var body: some View {
        VStack(spacing: 9) {
            GeometryReader { geometry in
                let axisSpace: CGFloat = interval.duration >= 23 * 3600 ? 82 : 65
                let plot = CGRect(x: 16, y: 23, width: max(1, geometry.size.width - 57), height: max(1, geometry.size.height - axisSpace))
                Canvas { context, _ in
                    drawDaylight(context: &context, rect: plot)
                    drawGrid(context: &context, rect: plot)
                    drawTimeRegions(context: &context, rect: plot)
                    // Fill each measured run independently, below all strokes.
                    // Quiet depth for the physical signals, never across gaps.
                    for metric in paintOrder where metric == .fan || metric == .memory {
                        for run in Dictionary(grouping: series[metric] ?? [], by: \.run).values {
                            let points = run.map { CGPoint(x: x($0.date, plot), y: plot.maxY - $0.value / 100 * plot.height) }
                            guard points.count > 1, let first = points.first, let last = points.last else { continue }
                            var area = trace(points)
                            area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                            area.addLine(to: CGPoint(x: first.x, y: plot.maxY))
                            area.closeSubpath()
                            context.fill(area, with: .linearGradient(
                                Gradient(colors: [metric.tint.opacity(fillOpacity(metric)), metric.tint.opacity(0.002)]),
                                startPoint: CGPoint(x: plot.midX, y: plot.minY),
                                endPoint: CGPoint(x: plot.midX, y: plot.maxY)))
                        }
                    }
                    for metric in paintOrder {
                        let runs = Dictionary(grouping: series[metric] ?? [], by: \.run)
                        for key in runs.keys.sorted() {
                            let run = runs[key] ?? []
                            let points = run.map {
                                CGPoint(x: x($0.date, plot), y: plot.maxY - $0.value / 100 * plot.height)
                            }
                            guard let first = points.first else { continue }
                            let path = trace(points)
                            if metric == .cpu || metric == .gpu {
                                var glow = context
                                glow.addFilter(.blur(radius: 1.1))
                                glow.stroke(path, with: .color(metric.tint.opacity(colorScheme == .dark ? 0.22 : 0.12)),
                                            style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                            }
                            context.stroke(path, with: traceShading(metric, points: points, run: run),
                                           style: StrokeStyle(lineWidth: strokeWidth(metric), lineCap: .round, lineJoin: .round))
                            if points.count == 1 {
                                context.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)),
                                             with: .color(metric.tint.opacity(strokeOpacity(metric))))
                            }
                        }
                    }
                    drawCondensedBreaks(context: &context, rect: plot)
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
                } else if !timeScale.condensedRegions.isEmpty {
                    Text("Pauses condensed · //")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
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
            .background(InstrumentGlassSurface(radius: 19))

        }
        .help("Click cards to choose signals. Calm shortens long sleep and unrecorded gaps, marked // with their actual duration. Precise keeps full elapsed-time spacing. Blank sections are never interpolated. The bottom rail marks recorded awake time and recent physical input, not focus.")
        .onChange(of: content.snapshot.interval) { _, _ in inspectionX = nil }
        .onChange(of: selected) { _, _ in inspectionX = nil }
        .task(id: "\(solarLocation)|\(interval.start.timeIntervalSince1970)|\(interval.end.timeIntervalSince1970)") {
            solarBands = []
            guard let location = SolarPreferences.decode(solarLocation) else { return }
            let window = interval
            let bands = await Task.detached(priority: .utility) {
                SolarContext.bands(in: window, location: location)
            }.value
            guard !Task.isCancelled else { return }
            solarBands = bands
        }
    }

    private func drawDaylight(context: inout GraphicsContext, rect: CGRect) {
        var lastLabelX = -CGFloat.infinity
        for (index, band) in solarBands.enumerated() {
            let left = x(band.interval.start, rect)
            let right = x(band.interval.end, rect)
            let tint: Color = switch band.phase {
            case .day: Color.orange.opacity(colorScheme == .dark ? 0.022 : 0.018)
            case .twilight: Color.indigo.opacity(colorScheme == .dark ? 0.09 : 0.045)
            case .night: Color.indigo.opacity(colorScheme == .dark ? 0.16 : 0.085)
            }
            context.fill(Path(CGRect(x: left, y: rect.minY, width: max(0, right - left), height: rect.height)),
                         with: .color(tint))
            guard index > 0 else { continue }
            var boundary = Path()
            boundary.move(to: CGPoint(x: left, y: rect.minY))
            boundary.addLine(to: CGPoint(x: left, y: rect.maxY))
            context.stroke(boundary, with: .color(.secondary.opacity(0.16)),
                           style: StrokeStyle(lineWidth: 0.6, dash: [2, 4]))
            // Actual sunrise/sunset guides use the same (possibly condensed)
            // coordinate map as the telemetry. Suppress labels, never time, when crowded.
            let previous = solarBands[index - 1].phase
            let title = band.phase == .day ? "Sunrise" : previous == .day ? "Sunset" : nil
            guard let title, inspectionX == nil, left - lastLabelX >= 100,
                  left > rect.minX + 48, left < rect.maxX - 48 else { continue }
            context.draw(Text("\(title) \(band.interval.start.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary),
                         at: CGPoint(x: left, y: rect.minY + 8), anchor: .top)
            lastLabelX = left
        }
    }

    private func inspection(at date: Date) -> some View {
        HStack(spacing: 9) {
            Text(date.formatted(date: interval.duration > 86400 ? .abbreviated : .omitted, time: .shortened))
                .foregroundStyle(.secondary)
            if let band = solarBands.first(where: { $0.interval.contains(date) }) {
                Text(band.phase.rawValue).foregroundStyle(.secondary)
            }
            if let region = timeRegions.first(where: { date >= $0.interval.start && date < $0.interval.end }) {
                Text(regionTitle(region)).foregroundStyle(.secondary)
            }
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
        let ticks = displayTicks(width: rect.width)
        for (index, tick) in ticks.enumerated() {
            let position = x(tick, rect)
            var line = Path()
            line.move(to: CGPoint(x: position, y: rect.minY))
            line.addLine(to: CGPoint(x: position, y: rect.maxY))
            context.stroke(line, with: .color(.primary.opacity(0.09)), lineWidth: 0.65)
            var marker = Path()
            marker.move(to: CGPoint(x: position, y: rect.maxY + 15))
            marker.addLine(to: CGPoint(x: position, y: rect.maxY + 19))
            context.stroke(marker, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
            let isLast = index == ticks.count - 1
            let isNow = isLast && abs(interval.end.timeIntervalSinceNow) < 150
            let label = isNow ? "Now" : tick.formatted(.dateTime
                .hour().minute())
            context.draw(Text(label).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(.primary.opacity(0.72)),
                         at: CGPoint(x: position, y: rect.maxY + 29),
                         anchor: index == 0 ? .leading : isLast ? .trailing : .center)
            if interval.duration >= 23 * 3600 {
                context.draw(Text(tick.formatted(.dateTime.weekday(.abbreviated).day()))
                    .font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: position, y: rect.maxY + 43),
                             anchor: index == 0 ? .leading : isLast ? .trailing : .center)
            }
        }
    }

    private func regionTitle(_ region: InstrumentTimeRegion) -> String {
        let minutes = max(1, Int(region.interval.duration / 60))
        let duration = minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" : "\(minutes)m"
        let title: String = switch region.kind {
        case .away: "Away"
        case .sleep: "Asleep"
        case .missing: "No readings"
        }
        return "\(title) · \(duration)"
    }

    private func drawTimeRegions(context: inout GraphicsContext, rect: CGRect) {
        // Only the three largest readable spans receive persistent labels.
        // Every smaller span remains available through inspection.
        let candidates = timeRegions.filter { region in
            guard !timeScale.condensedRegions.contains(region) else { return false }
            let width = x(region.interval.end, rect) - x(region.interval.start, rect)
            let text = context.resolve(Text(regionTitle(region)).font(.system(size: 10, weight: .medium)))
            return region.interval.duration >= 60 && width >= text.measure(in: CGSize(width: 400, height: 20)).width + 18
        }.sorted { $0.interval.duration > $1.interval.duration }.prefix(3)
        for region in candidates {
            let left = x(region.interval.start, rect), right = x(region.interval.end, rect)
            if region.kind != .away {
                context.fill(Path(CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)),
                             with: .color(.primary.opacity(0.018)))
            }
            context.draw(Text(regionTitle(region)).font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary),
                         at: CGPoint(x: (left + right) / 2, y: rect.maxY - 16))
        }
    }

    private func rail(_ interval: DateInterval, rect: CGRect, y: CGFloat, color: Color, context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: x(interval.start, rect), y: y))
        path.addLine(to: CGPoint(x: x(interval.end, rect), y: y))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func x(_ date: Date, _ rect: CGRect) -> CGFloat {
        rect.minX + timeScale.fraction(at: date) * rect.width
    }
    private func date(_ x: CGFloat, _ rect: CGRect) -> Date {
        timeScale.date(at: Double((x - rect.minX) / rect.width))
    }

    private func displayTicks(width: CGFloat) -> [Date] {
        guard !timeScale.condensedRegions.isEmpty else {
            return InstrumentTimeContext.ticks(in: interval, width: width)
        }
        // Generate clock-aligned candidates at the expanded activity density,
        // then perform spacing in display coordinates, not elapsed time.
        let candidates = InstrumentTimeContext.ticks(in: interval,
            width: width * interval.duration / max(1, timeScale.displayedDuration) * 2)
            .filter { date in
                !timeScale.condensedRegions.contains { date > $0.interval.start && date < $0.interval.end }
            }
        var ticks = [interval.start]
        for tick in candidates {
            let position = timeScale.fraction(at: tick) * width
            let last = timeScale.fraction(at: ticks.last!) * width
            if position - last >= 75 && width - position >= 75 { ticks.append(tick) }
        }
        ticks.append(interval.end)
        return ticks
    }

    private func traceShading(_ metric: MachineInstrument, points: [CGPoint], run: [InstrumentPoint]) -> GraphicsContext.Shading {
        let color = metric.tint.opacity(strokeOpacity(metric))
        guard let first = points.first, let last = points.last, last.x - first.x > 16 else { return .color(color) }
        let fade = min(0.18, 8 / (last.x - first.x))
        let startsAfterBoundary = (run.first?.date ?? interval.start).timeIntervalSince(interval.start) > 1.5
        let endsBeforeLive = interval.end.timeIntervalSince(run.last?.date ?? interval.end) > 120
        return .linearGradient(Gradient(stops: [
            .init(color: color.opacity(startsAfterBoundary ? 0.25 : 1), location: 0),
            .init(color: color, location: fade), .init(color: color, location: 1 - fade),
            .init(color: color.opacity(endsBeforeLive ? 0.25 : 1), location: 1)
        ]), startPoint: first, endPoint: CGPoint(x: last.x, y: first.y))
    }

    private func drawCondensedBreaks(context: inout GraphicsContext, rect: CGRect) {
        for region in timeScale.condensedRegions {
            let left = x(region.interval.start, rect), right = x(region.interval.end, rect)
            let band = CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)
            let glass = Path(roundedRect: band, cornerRadius: min(9, band.width / 3))
            context.fill(glass, with: .linearGradient(Gradient(colors: [
                .white.opacity(0.01), .white.opacity(colorScheme == .dark ? 0.055 : 0.35), .white.opacity(0.01)
            ]), startPoint: CGPoint(x: left, y: rect.midY), endPoint: CGPoint(x: right, y: rect.midY)))
            let center = (left + right) / 2
            context.draw(Text("//").font(.system(size: 13, weight: .light)).foregroundStyle(.secondary.opacity(0.65)),
                         at: CGPoint(x: center, y: rect.midY))
            let minutes = max(1, Int(region.interval.duration / 60))
            let duration = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
            context.draw(Text(region.kind == .sleep ? "Asleep" : "No data")
                .font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary),
                         at: CGPoint(x: center, y: rect.maxY - 29))
            context.draw(Text(duration).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary),
                         at: CGPoint(x: center, y: rect.maxY - 16))
        }
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
