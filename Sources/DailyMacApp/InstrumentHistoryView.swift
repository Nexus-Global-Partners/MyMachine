import AppKit
import DailyMacCore
import SwiftUI

/// One shared coordinate system for traces, grid, labels, and inspection.
/// Measured runs stay separate. Quiet presentation joins distinguish battery
/// interpolation and confirmed sleep transitions from actual sensor readings.
struct InstrumentHistoryView: View {
    let content: MonitoringDisplayState
    let selected: Set<MachineInstrument>
    let mode: TimelineDisplayMode
    let navigationBounds: DateInterval?
    let batteryEstimate: BatteryDischargeEstimate?
    let onPan: (DateInterval) -> Void
    let onPanStateChange: (Bool) -> Void
    let onJumpToActivity: ((Date, Int) -> Void)?
    @State private var inspectionX: CGFloat?
    @State private var dragWindow: DateInterval?
    @State private var dragStart: DateInterval?
    @State private var scrollTranslation: CGFloat = 0
    @State private var hoveredSleep: DateInterval?
    @State private var entranceStart = Date()
    @State private var entranceFinished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SolarPreferences.key) private var solarLocation = ""
    @State private var solarBands: [SolarBand] = []
    @Environment(\.colorScheme) private var colorScheme

    private let inspectionSamples: [SystemSample]
    private let series: [MachineInstrument: [InstrumentPoint]]
    private let presence: TimelinePresenceContext
    private let timeRegions: [InstrumentTimeRegion]
    private let buffer: DateInterval
    private let chargingIntervals: [DateInterval]
    private let gapJoins: [MachineInstrument: [InstrumentHistory.GapJoin]]

    init(content: MonitoringDisplayState, selected: Set<MachineInstrument>, mode: TimelineDisplayMode,
         navigationBounds: DateInterval? = nil,
         batteryEstimate: BatteryDischargeEstimate? = nil,
         onPan: @escaping (DateInterval) -> Void = { _ in }, onPanStateChange: @escaping (Bool) -> Void = { _ in },
         onJumpToActivity: ((Date, Int) -> Void)? = nil) {
        self.navigationBounds = navigationBounds
        self.batteryEstimate = batteryEstimate
        self.content = content
        self.selected = selected
        self.mode = mode
        self.onPan = onPan
        self.onPanStateChange = onPanStateChange
        self.onJumpToActivity = onJumpToActivity
        let window = content.graphBuffer ?? content.snapshot.interval
        buffer = window
        let samples = content.graphSamples ?? content.samples
        inspectionSamples = samples
        let events = content.graphEvents ?? content.events
        let presence = TimelineSemantics.presenceContext(from: samples, within: window)
        let regions = InstrumentTimeContext.regions(
            presence: presence,
            sleeps: TimelineSemantics.sleepIntervals(from: events, within: window, awakeSamples: samples), in: window)
        self.presence = presence
        timeRegions = regions
        chargingIntervals = InstrumentHistory.chargingIntervals(samples: samples, in: window)
        let preparedSeries = Dictionary(uniqueKeysWithValues: MachineInstrument.allCases.filter { selected.contains($0) }.map {
            ($0, InstrumentHistory.points($0, samples: samples, in: window,
                                          range: content.snapshot.range, mode: mode,
                                          displayedDuration: content.snapshot.interval.duration))
        })
        series = preparedSeries
        gapJoins = Dictionary(uniqueKeysWithValues: preparedSeries.map { metric, points in
            (metric, InstrumentHistory.gapJoins(metric, points: points,
                sleeps: regions.filter { $0.kind == .sleep }.map(\.interval)))
        })
    }

    private var bounds: DateInterval { navigationBounds ?? buffer }
    private var interval: DateInterval { dragWindow ?? content.snapshot.interval }
    private var shown: [MachineInstrument] { MachineInstrument.allCases.filter { selected.contains($0) } }
    // Supporting signals sit behind demand, including at crossings.
    private var paintOrder: [MachineInstrument] { [.fan, .memory, .battery, .cpu, .gpu].filter { selected.contains($0) } }
    private var hasDemandSignal: Bool { selected.contains(.cpu) || selected.contains(.gpu) }

    private func strokeOpacity(_ metric: MachineInstrument) -> Double {
        switch metric {
        case .cpu, .gpu: 1
        case .memory: hasDemandSignal ? 0.55 : 0.9
        case .battery: hasDemandSignal ? 0.72 : 1
        case .fan: hasDemandSignal ? 0.32 : 0.75
        }
    }

    private func strokeWidth(_ metric: MachineInstrument) -> CGFloat {
        switch metric {
        case .cpu, .gpu: 2.6
        case .memory: hasDemandSignal ? 1.8 : 2.2
        case .battery: hasDemandSignal ? 2 : 2.6
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
                let crossesDay = !Calendar.autoupdatingCurrent.isDate(interval.start, inSameDayAs: interval.end)
                let axisSpace: CGFloat = crossesDay || InstrumentViewport.isDayBoundary(interval.start) ? 82 : 65
                let plot = CGRect(x: 16, y: 23, width: max(1, geometry.size.width - 57), height: max(1, geometry.size.height - axisSpace))
                ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: entranceFinished || reduceMotion)) { frame in
                Canvas { context, _ in
                    var ink = context
                    ink.clip(to: Path(plot))
                    drawDaylight(context: &ink, rect: plot)
                    drawGrid(context: &context, rect: plot)
                    drawTimeRegions(context: &ink, rect: plot)
                    var chargingInk = revealed(ink, metric: .battery, rect: plot, at: frame.date)
                    drawCharging(context: &chargingInk, rect: plot)
                    // Fill each measured run independently, below all strokes.
                    // Quiet depth for the physical signals, never across gaps.
                    for metric in paintOrder where metric == .fan || metric == .memory {
                        let fillInk = revealed(ink, metric: metric, rect: plot, at: frame.date)
                        for run in Dictionary(grouping: series[metric] ?? [], by: \.run).values {
                            let points = run.map { CGPoint(x: x($0.date, plot), y: plot.maxY - $0.value / 100 * plot.height) }
                            guard points.count > 1, let first = points.first, let last = points.last else { continue }
                            var area = trace(points)
                            area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                            area.addLine(to: CGPoint(x: first.x, y: plot.maxY))
                            area.closeSubpath()
                            fillInk.fill(area, with: .linearGradient(
                                Gradient(colors: [metric.tint.opacity(fillOpacity(metric)), metric.tint.opacity(0.002)]),
                                startPoint: CGPoint(x: plot.midX, y: plot.minY),
                                endPoint: CGPoint(x: plot.midX, y: plot.maxY)))
                        }
                    }
                    for metric in paintOrder {
                        let lineInk = revealed(ink, metric: metric, rect: plot, at: frame.date)
                        drawGapJoins(metric, context: lineInk, rect: plot)
                        let runs = Dictionary(grouping: series[metric] ?? [], by: \.run)
                        for key in runs.keys.sorted() {
                            let run = runs[key] ?? []
                            guard InstrumentHistory.shouldDrawRun(run, in: interval, plotWidth: plot.width) else { continue }
                            let points = run.map {
                                CGPoint(x: x($0.date, plot), y: plot.maxY - $0.value / 100 * plot.height)
                            }
                            guard !points.isEmpty else { continue }
                            let path = trace(points, metric: metric)
                            if metric == .cpu || metric == .gpu || metric == .battery {
                                var glow = lineInk
                                glow.addFilter(.blur(radius: 1.1))
                                glow.opacity *= colorScheme == .dark ? 0.18 : 0.09
                                glow.stroke(path, with: traceShading(metric, points: points, run: run, rect: plot),
                                            style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                            }
                            lineInk.stroke(path, with: traceShading(metric, points: points, run: run, rect: plot),
                                           style: StrokeStyle(lineWidth: strokeWidth(metric), lineCap: .round, lineJoin: .round))

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
                }
                .accessibilityLabel("Machine history. \(shown.map(\.title).joined(separator: ", ")). \(interval.start.formatted()) to \(interval.end.formatted()). Dotted links are unmeasured connections; brief processor links never cross sleep. Tiny measured runs remain available on hover. Quiet processor ramps mark confirmed sleep, not measured zero readings. Other gaps remain blank.")
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if dragStart == nil {
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            dragStart = interval
                            entranceFinished = true
                            onPanStateChange(true)
                        }
                        guard let start = dragStart else { return }
                        inspectionX = nil
                        hoveredSleep = nil
                        dragWindow = InstrumentViewport.panned(start, translation: value.translation.width,
                            width: plot.width, earliest: bounds.start, latest: min(bounds.end, Date()))
                    }
                    .onEnded { _ in finishPan() })
                .overlay {
                    InstrumentHorizontalScrollSurface { delta, finished in
                        if finished { finishPan(); scrollTranslation = 0; return }
                        if dragStart == nil {
                            dragStart = interval
                            scrollTranslation = 0
                            entranceFinished = true
                            onPanStateChange(true)
                        }
                        guard let start = dragStart else { return }
                        inspectionX = nil
                        hoveredSleep = nil
                        scrollTranslation += delta
                        dragWindow = InstrumentViewport.panned(start, translation: scrollTranslation,
                            width: plot.width, earliest: bounds.start, latest: min(bounds.end, Date()))
                    }
                }
                .onTapGesture(count: 2) { inspectionX = nil }
                if let inspectionX {
                    inspection(at: date(min(plot.maxX, max(plot.minX, inspectionX)), plot))
                        .padding(.horizontal, 16).padding(.top, 5)
                        .allowsHitTesting(false)
                }
                if let hoveredSleep {
                    gapNavigation(hoveredSleep)
                        .position(x: plot.midX, y: plot.minY + 34)
                }
                if let batteryEstimate, selected.contains(.battery), dragWindow == nil, dragStart == nil {
                    batteryForecastMarker(batteryEstimate)
                        .position(x: plot.maxX + 22, y: plot.maxY - plot.height * 0.1)
                }
                if shown.allSatisfy({ series[$0]?.isEmpty != false }) {
                    VStack(spacing: 6) {
                        Text("No readings for this signal").font(.system(size: 13, weight: .medium))
                        Text(selected == [.fan] ? "Fan history starts with this update." : "Choose another signal or time range.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: plot.width, height: plot.height).offset(x: plot.minX, y: plot.minY)
                    .allowsHitTesting(false)
                }
                }
                .onContinuousHover { phase in
                    guard dragStart == nil else { return }
                    switch phase {
                    case .active(let point):
                        inspectionX = point.x
                        if point.y > plot.minY + 54 {
                            let time = date(min(plot.maxX, max(plot.minX, point.x)), plot)
                            hoveredSleep = timeRegions.first { $0.kind != .away && $0.interval.duration >= 300 && $0.interval.contains(time) }?.interval
                        }
                    case .ended: inspectionX = nil; hoveredSleep = nil
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(InstrumentGlassSurface(radius: 19))

        }
        .help("Drag or swipe horizontally to browse; pick a date to jump days. Hover over sleep or missing readings to jump to recorded activity. Dotted links connect unmeasured gaps; processor links are limited to brief missed readings, never sleep. Quiet CPU/GPU ramps mark confirmed sleep, not measured zeros. Green fill marks recorded charging only.")
        .onChange(of: content.snapshot.interval) { _, _ in
            if dragStart == nil { dragWindow = nil; inspectionX = nil; hoveredSleep = nil; entranceFinished = true }
        }
        .onDisappear { dragStart = nil; scrollTranslation = 0; onPanStateChange(false) }
        .task {
            entranceStart = Date()
            guard !reduceMotion else { entranceFinished = true; return }
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            entranceFinished = true
        }
        .onChange(of: selected) { _, _ in inspectionX = nil; hoveredSleep = nil }
        .task(id: "\(solarLocation)|\(buffer.start.timeIntervalSince1970)|\(buffer.end.timeIntervalSince1970)") {
            solarBands = []
            guard let location = SolarPreferences.decode(solarLocation) else { return }
            let window = buffer
            let bands = await Task.detached(priority: .utility) {
                SolarContext.bands(in: window, location: location)
            }.value
            guard !Task.isCancelled else { return }
            solarBands = bands
        }
    }

    private func batteryForecastMarker(_ estimate: BatteryDischargeEstimate) -> some View {
        // An axis annotation at 10%, not a future point on the historical trace.
        let rounded = Date(timeIntervalSince1970: (estimate.reachesTenPercentAt.timeIntervalSince1970 / 300).rounded() * 300)
        return HStack(spacing: 2) {
            Circle().fill(MachinePalette.battery).frame(width: 3, height: 3)
            Text("≈" + rounded.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 8.5, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(MachinePalette.battery)
        .frame(width: 35, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help("Battery estimated to reach 10% around \(rounded.formatted(date: .abbreviated, time: .shortened)). \(estimate.explanation)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery estimated to reach 10 percent around \(rounded.formatted(date: .abbreviated, time: .shortened)). At the recent discharge rate; actual time may vary.")
    }

    private func finishPan() {
        guard dragStart != nil else { return }
        dragStart = nil
        onPanStateChange(false)
        if let dragWindow, dragWindow != content.snapshot.interval { onPan(dragWindow) }
        else { dragWindow = nil }
    }

    private func gapNavigation(_ gap: DateInterval) -> some View {
        let label = timeRegions.first(where: { $0.interval == gap })?.kind == .sleep ? "Sleep" : "No readings"
        let previous = InstrumentViewport.activityNeighbor(to: gap, direction: -1, recorded: presence.awakeIntervals)
        let next = InstrumentViewport.activityNeighbor(to: gap, direction: 1, recorded: presence.awakeIntervals)
        return HStack(spacing: 8) {
            if onJumpToActivity != nil {
                distantJumpButton("Previous activity", symbol: "arrow.left", from: gap.start, direction: -1)
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                distantJumpButton("Next activity", symbol: "arrow.right", from: gap.end, direction: 1)
            } else {
                if let previous { jumpButton("Previous activity", symbol: "arrow.left", date: previous) }
                if previous != nil || next != nil {
                    Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let next { jumpButton("Next activity", symbol: "arrow.right", date: next) }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(InstrumentGlassSurface(radius: 9))
        .fixedSize()
        .opacity(onJumpToActivity != nil || previous != nil || next != nil ? 1 : 0)
    }

    private func distantJumpButton(_ title: String, symbol: String, from date: Date, direction: Int) -> some View {
        Button {
            inspectionX = nil
            hoveredSleep = nil
            entranceFinished = true
            onJumpToActivity?(date, direction)
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.plain)
        .help("Find the nearest saved reading beyond this gap, including outside the loaded graph.")
    }

    private func jumpButton(_ title: String, symbol: String, date: Date) -> some View {
        Button {
            let destination = InstrumentViewport.focused(interval, on: date,
                earliest: bounds.start, latest: min(bounds.end, Date()))
            inspectionX = nil
            hoveredSleep = nil
            entranceFinished = true
            dragWindow = destination
            onPan(destination)
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.plain)
        .help("Jump to the nearest recorded activity at the same scale. Sleep keeps its elapsed duration.")
    }

    private func revealed(_ context: GraphicsContext, metric: MachineInstrument, rect: CGRect, at date: Date) -> GraphicsContext {
        guard !entranceFinished, !reduceMotion else { return context }
        let progress = InstrumentEntrance.progress(metric, elapsed: date.timeIntervalSince(entranceStart))
        var layer = context
        layer.clip(to: Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * progress, height: rect.height)))
        return layer
    }

    private func drawCharging(context: inout GraphicsContext, rect: CGRect) {
        guard selected.contains(.battery), !chargingIntervals.isEmpty else { return }
        for run in Dictionary(grouping: series[.battery] ?? [], by: \.run).values {
            let points = run.map { CGPoint(x: x($0.date, rect), y: rect.maxY - $0.value / 100 * rect.height) }
            guard points.count > 1, let first = points.first, let last = points.last else { continue }
            var area = trace(points, metric: .battery)
            area.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            area.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            area.closeSubpath()
            for charging in chargingIntervals {
                let left = max(first.x, x(charging.start, rect))
                let right = min(last.x, x(charging.end, rect))
                guard right > left else { continue }
                var layer = context
                layer.clip(to: Path(CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)))
                layer.fill(area, with: .linearGradient(
                    Gradient(colors: [MachinePalette.battery.opacity(colorScheme == .dark ? 0.20 : 0.14),
                                      MachinePalette.battery.opacity(0.015)]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            }
        }
    }

    private func drawGapJoins(_ metric: MachineInstrument, context: GraphicsContext, rect: CGRect) {
        for join in gapJoins[metric] ?? [] {
            let a = CGPoint(x: x(join.before.date, rect), y: rect.maxY - join.before.value / 100 * rect.height)
            let b = CGPoint(x: x(join.after.date, rect), y: rect.maxY - join.after.value / 100 * rect.height)
            guard b.x >= rect.minX, a.x <= rect.maxX else { continue }
            var path = Path()
            path.move(to: a)
            if metric == .battery {
                let middle = (a.x + b.x) / 2
                path.addCurve(to: b, control1: CGPoint(x: middle, y: a.y), control2: CGPoint(x: middle, y: b.y))
                context.stroke(path, with: .color(metric.tint.opacity(strokeOpacity(metric) * 0.6)),
                    style: StrokeStyle(lineWidth: strokeWidth(metric) * 0.85, lineCap: .round, dash: [2, 3]))
            } else if mode == .calm, join.isBriefMissing {
                // A dashed, quieter link is not observed demand. It never
                // crosses confirmed sleep or enters hover/averages.
                let middle = (a.x + b.x) / 2
                path.addCurve(to: b, control1: CGPoint(x: middle, y: a.y), control2: CGPoint(x: middle, y: b.y))
                context.stroke(path, with: .color(metric.tint.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 3]))
            } else if mode == .calm, let shoulders = InstrumentHistory.sleepShoulders(join,
                visibleDuration: interval.duration, plotWidth: rect.width) {
                let zeroA = CGPoint(x: x(shoulders.down, rect), y: rect.maxY)
                let zeroB = CGPoint(x: x(shoulders.up, rect), y: rect.maxY)
                path.addCurve(to: zeroA, control1: CGPoint(x: (a.x + zeroA.x) / 2, y: a.y),
                    control2: CGPoint(x: (a.x + zeroA.x) / 2, y: rect.maxY))
                path.move(to: zeroB)
                path.addCurve(to: b, control1: CGPoint(x: (b.x + zeroB.x) / 2, y: rect.maxY),
                    control2: CGPoint(x: (b.x + zeroB.x) / 2, y: b.y))
                context.stroke(path, with: .color(metric.tint.opacity(0.32)),
                    style: StrokeStyle(lineWidth: strokeWidth(metric) * 0.8, lineCap: .round, lineJoin: .round))
                var rest = Path(); rest.move(to: zeroA); rest.addLine(to: zeroB)
                context.stroke(rest, with: .color(metric.tint.opacity(0.18)),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
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
            Text(date.formatted(date: !Calendar.autoupdatingCurrent.isDate(interval.start, inSameDayAs: interval.end) ? .abbreviated : .omitted, time: .shortened))
                .foregroundStyle(.secondary)
            if let band = solarBands.first(where: { $0.interval.contains(date) }) {
                Text(band.phase.rawValue).foregroundStyle(.secondary)
            }
            if let region = timeRegions.first(where: { date >= $0.interval.start && date < $0.interval.end }) {
                Text(regionTitle(region)).foregroundStyle(.secondary)
            }
            ForEach(shown) { metric in
                let measured = InstrumentHistory.measuredValue(metric, at: date, samples: inspectionSamples, in: buffer)
                let isBridge = (gapJoins[metric] ?? []).contains {
                    date > $0.before.date && date < $0.after.date && ($0.sleep == nil)
                }
                Text("\(metric.title) \(measured.map { "\(Int($0.rounded()))%" } ?? (isBridge ? "unmeasured" : "—"))")
                    .foregroundStyle(metric.tint)
            }
            if selected.contains(.battery), chargingIntervals.contains(where: { date >= $0.start && date < $0.end }) {
                Image(systemName: "bolt.fill").foregroundStyle(MachinePalette.battery)
                    .accessibilityLabel("Charging")
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
            if !isNow && InstrumentViewport.isDayBoundary(tick) {
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
        // Gap explanations are available on hover, not repeated across the plot.
        for region in timeRegions where region.kind != .away {
            let left = x(region.interval.start, rect), right = x(region.interval.end, rect)
            context.fill(Path(CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)),
                         with: .color(.primary.opacity(0.012)))
        }
    }

    private func rail(_ interval: DateInterval, rect: CGRect, y: CGFloat, color: Color, context: inout GraphicsContext) {
        guard interval.end > self.interval.start, interval.start < self.interval.end else { return }
        var path = Path()
        path.move(to: CGPoint(x: max(rect.minX, x(interval.start, rect)), y: y))
        path.addLine(to: CGPoint(x: min(rect.maxX, x(interval.end, rect)), y: y))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func x(_ date: Date, _ rect: CGRect) -> CGFloat {
        rect.minX + date.timeIntervalSince(interval.start) / max(1, interval.duration) * rect.width
    }
    private func date(_ x: CGFloat, _ rect: CGRect) -> Date {
        interval.start.addingTimeInterval(Double((x - rect.minX) / rect.width) * interval.duration)
    }

    private func displayTicks(width: CGFloat) -> [Date] {
        InstrumentViewport.ticks(in: interval, width: width)
    }

    private func traceShading(_ metric: MachineInstrument, points: [CGPoint], run: [InstrumentPoint], rect: CGRect) -> GraphicsContext.Shading {
        let color = metric.tint.opacity(strokeOpacity(metric))
        guard let first = points.first, let last = points.last, last.x > first.x else { return .color(color) }
        let fade = min(0.35, 8 / (last.x - first.x))
        let joins = (gapJoins[metric] ?? []).filter {
            metric == .battery || (mode == .calm && ($0.isBriefMissing ||
                InstrumentHistory.sleepShoulders($0, visibleDuration: interval.duration, plotWidth: rect.width) != nil))
        }
        let startJoin = joins.first { $0.after.date == run.first?.date }
        let endJoin = joins.first { $0.before.date == run.last?.date }
        let startsAfterBoundary = startJoin == nil && (run.first?.date ?? interval.start).timeIntervalSince(interval.start) > 1.5
        let endsBeforeLive = endJoin == nil && interval.end.timeIntervalSince(run.last?.date ?? interval.end) > 120
        return .linearGradient(Gradient(stops: [
            .init(color: color.opacity(startJoin?.sleep != nil ? 0.32 : startsAfterBoundary ? 0.06 : 1), location: 0),
            .init(color: color, location: fade), .init(color: color, location: 1 - fade),
            .init(color: color.opacity(endJoin?.sleep != nil ? 0.32 : endsBeforeLive ? 0.06 : 1), location: 1)
        ]), startPoint: first, endPoint: CGPoint(x: last.x, y: first.y))
    }

    private func trace(_ points: [CGPoint], metric: MachineInstrument? = nil) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        let controls = mode == .calm ? InstrumentHistory.boundedCurveControls(points) : []
        for index in 1..<points.count {
            let point = points[index]
            if !controls.isEmpty {
                let pair = controls[index - 1]
                path.addCurve(to: point, control1: pair.0, control2: pair.1)
            } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Receives scroll events only inside this chart. Mouse and hover events continue
/// to SwiftUI; native momentum is respected and one load follows the gesture.
private struct InstrumentHorizontalScrollSurface: NSViewRepresentable {
    var onScroll: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> ScrollSurface { ScrollSurface() }
    func updateNSView(_ view: ScrollSurface, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: ScrollSurface, coordinator: ()) { view.settle?.cancel() }

    final class ScrollSurface: NSView {
        var onScroll: ((CGFloat, Bool) -> Void)?
        var settle: DispatchWorkItem?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .scrollWheel,
                  abs(event.scrollingDeltaX) > 0 || !event.momentumPhase.isEmpty else { return nil }
            return super.hitTest(point)
        }
        override func scrollWheel(with event: NSEvent) {
            let delta = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 12)
            guard delta != 0 else { return }
            settle?.cancel()
            onScroll?(delta, false)
            let done = DispatchWorkItem { [weak self] in self?.onScroll?(0, true) }
            settle = done
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: done)
        }
    }
}
