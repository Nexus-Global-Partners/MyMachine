import DailyMacCore
import Foundation

enum InstrumentHistoryValidation {
    static func run(harness: ValidationHarness) async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let window = DateInterval(start: start, duration: 3_600)
        await harness.run("historical activity summary excludes today and clips the selected period") {
            let today = sample(start.addingTimeInterval(60), duration: 60)
            let yesterday = start.addingTimeInterval(-86400)
            let history = [sample(yesterday.addingTimeInterval(600), duration: 600),
                           sample(yesterday.addingTimeInterval(900), duration: 300, idle: true), today]
            let historical = RecordedActivityTotals.measure(history, in: DateInterval(start: yesterday, duration: 86400))
            let live = RecordedActivityTotals.measure(history, in: window)
            try harness.check(historical.you == 600 && historical.machine == 900, "history used today's totals or counted idle as human use")
            try harness.check(live.you == 60 && live.machine == 60, "today includes the prior day")
            let partial = RecordedActivityTotals.measure(history, in: DateInterval(start: yesterday.addingTimeInterval(500), duration: 400))
            try harness.check(partial.you == 100 && partial.machine == 400, "selected range duration leaked outside bounds")
            let missing = RecordedActivityTotals.measure(history, in: DateInterval(start: yesterday.addingTimeInterval(-86400), duration: 86400))
            try harness.check(missing.lastReading == nil, "missing history appears as a measured zero")
        }
        await harness.run("battery gaps connect only bounded readings without changing measured coverage") {
            let a = sample(start.addingTimeInterval(60), duration: 60, battery: 80)
            let b = sample(start.addingTimeInterval(1860), duration: 60, battery: 70)
            let points = InstrumentHistory.points(.battery, samples: [a, b], in: window, range: .oneHour, mode: .calm)
            let joins = InstrumentHistory.gapJoins(.battery, points: points, sleeps: [])
            try harness.check(joins.count == 1, "battery still cuts between bounded readings")
            try harness.check(joins.first?.before.value == 80 && joins.first?.after.value == 70, "join changed battery endpoints")
            try harness.check(Set(points.map(\.run)).count == 2, "estimated join became measured data")
            try harness.check(InstrumentHistory.chargingIntervals(samples: [a, b], in: window).isEmpty, "bridge invented charging")
            try harness.check(InstrumentHistory.gapJoins(.battery, points: [], sleeps: []).isEmpty, "empty battery extrapolated")
        }
        await harness.run("processor sleep joins never turn unknown gaps into zero readings") {
            let points = InstrumentHistory.points(.cpu, samples: [sample(start.addingTimeInterval(60), duration: 60),
                sample(start.addingTimeInterval(1860), duration: 60)], in: window, range: .oneHour, mode: .calm)
            let sleep = DateInterval(start: start.addingTimeInterval(70), end: start.addingTimeInterval(1790))
            let joins = InstrumentHistory.gapJoins(.cpu, points: points, sleeps: [sleep])
            try harness.check(joins.count == 1 && joins.first?.sleep == sleep, "confirmed sleep still ends in an abrupt cut")
            try harness.check(InstrumentHistory.gapJoins(.cpu, points: points, sleeps: []).isEmpty, "missing telemetry treated as sleep")
            let brief = DateInterval(start: start.addingTimeInterval(800), duration: 60)
            try harness.check(InstrumentHistory.gapJoins(.gpu, points: points, sleeps: [brief]).isEmpty, "brief sleep covered unrelated missing time")
            try harness.check(InstrumentHistory.gapJoins(.fan, points: points, sleeps: [sleep]).isEmpty, "fan forced to zero without a measurement")
            try harness.check(points.allSatisfy { $0.value == 20 }, "rendering ramp overwrote processor measurements")
        }
        await harness.run("brief missing links remain distinct and cannot cross any sleep") {
            let values = [sample(start.addingTimeInterval(60), duration: 60, cpu: 80),
                          sample(start.addingTimeInterval(150), duration: 30, cpu: 40)]
            let points = InstrumentHistory.points(.cpu, samples: values, in: window, range: .oneHour, mode: .calm)
            let link = InstrumentHistory.gapJoins(.cpu, points: points, sleeps: [])
            try harness.check(link.count == 1 && link[0].isBriefMissing && link[0].sleep == nil, "brief missing sample has no distinct presentation link")
            let sleep = DateInterval(start: start.addingTimeInterval(80), duration: 10)
            try harness.check(InstrumentHistory.gapJoins(.cpu, points: points, sleeps: [sleep]).isEmpty, "unknown link carried high demand through recorded sleep")
            try harness.check(InstrumentHistory.measuredValue(.cpu, at: start.addingTimeInterval(90), samples: values, in: window) == nil, "bridge became a measured hover value")
            try harness.check(Set(points.map(\.run)).count == 2, "brief bridge merged measured coverage")
            let long = [values[0], sample(start.addingTimeInterval(600), duration: 30, cpu: 40)]
            let longPoints = InstrumentHistory.points(.cpu, samples: long, in: window, range: .oneHour, mode: .calm)
            try harness.check(InstrumentHistory.gapJoins(.cpu, points: longPoints, sleeps: []).isEmpty, "long outage acquired invented continuity")
        }
        await harness.run("sleep shoulder geometry avoids zero needles at every chart scale") {
            for hours in [1.0, 6, 8, 24, 48] {
                let visibleDuration = hours * 3600
                let span = DateInterval(start: start, duration: visibleDuration)
                for width in [350.0, 620, 1000] {
                    let tinyGap = visibleDuration * 4 / width
                    let tiny = [sample(start.addingTimeInterval(60), duration: 60),
                                sample(start.addingTimeInterval(60 + tinyGap + 30), duration: 30)]
                    let points = InstrumentHistory.points(.cpu, samples: tiny, in: span, range: .oneHour, mode: .calm)
                    let sleep = DateInterval(start: start.addingTimeInterval(60), duration: tinyGap)
                    let joins = InstrumentHistory.gapJoins(.cpu, points: points, sleeps: [sleep])
                    try harness.check(joins.count == 1, "confirmed tiny sleep lost evidence")
                    try harness.check(InstrumentHistory.sleepShoulders(joins[0], visibleDuration: visibleDuration, plotWidth: width) == nil, "four-pixel sleep became a zero needle")
                    let gapDuration = visibleDuration * 0.3
                    let long = [tiny[0], sample(start.addingTimeInterval(60 + gapDuration + 30), duration: 30)]
                    let longPoints = InstrumentHistory.points(.cpu, samples: long, in: span, range: .oneHour, mode: .calm)
                    let longSleep = DateInterval(start: start.addingTimeInterval(60), duration: gapDuration)
                    guard let longJoin = InstrumentHistory.gapJoins(.cpu, points: longPoints, sleeps: [longSleep]).first else {
                        throw ValidationFailure.failed("readable sleep lost its recorded boundaries")
                    }
                    guard let shoulders = InstrumentHistory.sleepShoulders(longJoin, visibleDuration: visibleDuration, plotWidth: width) else {
                        throw ValidationFailure.failed("readable sleep lost its resting transition")
                    }
                    let downWidth = shoulders.down.timeIntervalSince(longJoin.before.date) / visibleDuration * width
                    let upWidth = longJoin.after.date.timeIntervalSince(shoulders.up) / visibleDuration * width
                    try harness.check(downWidth >= 18 - 0.001 && upWidth >= 18 - 0.001, "sleep shoulder became a narrow spike")
                    try harness.check(shoulders.down >= longSleep.start && shoulders.up <= longSleep.end && shoulders.down < shoulders.up, "sleep geometry escaped confirmed interval")
                }
            }
        }
        await harness.run("tiny run suppression is scale dependent and preserves raw hover values") {
            let samples = [sample(start.addingTimeInterval(30), duration: 30, cpu: 73)]
            let day = DateInterval(start: start, duration: 86400)
            let points = InstrumentHistory.points(.cpu, samples: samples, in: day, range: .today, mode: .calm)
            try harness.check(!InstrumentHistory.shouldDrawRun(points, in: day, plotWidth: 620), "subpixel live fragment still draws a dot")
            try harness.check(InstrumentHistory.shouldDrawRun(points, in: window, plotWidth: 620), "zoomed measurable run stayed hidden")
            try harness.check(InstrumentHistory.measuredValue(.cpu, at: start.addingTimeInterval(15), samples: samples, in: day) == 73, "suppressed run lost its exact reading")
            try harness.check(InstrumentHistory.measuredValue(.cpu, at: start.addingTimeInterval(35), samples: samples, in: day) == nil, "hover extends recording into a gap")
            let unobserved = [sample(start.addingTimeInterval(60), duration: 0, cpu: 0)]
            try harness.check(InstrumentHistory.measuredValue(.cpu, at: start.addingTimeInterval(60), samples: unobserved, in: day) == nil, "restart baseline presented as measured zero")
        }
        await harness.run("processor curves preserve measured peaks without repeated easing or overshoot") {
            let points = [CGPoint(x: 0, y: 70), CGPoint(x: 7, y: 30), CGPoint(x: 19, y: 10),
                          CGPoint(x: 29, y: 45), CGPoint(x: 44, y: 80)]
            let controls = InstrumentHistory.boundedCurveControls(points)
            try harness.check(controls.count == points.count - 1, "lost processor curve segments")
            try harness.check(controls[0].1.y != points[1].y && controls[1].0.y != points[1].y, "processor curve still stops flat at every bucket")
            try harness.check(controls[1].1.y == points[2].y && controls[2].0.y == points[2].y, "measured turning point moved")
            for (index, pair) in controls.enumerated() {
                let a = points[index], b = points[index + 1]
                let low = min(a.y, b.y), high = max(a.y, b.y)
                for step in 0...100 {
                    let t = Double(step) / 100, u = 1 - t
                    let y = u*u*u*a.y + 3*u*u*t*pair.0.y + 3*u*t*t*pair.1.y + t*t*t*b.y
                    try harness.check(y >= low - 0.0001 && y <= high + 0.0001, "processor spline invented an out-of-bounds peak")
                }
            }
        }
        await harness.run("battery curve keeps a steady slope instead of flattening at every reading") {
            let points = [CGPoint(x: 0, y: 20), CGPoint(x: 10, y: 30), CGPoint(x: 30, y: 50), CGPoint(x: 60, y: 80)]
            let controls = InstrumentHistory.batteryCurveControls(points)
            try harness.check(controls.count == points.count - 1, "lost battery segments")
            for (index, pair) in controls.enumerated() {
                try harness.check(abs(pair.0.y - pair.0.x - 20) < 0.0001, "battery flattens at each reading instead of following steady charge")
                try harness.check(abs(pair.1.y - pair.1.x - 20) < 0.0001, "battery introduces repeated easing steps")
                try harness.check(pair.0.x > points[index].x && pair.1.x < points[index + 1].x, "controls escaped the measured time segment")
            }
        }
        await harness.run("battery curve preserves plateaus peaks bounds and continuous slopes") {
            let points = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 50), CGPoint(x: 11, y: 100),
                          CGPoint(x: 20, y: 100), CGPoint(x: 30, y: 60), CGPoint(x: 31, y: 59), CGPoint(x: 50, y: 0)]
            let controls = InstrumentHistory.batteryCurveControls(points)
            for (index, pair) in controls.enumerated() {
                let a = points[index], b = points[index + 1]
                let bounds = min(a.y, b.y)...max(a.y, b.y)
                for step in 0...100 {
                    let t = Double(step) / 100, u = 1 - t
                    let y = u*u*u*a.y + 3*u*u*t*pair.0.y + 3*u*t*t*pair.1.y + t*t*t*b.y
                    try harness.check(y >= bounds.lowerBound - 0.0001 && y <= bounds.upperBound + 0.0001, "battery overshot measured limits")
                }
                if index > 0 {
                    let prior = controls[index - 1].1
                    let incoming = (a.y - prior.y) / (a.x - prior.x)
                    let outgoing = (pair.0.y - a.y) / (pair.0.x - a.x)
                    try harness.check(abs(incoming - outgoing) < 0.0001, "battery has a corner between segments")
                }
            }
            try harness.check(controls[2].0.y == 100 && controls[2].1.y == 100, "full-charge plateau changed")
            try harness.check(InstrumentHistory.batteryCurveControls([]).isEmpty, "empty battery gained data")
            try harness.check(InstrumentHistory.batteryCurveControls([CGPoint(x: 0, y: 50)]).isEmpty, "single reading gained a curve")
        }
        await harness.run("activity totals advance per reading without double counting report refreshes") {
            let first = sample(start.addingTimeInterval(30), duration: 30)
            let next = sample(start.addingTimeInterval(60), duration: 30)
            let before = RecordedActivityTotals.measure([first], in: window)
            let after = RecordedActivityTotals.measure([first, next, first], in: window)
            try harness.check(before.you == 30 && after.you == 60 && after.machine == 60, "new readings did not advance totals exactly once")
            let idle = sample(start.addingTimeInterval(120), duration: 30, idle: true)
            let gap = RecordedActivityTotals.measure([first, next, idle], in: window)
            try harness.check(gap.you == 60 && gap.machine == 90, "idle or unrecorded gaps counted as human use")
            let midnight = RecordedActivityTotals.measure([sample(start.addingTimeInterval(10), duration: 30)], in: window)
            try harness.check(midnight.machine == 10 && midnight.you == 10, "yesterday leaked into today")
            try harness.check(RecordedActivityTotals.measure([], in: window).lastReading == nil, "missing readings gained freshness")
        }
        await harness.run("time guides use readable clock marks and preserve exact endpoints") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
            for hours in [1.0, 4, 6, 12, 24, 48] {
                let range = DateInterval(start: start.addingTimeInterval(173), duration: hours * 3600)
                let ticks = InstrumentTimeContext.ticks(in: range, width: 630, calendar: calendar)
                try harness.check(ticks.first == range.start && ticks.last == range.end, "axis lost exact endpoints")
                try harness.check(ticks.count >= 3 && ticks.count <= 8, "axis became unreadably sparse or busy")
                try harness.check(zip(ticks, ticks.dropFirst()).allSatisfy { $1 > $0 }, "time guides overlapped")
                try harness.check(ticks.dropFirst().dropLast().allSatisfy { calendar.component(.second, from: $0) == 0 }, "interior guides not clock aligned")
            }
        }
        await harness.run("graph absence labels distinguish recorded idle sleep and unknown coverage") {
            func span(_ offset: Double, _ duration: Double) -> DateInterval {
                DateInterval(start: start.addingTimeInterval(offset), duration: duration)
            }
            let presence = TimelinePresenceContext(awakeIntervals: [span(0, 600)], handsOnIntervals: [span(0, 120)])
            let regions = InstrumentTimeContext.regions(presence: presence, sleeps: [span(900, 300)], in: span(0, 1800))
            try harness.check(regions.filter { $0.kind == .away }.reduce(0) { $0 + $1.interval.duration } == 480, "unknown time was labeled away")
            try harness.check(regions.filter { $0.kind == .sleep }.reduce(0) { $0 + $1.interval.duration } == 300, "sleep lost lifecycle evidence")
            try harness.check(regions.filter { $0.kind == .missing }.reduce(0) { $0 + $1.interval.duration } == 900, "missing coverage was filled in")
        }
        await harness.run("instrument means weight recorded time, preserve unknowns, and ignore duplicates") {
            let first = sample(start.addingTimeInterval(30), duration: 30, cpu: 20, rpm: 1_000)
            let second = sample(start.addingTimeInterval(90), duration: 60, cpu: 80, rpm: 4_000)
            let values = [second, first, first]
            let mean = InstrumentHistory.average(.cpu, samples: values, in: window)
            try harness.check(abs((mean ?? -1) - 60) < 0.001, "mean was not duration weighted")
            try harness.check(InstrumentHistory.average(.gpu, samples: values, in: window) == nil, "missing GPU became zero")
            try harness.check(InstrumentHistory.average(.memory, samples: values, in: window) == 50, "memory is not measured used / total")
            try harness.check(abs((InstrumentHistory.average(.fan, samples: values, in: window) ?? -1) - 60) < 0.001, "fan mean was not measured RPM / max")
        }
        await harness.run("fan graph breaks at missing sensor intervals and never invents old history") {
            let values = [
                sample(start.addingTimeInterval(30), duration: 30, rpm: 1_000),
                sample(start.addingTimeInterval(60), duration: 30),
                sample(start.addingTimeInterval(90), duration: 30, rpm: 4_000),
                sample(start.addingTimeInterval(300), duration: 30, rpm: 0)
            ]
            for mode in [TimelineDisplayMode.calm, .precise] {
                let points = InstrumentHistory.points(.fan, samples: values, in: window, range: .oneHour, mode: mode)
                try harness.check(Set(points.map(\.run)).count == 3, "fan history bridged missing or unrecorded time")
                try harness.check(points.contains { $0.value == 0 }, "a measured stopped fan was omitted")
                let legacy = InstrumentHistory.points(.fan, samples: [values[1]], in: window, range: .oneHour, mode: mode)
                try harness.check(legacy.isEmpty, "legacy fan readings were fabricated")
            }
        }
        await harness.run("physical curves use ordered bucket centers without vertical step edges") {
            let values = (1...24).map { index in
                sample(start.addingTimeInterval(Double(index) * 30), duration: 30,
                       rpm: index < 12 ? 1_000 : 4_000)
            }
            for metric in [MachineInstrument.fan, .memory] {
                for mode in [TimelineDisplayMode.calm, .precise] {
                    let points = InstrumentHistory.points(metric, samples: values, in: window, range: .oneHour, mode: mode)
                    try harness.check(points.first?.date == start && points.last?.date == start.addingTimeInterval(720), "smoothed signal lost observed endpoints")
                    try harness.check(zip(points, points.dropFirst()).allSatisfy { $0.date < $1.date }, "duplicate-time step edge remains")
                    try harness.check(points.allSatisfy { (0...100).contains($0.value) }, "physical curve exceeds measured scale")
                    if metric == .fan {
                        try harness.check(points.contains { $0.value == 20 } && points.contains { $0.value == 80 }, "measured fan levels lost")
                    }
                }
            }
        }
        await harness.run("fan history survives SQLite and legacy JSON remains readable") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("machine-instrument-validation-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            let measured = sample(start.addingTimeInterval(30), duration: 30, rpm: 2_500)
            try await store.save(sample: measured, processes: [])
            let restored = try await store.samples(in: window)
            try harness.check(restored.first?.fanRPM == 2_500 && restored.first?.fanMaximumRPM == 5_000, "fan database fields lost")
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(measured)) as! [String: Any]
            json.removeValue(forKey: "fanRPM")
            json.removeValue(forKey: "fanMaximumRPM")
            let legacy = try JSONDecoder().decode(SystemSample.self, from: JSONSerialization.data(withJSONObject: json))
            try harness.check(MachineInstrument.fan.value(in: legacy) == nil, "legacy decoding inferred a fan value")
            let invalid = sample(start.addingTimeInterval(60), duration: 30, rpm: -1)
            try harness.check(MachineInstrument.fan.value(in: invalid) == nil, "invalid RPM became a graph value")
        }
        await harness.run("CPU continuity does not depend on GPU sensor availability") {
            let values = [sample(start.addingTimeInterval(30), duration: 30, gpu: 40),
                          sample(start.addingTimeInterval(60), duration: 30),
                          sample(start.addingTimeInterval(90), duration: 30, gpu: 60)]
            let cpu = InstrumentHistory.points(.cpu, samples: values, in: window, range: .oneHour, mode: .calm)
            let gpu = InstrumentHistory.points(.gpu, samples: values, in: window, range: .oneHour, mode: .calm)
            try harness.check(Set(cpu.map(\.run)).count == 1, "continuous CPU split when only GPU was missing")
            try harness.check(Set(gpu.map(\.run)).count == 2, "missing GPU was bridged")
        }
        await harness.run("condensed time preserves dates durations and background work at every scale") {
            for hours in [1.0, 4, 6, 12, 24, 48] {
                let duration = hours * 3600
                let range = DateInterval(start: start, duration: duration)
                let first = DateInterval(start: start, duration: duration * 0.25)
                let second = DateInterval(start: start.addingTimeInterval(duration * 0.8), end: range.end)
                let sleep = DateInterval(start: first.end, end: second.start)
                let presence = TimelinePresenceContext(awakeIntervals: [first, second], handsOnIntervals: [])
                let regions = InstrumentTimeContext.regions(presence: presence, sleeps: [sleep], in: range)
                let scale = InstrumentTimeScale(window: range, regions: regions, mode: .calm)
                try harness.check(scale.condensedRegions.count == 1, "long sleep not condensed")
                let gapWidth = scale.fraction(at: sleep.end) - scale.fraction(at: sleep.start)
                try harness.check(gapWidth < 0.07 && gapWidth > 0, "sleep consumed chart space or disappeared")
                try harness.check(scale.condensedRegions.first?.interval.duration == sleep.duration, "true gap duration changed")
                try harness.check(scale.fraction(at: range.start) == 0 && scale.fraction(at: range.end) == 1, "axis endpoints changed")
                for index in 0...100 {
                    let date = start.addingTimeInterval(duration * Double(index) / 100)
                    try harness.check(abs(scale.date(at: scale.fraction(at: date)).timeIntervalSince(date)) < 0.001, "hover date differs from drawn date")
                }
                let precise = InstrumentTimeScale(window: range, regions: regions, mode: .precise)
                try harness.check(precise.condensedRegions.isEmpty && precise.displayedDuration == duration, "Precise no longer shows elapsed time")
                let background = TimelinePresenceContext(awakeIntervals: [range], handsOnIntervals: [])
                let backgroundRegions = InstrumentTimeContext.regions(presence: background, sleeps: [], in: range)
                try harness.check(InstrumentTimeScale(window: range, regions: backgroundRegions, mode: .calm).condensedRegions.isEmpty, "recorded background work was compressed")
                let empty = InstrumentTimeContext.regions(presence: .init(awakeIntervals: [], handsOnIntervals: []), sleeps: [], in: range)
                try harness.check(InstrumentTimeScale(window: range, regions: empty, mode: .calm).condensedRegions.isEmpty, "an entirely missing range gained fake activity space")
            }
        }
        await harness.run("condensed long ranges retain short-session curve detail and true gaps") {
            let range = DateInterval(start: start, duration: 48 * 3600)
            let firstSession: [SystemSample] = (1...120).map { index in
                sample(start.addingTimeInterval(Double(index) * 30), duration: 30, cpu: Double(index % 60), gpu: 50)
            }
            let secondStart = start.addingTimeInterval(47 * 3600)
            let secondSession: [SystemSample] = (1...120).map { index in
                sample(secondStart.addingTimeInterval(Double(index) * 30), duration: 30, cpu: Double(index % 60), gpu: 60)
            }
            let values = firstSession + secondSession
            let points = InstrumentHistory.points(.cpu, samples: values, in: range, range: .fortyEightHours,
                                                  mode: .calm, displayedDuration: 2 * 3600)
            try harness.check(points.count >= 48, "long-range buckets flattened short sessions")
            try harness.check(Set(points.map(\.run)).count == 2, "true multi-hour gap was connected")
            try harness.check(!points.contains { $0.date > start.addingTimeInterval(3600) && $0.date < start.addingTimeInterval(47 * 3600) }, "points invented inside gap")
        }
        await harness.run("multiple condensed gaps preserve leading trailing and interior time") {
            let range = DateInterval(start: start, duration: 24 * 3600)
            let awake = [(4.0, 6.0), (12.0, 14.0), (21.0, 22.0)].map {
                DateInterval(start: start.addingTimeInterval($0.0 * 3600), end: start.addingTimeInterval($0.1 * 3600))
            }
            let regions = InstrumentTimeContext.regions(presence: .init(awakeIntervals: awake, handsOnIntervals: []), sleeps: [], in: range)
            let scale = InstrumentTimeScale(window: range, regions: regions, mode: .calm)
            try harness.check(scale.condensedRegions.count == 4, "leading or trailing gap not retained")
            var previous = -1.0
            for index in 0...240 {
                let date = start.addingTimeInterval(Double(index) * 360)
                let fraction = scale.fraction(at: date)
                try harness.check(fraction > previous, "condensed time reversed or collapsed")
                try harness.check(abs(scale.date(at: fraction).timeIntervalSince(date)) < 0.001, "multiple-gap inspection date drifted")
                previous = fraction
            }
            let totalGapWidth = scale.condensedRegions.reduce(0.0) { $0 + scale.fraction(at: $1.interval.end) - scale.fraction(at: $1.interval.start) }
            try harness.check(totalGapWidth <= 0.261, "gaps consume too much plot space")
        }
    }

    private static func sample(_ date: Date, duration: Double, cpu: Double = 20, rpm: Double? = nil, idle: Bool = false, gpu: Double? = nil, battery: Double? = nil) -> SystemSample {
        SystemSample(timestamp: date, duration: duration, foregroundApp: "Test", foregroundBundleID: nil,
                     category: idle ? .idle : .other, isIdle: idle, cpuPercent: cpu, gpuPercent: gpu, loadAverage1m: 1, loadAverage5m: 1,
                     memoryUsedBytes: 4_000, memoryTotalBytes: 8_000, memoryPressure: .low,
                     swapUsedBytes: 0, thermalLevel: .nominal, batteryPercent: battery,
                     powerSource: .unknown, isCharging: nil, diskReadBytes: 0, diskWriteBytes: 0,
                     networkReceivedBytes: 0, networkSentBytes: 0, monitorCPUPercent: 0,
                     monitorMemoryBytes: 0, monitorDiskWriteBytes: 0, samplingInterval: duration,
                     fanRPM: rpm, fanMaximumRPM: rpm == nil ? nil : 5_000)
    }
}
