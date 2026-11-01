import DailyMacCore
import Foundation
import IOKit.ps

enum MeasurementAccuracyValidation {
    static func run(harness: ValidationHarness) async {
        await harness.run("host CPU failure needs a new baseline and never creates a rollover spike") {
            var tracker = HostCPUTracker()
            let first = HostCPUCounters(user: 100, system: 200, nice: 0, idle: 700)
            let second = HostCPUCounters(user: 110, system: 210, nice: 0, idle: 780)
            try harness.check(tracker.observe(first) == nil, "first host counters became measured CPU")
            try harness.check(tracker.observe(second) == 20, "whole-machine busy tick fraction changed")
            try harness.check(tracker.observe(nil) == nil, "failed host read became zero CPU")
            try harness.check(tracker.observe(first) == nil, "recovery was compared with stale pre-failure counters")
            try harness.check(tracker.observe(second) == 20, "second recovered host observation did not resume")
            try harness.check(tracker.observe(second) == nil, "unchanged host tick counters established false idle")
            try harness.check(tracker.observe(first) == nil, "counter reset became a large rollover")
            try harness.check(TelemetrySemantics.hostCPUTickDelta(current: 3, previous: UInt64(UInt32.max) - 2) == 6,
                              "a real 32-bit tick rollover was lost")
            try harness.check(TelemetrySemantics.hostCPUTickDelta(current: 20, previous: 400) == nil,
                              "a non-boundary backwards jump was accepted")
            try harness.check(TelemetrySemantics.hostCPUTickDelta(current: .max, previous: 0) == nil,
                              "a value outside the host's 32-bit counter width was accepted")
        }

        await harness.run("failed process census and PID restart invalidate previous counter identities") {
            struct Identity: Hashable { let pid: Int; let started: Int }
            let original = Identity(pid: 42, started: 1)
            let restarted = Identity(pid: 42, started: 2)
            var history = CounterObservationHistory<Identity, UInt64>()
            history.replace(with: [original: 100])
            try harness.check(history[original] == 100, "process baseline not recorded")
            history.replace(with: nil)
            try harness.check(history[original] == nil, "enumeration failure retained old counters for a shorter elapsed interval")
            history.replace(with: [original: 300])
            try harness.check(history[original] == 300, "recovery failed to establish a fresh baseline")
            history.replace(with: [restarted: 10])
            try harness.check(history[original] == nil && history[restarted] == 10, "reused PID inherited the old process baseline")
            history.replace(with: [:])
            try harness.check(history[restarted] == nil, "a disappeared process retained its old baseline")
        }

        await harness.run("battery level belongs to the present internal battery and charging remains independent") {
            let internalBattery: [String: Any] = [
                kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
                kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: kIOPSACPowerValue
            ]
            let ups: [String: Any] = [
                kIOPSTypeKey: kIOPSUPSType, kIOPSIsPresentKey: true,
                kIOPSCurrentCapacityKey: 5, kIOPSMaxCapacityKey: 100, kIOPSIsChargingKey: true
            ]
            let reading = BatteryTelemetry.reading(descriptions: [ups, internalBattery], providingSource: .battery)
            try harness.check(reading.percent == 80 && reading.source == .adapter && reading.charging == false,
                              "UPS capacity or plugged-in state replaced the internal battery/charging observation")
            var malformed = internalBattery
            malformed[kIOPSCurrentCapacityKey] = Double.nan
            let invalid = BatteryTelemetry.reading(descriptions: [malformed], providingSource: .unknown)
            try harness.check(invalid.percent == nil && invalid.source == .adapter && invalid.charging == false,
                              "malformed capacity erased independently observed power state")
            var absent = internalBattery
            absent[kIOPSIsPresentKey] = false
            try harness.check(BatteryTelemetry.reading(descriptions: [ups, absent], providingSource: .adapter).percent == nil,
                              "external or absent battery became laptop capacity")
            try harness.check(BatteryTelemetry.reading(descriptions: [internalBattery, internalBattery], providingSource: .adapter).percent == nil,
                              "ambiguous multiple batteries were silently combined")
            for invalid in [-1.0, 101.0, .nan, .infinity] {
                try harness.check(BatteryTelemetry.capacityPercent(current: invalid, maximum: 100) == nil,
                                  "invalid battery capacity became a plausible percentage")
            }
            try harness.check(BatteryTelemetry.capacityPercent(current: 0, maximum: 100) == 0,
                              "valid empty battery was hidden")
            try harness.check(BatteryTelemetry.capacityPercent(current: 50, maximum: 0) == nil,
                              "missing maximum became a percentage")
        }

        await harness.run("GPU percentages need a single valid device and wall-clock steps break continuity") {
            try harness.check(TelemetrySemantics.wholeDeviceGPUPercent([0]) == 0, "measured zero GPU was hidden")
            try harness.check(TelemetrySemantics.wholeDeviceGPUPercent([100]) == 100, "valid GPU utilization changed units")
            for values: [Double] in [[], [20, 80], [.nan], [.infinity], [-1], [101]] {
                try harness.check(TelemetrySemantics.wholeDeviceGPUPercent(values) == nil,
                                  "missing, invalid or multiple GPUs became a whole-machine claim")
            }
            try harness.check(TelemetrySemantics.wallClockIsContinuous(wallElapsed: 15.1, monotonicElapsed: 15), "normal clock jitter broke continuity")
            for elapsed in [-15.0, 0, 60, .nan, .infinity] {
                try harness.check(!TelemetrySemantics.wallClockIsContinuous(wallElapsed: elapsed, monotonicElapsed: 15),
                                  "clock discontinuity could create overlapping or unobserved history")
            }
            try harness.check(TelemetrySemantics.isUnexpectedGap(elapsed: 600, expectedInterval: 15), "sleep-sized gap retained deltas")
        }

        await harness.run("unavailable host intervals stay out of live gauges charts and period averages") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let valid = sample(at: now.addingTimeInterval(-15), duration: 15, cpu: 80)
            let missing = sample(at: now, duration: 0, cpu: 0)
            let window = DateInterval(start: now.addingTimeInterval(-60), end: now)
            try harness.check(MachineStatusSignal.current(sample: missing, at: now) == nil, "missing host interval became live zero")
            try harness.check(MachineDemandAverage.current(sample: missing, recentSamples: [valid], at: now) == nil,
                              "missing host interval became a live average")
            try harness.check(InstrumentHistory.average(.cpu, samples: [valid, missing], in: window) == 80,
                              "period average included a missing interval as zero CPU")
            let points = TimelineSemantics.processorTrend(from: [valid, missing], within: window, range: .oneHour, displayMode: .precise)
            try harness.check(!points.isEmpty && points.allSatisfy { $0.cpuPercent == 80 },
                              "CPU chart drew a false drop to zero for unavailable counters")
        }
    }

    private static func sample(at timestamp: Date, duration: TimeInterval, cpu: Double) -> SystemSample {
        SystemSample(timestamp: timestamp, duration: duration, foregroundApp: "Fixture", foregroundBundleID: nil,
                     category: .other, isIdle: false, cpuPercent: cpu, loadAverage1m: 0, loadAverage5m: 0,
                     memoryUsedBytes: 1_000, memoryTotalBytes: 2_000, memoryPressure: .low, swapUsedBytes: 0,
                     thermalLevel: .nominal, batteryPercent: nil, powerSource: .adapter, isCharging: false,
                     diskReadBytes: 0, diskWriteBytes: 0, networkReceivedBytes: 0, networkSentBytes: 0,
                     monitorCPUPercent: 0, monitorMemoryBytes: 0, monitorDiskWriteBytes: 0, samplingInterval: 15)
    }
}
