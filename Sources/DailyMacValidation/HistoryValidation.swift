import DailyMacCore
import Foundation

enum HistoryValidation {
    static func run(harness: ValidationHarness) async {
        await harness.run("selectable ranges keep line graphs while legacy week summaries stay readable") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
            let week = MonitoringHistory.overviewInterval(for: .oneWeek, endingAt: end, calendar: calendar)!
            let days = MonitoringHistory.daySummaries(in: week, samples: [], reports: [], events: [], calendar: calendar)
            try harness.check(days.count == 7, "week did not provide exactly seven calendar slots")
            try harness.check(days.first?.dayKey == "2026-03-02" && days.last?.dayKey == "2026-03-08", "week calendar labels shifted across DST")
            try harness.check(days.last?.interval.duration == 11 * 3600, "today did not respect spring DST")
            let twoDays = MonitoringRange.fortyEightHours.interval(endingAt: end, calendar: calendar)
            try harness.check(twoDays.duration == 48 * 3600, "48h silently changed to calendar days")
            let clippedDays = MonitoringHistory.daySummaries(in: twoDays, samples: [], reports: [], events: [], calendar: calendar)
            try harness.check(clippedDays.count == 3 && clippedDays.first?.isPartialDay == true, "48h did not expose its clipped first day")
            for range in MonitoringRange.selectableRanges {
                try harness.check(MonitoringHistory.overviewInterval(for: range, endingAt: end) == nil, "\(range.compactLabel) was forced into daily overview")
            }
        }

        await harness.run("daily means retain raw peaks and exclude sleep, invalid and duplicate samples") {
            let day = DayBoundaries.interval(for: "2026-09-01", timezone: utc)!
            let first = sample(day.start.addingTimeInterval(600), duration: 60, cpu: 20, gpu: 40)
            let second = sample(day.start.addingTimeInterval(900), duration: 120, cpu: 80, gpu: nil, idle: true, pressure: .high, thermal: .serious)
            let baseline = sample(day.start.addingTimeInterval(950), duration: 0, cpu: 100, gpu: 100)
            let invalidGPU = sample(day.start.addingTimeInterval(1_100), duration: 60, cpu: 50, gpu: .nan)
            let resource = MonitoringHistory.resourceSummary(from: [second, first, first, baseline, invalidGPU], within: day)
            try harness.check(resource.observedDuration == 240, "overlap or baseline inflated observation time")
            try harness.check(abs((resource.averageCPU ?? -1) - 57.5) < 0.001 && resource.peakCPU == 80, "CPU mean/peak included baseline or missing time")
            try harness.check(resource.averageGPU == 40 && resource.peakGPU == 40 && resource.gpuObservedDuration == 60, "missing/invalid GPU was converted to zero")
            try harness.check(resource.humanActiveDuration == 120 && resource.backgroundDuration == 120, "human/background time no longer reconciles")
            try harness.check(resource.highMemoryDuration == 120 && resource.seriousThermalDuration == 120, "pressure durations were diluted")
            let clipped = MonitoringHistory.resourceSummary(from: [first], within: DateInterval(start: first.timestamp.addingTimeInterval(-30), end: first.timestamp))
            try harness.check(clipped.observedDuration == 30 && clipped.averageCPU == 20, "sample crossing first boundary was not clipped")
        }

        await harness.run("legacy retained days remain useful without fabricated GPU history") {
            let day = DayBoundaries.interval(for: "2026-09-01", timezone: utc)!
            let readings = [sample(day.start.addingTimeInterval(600), duration: 60, cpu: 20, gpu: 40), sample(day.start.addingTimeInterval(900), duration: 120, cpu: 80, gpu: 70)]
            let report = makeReport(dayKey: "2026-09-01", samples: readings)
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
            json.removeValue(forKey: "resourceSummary")
            let legacy = try JSONDecoder().decode(DailyReport.self, from: JSONSerialization.data(withJSONObject: json))
            try harness.check(legacy.resourceSummary == nil, "legacy missing summary failed optional decoding")
            let summary = MonitoringHistory.daySummaries(in: day, samples: [], reports: [legacy], events: [], calendar: utcCalendar)[0]
            try harness.check(summary.source == .retained && summary.observedDuration == 180, "retained day was omitted after raw deletion")
            try harness.check(summary.averageCPU == 60 && summary.peakCPU == 80 && summary.humanActiveDuration == 180, "legacy useful metrics were lost")
            try harness.check(summary.averageGPU == nil && summary.peakGPU == nil && summary.elevatedMemoryDuration == nil, "legacy missing metrics were fabricated")
            let modern = MonitoringHistory.daySummaries(in: day, samples: [], reports: [report], events: [], calendar: utcCalendar)[0]
            try harness.check(modern.averageGPU == 60 && modern.peakGPU == 70, "new daily GPU summary did not survive raw deletion")
        }

