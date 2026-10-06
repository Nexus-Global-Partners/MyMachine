import DailyMacCore
import Foundation

enum BatteryNavigationValidation {
    static func run(harness: ValidationHarness) async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let window = DateInterval(start: start, duration: 3600)
        await harness.run("battery card uses measured capacity and replaces only the visible memory instrument") {
            try harness.check(MachineInstrument.panelInstruments == [.cpu, .gpu, .battery, .fan], "incorrect compact instruments")
            for value in [0.0, 50, 100] {
                try harness.check(MachineInstrument.battery.value(in: sample(start, level: value)) == value, "valid battery level lost")
            }
            for value in [Double.nan, -1, 101] {
                try harness.check(MachineInstrument.battery.value(in: sample(start, level: value)) == nil, "invalid battery level shown")
            }
            try harness.check(MachineInstrument.battery.value(in: sample(start, level: nil)) == nil, "missing battery became zero")
        }
        await harness.run("charging fill requires explicit charging and excludes full held unknown and disconnected states") {
            let values = [
                sample(start.addingTimeInterval(30), level: 60, charging: true),
                sample(start.addingTimeInterval(60), level: 62, charging: true),
                sample(start.addingTimeInterval(90), level: 100, charging: false),
                sample(start.addingTimeInterval(120), level: 80, charging: nil),
                sample(start.addingTimeInterval(150), level: 80, charging: true, power: .battery),
                sample(start.addingTimeInterval(180), level: nil, charging: true),
                sample(start.addingTimeInterval(240), level: 85, charging: true)
            ]
            let spans = InstrumentHistory.chargingIntervals(samples: values, in: window)
            try harness.check(spans.count == 2, "charging crossed a false/unknown state or a gap")
            try harness.check(spans[0] == DateInterval(start: start, duration: 60), "adjacent charging intervals not joined exactly")
            try harness.check(spans[1] == DateInterval(start: start.addingTimeInterval(210), duration: 30), "charging extended into missing time")
            let clipped = InstrumentHistory.chargingIntervals(samples: values, in: DateInterval(start: start.addingTimeInterval(15), duration: 30))
            try harness.check(clipped == [DateInterval(start: start.addingTimeInterval(15), duration: 30)], "charging not clipped to selected window")
        }
        await harness.run("battery graph and charging boundaries stay correct across all time scales") {
            for range in MonitoringRange.selectableRanges {
                let span = DateInterval(start: start, duration: range.duration)
                let values = [sample(start.addingTimeInterval(30), level: 20, charging: true),
                              sample(start.addingTimeInterval(60), level: nil),
                              sample(start.addingTimeInterval(90), level: 70),
                              sample(start.addingTimeInterval(1800), level: 75, charging: true)]
                for mode in [TimelineDisplayMode.calm, .precise] {
                    let points = InstrumentHistory.points(.battery, samples: values, in: span, range: range, mode: mode)
                    try harness.check(Set(points.map(\.run)).count == 3, "battery curve bridged unavailable readings")
                    try harness.check(points.allSatisfy { (0...100).contains($0.value) }, "battery curve exceeded percent scale")
                    let regions = InstrumentTimeContext.regions(presence: .init(awakeIntervals: [], handsOnIntervals: []), sleeps: [], in: span)
                    let scale = InstrumentTimeScale(window: span, regions: regions, mode: mode)
                    for charging in InstrumentHistory.chargingIntervals(samples: values, in: span) {
                        try harness.check(abs(scale.date(at: scale.fraction(at: charging.start)).timeIntervalSince(charging.start)) < 0.01, "charging fill moved on time axis")
                    }
                }
            }
        }
        await harness.run("battery and charging survive storage for historical rendering") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("battery-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            try await store.save(sample: sample(start.addingTimeInterval(30), level: 63, charging: true), processes: [])
            let restored = try await store.samples(in: window)
            try harness.check(restored.first?.batteryPercent == 63 && restored.first?.isCharging == true, "stored charging lost")
            try harness.check(InstrumentHistory.chargingIntervals(samples: restored, in: window).first?.duration == 30, "stored fill coverage wrong")
        }
        await harness.run("time arrows move through history without changing duration and return to live") {
            let now = start.addingTimeInterval(4 * 86400)
            for range in MonitoringRange.selectableRanges {
                let live = range.interval(endingAt: now)
                let previous = HistoryNavigation.shifted(live, by: -1, range: range, now: now)!
                try harness.check(previous.end == live.start && previous.duration == live.duration, "arrow changed scale instead of time")
                let earlier = HistoryNavigation.shifted(previous, by: -1, range: range, now: now)!
                try harness.check(HistoryNavigation.shifted(earlier, by: 1, range: range, now: now) == previous, "navigation not reversible")
                try harness.check(HistoryNavigation.shifted(previous, by: 1, range: range, now: now.addingTimeInterval(90)) == nil, "forward did not return to live after time elapsed")
            }
        }
        await harness.run("day navigation respects calendar dates DST and today boundary") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
            let parser = ISO8601DateFormatter()
            let now = parser.date(from: "2026-03-30T12:00:00Z")!
            let today = DateInterval(start: calendar.startOfDay(for: now), end: now)
            let yesterday = HistoryNavigation.shifted(today, by: -1, range: nil, now: now, calendar: calendar)!
            try harness.check(yesterday.duration == 23 * 3600, "DST calendar day forced into 24 hours")
            try harness.check(HistoryNavigation.shifted(yesterday, by: 1, range: nil, now: now, calendar: calendar) == nil, "today is not live")
        }
    }

    private static func sample(_ date: Date, level: Double?, charging: Bool? = false, power: PowerSource = .adapter) -> SystemSample {
        SystemSample(timestamp: date, duration: 30, foregroundApp: "Test", foregroundBundleID: nil,
                     category: .other, isIdle: false, cpuPercent: 20, loadAverage1m: 1, loadAverage5m: 1,
                     memoryUsedBytes: 4000, memoryTotalBytes: 8000, memoryPressure: .low,
                     swapUsedBytes: 0, thermalLevel: .nominal, batteryPercent: level,
                     powerSource: power, isCharging: charging, diskReadBytes: 0, diskWriteBytes: 0,
                     networkReceivedBytes: 0, networkSentBytes: 0, monitorCPUPercent: 0,
                     monitorMemoryBytes: 0, monitorDiskWriteBytes: 0, samplingInterval: 30)
    }
}
