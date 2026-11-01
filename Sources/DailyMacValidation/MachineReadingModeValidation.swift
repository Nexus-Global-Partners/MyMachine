import DailyMacCore
import Foundation

enum MachineReadingModeValidation {
    static func run(harness: ValidationHarness) async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await harness.run("live reading uses the latest measurement rather than a hidden two-minute average") {
            let old = sample(now.addingTimeInterval(-60), duration: 60, cpu: 10)
            let latest = sample(now, duration: 30, cpu: 90, gpu: 80)
            let result = MachineReadingSnapshot(mode: .live, latest: latest, samples: [old, latest], liveFanPercent: 40, at: now)
            try harness.check(result.values[.cpu] == 90 && result.demand?.cpuPercent == 90, "live card/icon diverged or remained smoothed")
            try harness.check(result.values[.gpu] == 80 && result.signal?.effortScore == 90, "effort did not follow live demand")
            try harness.check(result.values[.fan] == 40, "live fan ignored fresh sensor")
        }
        await harness.run("all average windows clip boundaries weight duration and omit missing time") {
            for mode in MachineReadingMode.allCases where mode != .live {
                let duration = mode.duration!
                let first = sample(now.addingTimeInterval(-duration + 10), duration: 30, cpu: 20, rpm: 1000)
                let latest = sample(now, duration: 30, cpu: 80, rpm: 4000)
                let result = MachineReadingSnapshot(mode: mode, latest: latest, samples: [latest, first, first], at: now)
                try harness.check(abs((result.values[.cpu] ?? -1) - 65) < 0.001, "window did not clip, deduplicate, or duration-weight")
                try harness.check(result.demand?.cpuPercent == 65 && result.signal?.cpuPercent == 65, "icon and effort diverged from average")
                try harness.check(abs((result.values[.fan] ?? -1) - 65) < 0.001, "fan average differs from measured RPM coverage")
                try harness.check(result.values[.gpu] == nil && result.demand?.gpuPercent == nil, "missing GPU became zero")
                try harness.check(result.interval.duration == duration, "selected duration changed")
            }
        }
        await harness.run("averages preserve latest battery and current thermal safety") {
            let old = sample(now.addingTimeInterval(-60), duration: 30, cpu: 10, battery: 90)
            let latest = sample(now, duration: 30, cpu: 20, battery: 30, thermal: .critical)
            let result = MachineReadingSnapshot(mode: .average4Hours, latest: latest, samples: [old, latest], at: now)
            try harness.check(result.values[.battery] == 30, "battery became a misleading average charge level")
            try harness.check(result.signal?.health == .critical, "current thermal safety was averaged away")
            try harness.check(result.signal?.effortScore == 15, "thermal health overwrote measured average effort")
        }
        await harness.run("stale baselines and empty history never appear as live values") {
            let old = sample(now.addingTimeInterval(-600), duration: 30, cpu: 80)
            let baseline = sample(now, duration: 0, cpu: 0)
            for latest in [old, baseline] {
                let result = MachineReadingSnapshot(mode: .average5Minutes, latest: latest, samples: [old, baseline], liveFanPercent: 50, at: now)
                try harness.check(result.values.isEmpty && result.signal == nil && result.demand == nil, "stale/baseline value appeared current")
            }
            let empty = MachineReadingSnapshot(mode: .live, latest: nil, samples: [], at: now)
            try harness.check(empty.values.isEmpty, "empty history gained measurements")
        }
        await harness.run("four hour mode includes retained data outside the latest two minutes") {
            let old = sample(now.addingTimeInterval(-10800), duration: 60, cpu: 90)
            let latest = sample(now, duration: 30, cpu: 0)
            let long = MachineReadingSnapshot(mode: .average4Hours, latest: latest, samples: [old, latest], at: now)
            let short = MachineReadingSnapshot(mode: .average5Minutes, latest: latest, samples: [old, latest], at: now)
            try harness.check(long.values[.cpu] == 60 && short.values[.cpu] == 0, "long average silently used only recent samples")
        }
        await harness.run("app CPU shares use same-window core seconds with no duplicate interval weighting") {
            let first = app(now.addingTimeInterval(-60), duration: 60, name: "A", cpu: 100)
            let lastA = app(now, duration: 30, name: "A", cpu: 0)
            let lastB = app(now, duration: 30, name: "B", cpu: 100)
            let window = DateInterval(start: now.addingTimeInterval(-90), end: now)
            let rows = MachineReadingSnapshot.appContributors(samples: [first, first, lastA, lastB], in: window)
            try harness.check(rows.count == 2 && rows.allSatisfy { abs($0.observedCPUSharePercent - 50) < 0.001 }, "app shares were unweighted or duplicates counted")
            try harness.check(rows.reduce(0) { $0 + $1.cpuCoreSeconds } == 60, "app window included out-of-window CPU")
        }
        await harness.run("uncalibrated app collections are excluded as a whole") {
            let valid = app(now, duration: 30, name: "A", cpu: 100)
            let invalid = app(now, duration: 30, name: "B", cpu: 50, version: nil)
            let rows = MachineReadingSnapshot.appContributors(samples: [valid, invalid], in: DateInterval(start: now.addingTimeInterval(-300), end: now))
            try harness.check(rows.isEmpty, "mixed CPU measurement versions fabricated shares")
        }
        await harness.run("activity jump lookup is bounded inclusive and excludes counter baselines") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("machine-jump-validation-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            let before = now.addingTimeInterval(-3600), after = now.addingTimeInterval(-60)
            for reading in [sample(before.addingTimeInterval(-60), duration: 30, cpu: 20),
                            sample(before, duration: 30, cpu: 20),
                            sample(now.addingTimeInterval(-1800), duration: 0, cpu: 0),
                            sample(after, duration: 30, cpu: 20)] {
                try await store.save(sample: reading, processes: [])
            }
            let bounds = DateInterval(start: before, end: after)
            let next = try await store.recordedSampleTimestamps(in: bounds, direction: 1)
            let previous = try await store.recordedSampleTimestamps(in: bounds, direction: -1)
            try harness.check(next == [before, after] && previous == [after, before], "jump lookup escaped bounds, dropped exact boundary, or included a baseline")
            let limited = try await store.recordedSampleTimestamps(in: bounds, direction: 1, limit: 1)
            try harness.check(limited == [before], "bounded jump query ignored limit")
        }
        await harness.run("reading preference raw values round-trip every supported mode") {
            for mode in MachineReadingMode.allCases {
                try harness.check(MachineReadingMode(rawValue: mode.rawValue) == mode, "mode did not survive persistence")
            }
            try harness.check(Set(MachineReadingMode.allCases.compactMap(\.duration)) == Set([300.0, 1800, 3600, 14400]), "average options changed")
        }
    }

    private static func sample(_ date: Date, duration: Double, cpu: Double, gpu: Double? = nil,
                               rpm: Double? = nil, battery: Double? = nil, thermal: ThermalLevel = .nominal) -> SystemSample {
        SystemSample(timestamp: date, duration: duration, foregroundApp: "Test", foregroundBundleID: nil,
                     category: .other, isIdle: false, cpuPercent: cpu, gpuPercent: gpu, loadAverage1m: 1, loadAverage5m: 1,
                     memoryUsedBytes: 4_000, memoryTotalBytes: 8_000, memoryPressure: .low,
                     swapUsedBytes: 0, thermalLevel: thermal, batteryPercent: battery,
                     powerSource: .unknown, isCharging: nil, diskReadBytes: 0, diskWriteBytes: 0,
                     networkReceivedBytes: 0, networkSentBytes: 0, monitorCPUPercent: 0,
                     monitorMemoryBytes: 0, monitorDiskWriteBytes: 0, samplingInterval: max(30, duration),
                     fanRPM: rpm, fanMaximumRPM: rpm == nil ? nil : 5000)
    }
    private static func app(_ date: Date, duration: Double, name: String, cpu: Double, version: Int? = 1) -> AppResourceSample {
        AppResourceSample(timestamp: date, duration: duration, ownerName: name, ownerBundleID: "test.\(name)",
                          isForeground: false, cpuPercent: cpu, memoryBytes: 0, diskReadBytes: 0, diskWriteBytes: 0,
                          processCount: 1, workerCount: 0, workerNames: [], cpuMeasurementVersion: version)
    }
}