        await harness.run("retained reports cannot be sliced or replaced by partially retained detail") {
            let day = DayBoundaries.interval(for: "2026-09-01", timezone: utc)!
            let first = sample(day.start.addingTimeInterval(600), duration: 60, cpu: 20, gpu: 40)
            let last = sample(day.start.addingTimeInterval(3_600), duration: 120, cpu: 80, gpu: 70)
            let report = makeReport(dayKey: "2026-09-01", samples: [first, last])
            let full = MonitoringHistory.daySummaries(in: day, samples: [last], reports: [report], events: [], calendar: utcCalendar)[0]
            try harness.check(full.source == .retained && full.observedDuration == 180 && full.averageCPU == 60, "partial raw retention displaced fuller daily report")
            let partial = DateInterval(start: day.start.addingTimeInterval(1_800), end: day.end)
            let clipped = MonitoringHistory.daySummaries(in: partial, samples: [last], reports: [report], events: [], calendar: utcCalendar)[0]
            try harness.check(clipped.source == .detail && clipped.observedDuration == 120 && clipped.averageCPU == 80, "whole-day report leaked values into clipped window")
            let absent = MonitoringHistory.daySummaries(in: partial, samples: [], reports: [report], events: [], calendar: utcCalendar)[0]
            try harness.check(absent.source == .unavailable && absent.averageCPU == nil, "partial retained day was falsely treated as fully observed")
        }

        await harness.run("daily sleep requires lifecycle evidence and never overlaps observed work") {
            let day = DayBoundaries.interval(for: "2026-09-01", timezone: utc)!
            let sleep = ActivityEvent(timestamp: day.start.addingTimeInterval(600), type: .sleep, title: "Sleep", explanation: "Fixture", severity: .information)
            let wake = ActivityEvent(timestamp: day.start.addingTimeInterval(3_600), type: .wake, title: "Wake", explanation: "Fixture", severity: .information)
            let absent = MonitoringHistory.daySummaries(in: day, samples: [], reports: [], events: [sleep, wake], calendar: utcCalendar)[0]
            try harness.check(absent.source == .unavailable && absent.confirmedSleepDuration == 3_000 && absent.unobservedDuration == 83_400, "unknown day remainder became sleep")
            let observation = sample(day.start.addingTimeInterval(1_800), duration: 60, cpu: 20, gpu: 0)
            let observed = MonitoringHistory.daySummaries(in: day, samples: [observation], reports: [], events: [sleep, wake], calendar: utcCalendar)[0]
            try harness.check(observed.confirmedSleepDuration == 2_940 && observed.observedDuration == 60 && observed.averageGPU == 0, "sleep contradicted observed work or zero GPU became missing")
            let openSleep = MonitoringHistory.daySummaries(in: day, samples: [], reports: [], events: [sleep], calendar: utcCalendar)[0]
            try harness.check(openSleep.confirmedSleepDuration == 0, "unpaired sleep was extended over unknown history")
        }

        await harness.run("day inspection snapshot uses exact selected calendar bounds") {
            let day = DayBoundaries.interval(for: "2026-09-01", timezone: utc)!
            let samples = [sample(day.start.addingTimeInterval(-60), duration: 30, cpu: 99, gpu: 99), sample(day.start.addingTimeInterval(120), duration: 30, cpu: 20, gpu: 40)]
            let snapshot = InsightEngine().makeMonitoringSnapshot(range: .twentyFourHours, endingAt: day.end, samples: samples, intervalOverride: day)
            try harness.check(snapshot.interval == day && snapshot.sampleCount == 1 && snapshot.averageCPU == 20, "selected day did not isolate readings")
        }
    }

    private static let utc = TimeZone(identifier: "UTC")!
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private static func makeReport(dayKey: String, samples: [SystemSample]) -> DailyReport {
        InsightEngine().makeReport(dayKey: dayKey, timezone: utc, samples: samples, processSamples: [], events: [])
    }

    private static func sample(
        _ timestamp: Date, duration: TimeInterval, cpu: Double, gpu: Double?,
        idle: Bool = false, pressure: MemoryPressureLevel = .low, thermal: ThermalLevel = .nominal
    ) -> SystemSample {
        SystemSample(
            timestamp: timestamp, duration: duration,
            foregroundApp: "Fixture", foregroundBundleID: nil, category: .writing, isIdle: idle,
            cpuPercent: cpu, gpuPercent: gpu, loadAverage1m: 1, loadAverage5m: 1,
            memoryUsedBytes: 8_000_000_000, memoryTotalBytes: 16_000_000_000,
            memoryPressure: pressure, swapUsedBytes: 0, thermalLevel: thermal,
            batteryPercent: nil, powerSource: .battery, isCharging: nil,
            diskReadBytes: 0, diskWriteBytes: 0, networkReceivedBytes: 0, networkSentBytes: 0,
            monitorCPUPercent: 0.1, monitorMemoryBytes: 1_000_000, monitorDiskWriteBytes: 0,
            samplingInterval: max(1, duration)
        )
    }
}
