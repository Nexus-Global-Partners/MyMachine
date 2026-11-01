import DailyMacCore
import Foundation

enum BatteryDischargeEstimateValidation {
    static func run(harness: ValidationHarness) async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await harness.run("battery forecast uses a recent measured pace and reports uncertainty") {
            let history = readings(endingAt: now, minutes: 60) { 60 - floor(Double($0) / 6) }
            guard let forecast = BatteryDischargeEstimate.estimate(samples: history, now: now) else {
                throw ValidationFailure.failed("stable hour of discharge did not produce a forecast")
            }
            try harness.check(abs(forecast.percentagePointsPerHour - 10) < 0.001, "discharge rate has wrong units")
            try harness.check(abs(forecast.minutesRemaining - 240) < 0.001, "forecast did not target 10% remaining")
            try harness.check(forecast.reachesTenPercentAt == now.addingTimeInterval(4 * 3_600), "forecast clock used the wrong anchor")
            try harness.check(forecast.earliestTenPercentAt < forecast.reachesTenPercentAt
                              && forecast.latestTenPercentAt > forecast.reachesTenPercentAt,
                              "forecast sensitivity range did not enclose its point estimate")
            let later = BatteryDischargeEstimate.estimate(samples: history, now: now.addingTimeInterval(60))
            try harness.check(later?.reachesTenPercentAt == forecast.reachesTenPercentAt,
                              "clock estimate drifted forward when no newer battery observation arrived")
            try harness.check(abs((later?.minutesRemaining ?? -1) - 239) < 0.001, "elapsed time was not deducted")
            try harness.check(BatteryDischargeEstimate.estimate(samples: Array(history.reversed()) + history, now: now) == forecast,
                              "sorting or duplicate records changed the forecast")
        }

        await harness.run("battery forecast permits quantized plateaus but needs enough discharge") {
            let partial = readings(endingAt: now, minutes: 20) { 30 - floor(Double($0) * 3 / 20) }
            let estimate = BatteryDischargeEstimate.estimate(samples: partial, now: now)
            try harness.check(estimate != nil && estimate?.observedDrop == 3, "normal repeated integer percentages were rejected")
            try harness.check(BatteryDischargeEstimate.estimate(samples: readings(endingAt: now, minutes: 19) { 30 - Double($0) / 5 }, now: now) == nil,
                              "less than twenty minutes became a forecast")
            try harness.check(BatteryDischargeEstimate.estimate(samples: readings(endingAt: now, minutes: 60) { 50 - Double($0) / 30 }, now: now) == nil,
                              "two-point reporting noise became a forecast")
            try harness.check(BatteryDischargeEstimate.estimate(samples: readings(endingAt: now, minutes: 60) { _ in 50 }, now: now) == nil,
                              "flat battery produced a runtime claim")
            try harness.check(BatteryDischargeEstimate.estimate(samples: readings(endingAt: now, minutes: 60) { 100 - Double($0) / 20 }, now: now) == nil,
                              "extreme extrapolation horizon was shown")
        }

        await harness.run("battery forecast rejects unknown charging adapter stale and invalid current state") {
            let history = readings(endingAt: now, minutes: 30) { 40 - Double($0) / 3 }
            for latest in [
                sample(at: now, battery: 30, power: .adapter),
                sample(at: now, battery: 30, charging: true),
                sample(at: now, battery: 30, charging: nil),
                sample(at: now, battery: 30, power: .unknown),
                sample(at: now, battery: nil), sample(at: now, battery: .nan),
                sample(at: now, battery: 10), sample(at: now, battery: 9),
                sample(at: now, battery: 30, duration: 0)
            ] {
                try harness.check(BatteryDischargeEstimate.estimate(samples: Array(history.dropLast()) + [latest], now: now) == nil,
                                  "invalid or non-discharging current state produced a forecast")
            }
            try harness.check(BatteryDischargeEstimate.estimate(samples: history, now: now.addingTimeInterval(300)) == nil, "stale history remained a current forecast")
            try harness.check(BatteryDischargeEstimate.estimate(samples: history, now: now.addingTimeInterval(-1)) == nil, "future observation was accepted")
        }

        await harness.run("battery forecast breaks on gaps missing charging coverage and changing pace") {
            let history = readings(endingAt: now, minutes: 60) { 60 - Double($0) / 6 }
            var restarted = history
            restarted[55] = sample(at: history[55].timestamp, battery: history[55].batteryPercent, duration: 0)
            let resumed = BatteryDischargeEstimate.estimate(samples: restarted, now: now)
            try harness.check(resumed != nil, "isolated restart baseline discarded an otherwise supported discharge trend")
            try harness.check(abs((resumed?.observedCoverageFraction ?? 0) - 59.0 / 60) < 0.001,
                              "restart baseline invented interval coverage")
            var prolonged = restarted
            prolonged[54] = sample(at: history[54].timestamp, battery: history[54].batteryPercent, duration: 0)
            try harness.check(BatteryDischargeEstimate.estimate(samples: prolonged, now: now) == nil,
                              "consecutive unavailable intervals retained a confident forecast")
            let gap = history.enumerated().filter { !(42...45).contains($0.offset) }.map(\.element)
            try harness.check(BatteryDischargeEstimate.estimate(samples: gap, now: now) == nil, "forecast bridged a sleep-sized gap")
            var unknownCharging = history
            unknownCharging[50] = sample(at: history[50].timestamp, battery: history[50].batteryPercent, charging: nil)
            try harness.check(BatteryDischargeEstimate.estimate(samples: unknownCharging, now: now) == nil, "missing charging state was fabricated as discharging")
            let sparse = history.enumerated().filter { $0.offset % 10 == 0 }.map(\.element)
            try harness.check(BatteryDischargeEstimate.estimate(samples: sparse, now: now) == nil, "sparse endpoints became reliable coverage")
            let poorCoverage = readings(endingAt: now, minutes: 60, duration: 20) { 60 - Double($0) / 6 }
            try harness.check(BatteryDischargeEstimate.estimate(samples: poorCoverage, now: now) == nil, "unobserved gaps were counted as covered time")
            let flattened = readings(endingAt: now, minutes: 60) { 60 - Double(min($0, 30)) / 3 }
            try harness.check(BatteryDischargeEstimate.estimate(samples: flattened, now: now) == nil, "old discharge rate survived a flat recent half hour")
            let accelerated = readings(endingAt: now, minutes: 60) { $0 <= 30 ? 60 - Double($0) / 30 : 59 - Double($0 - 30) / 3 }
            try harness.check(BatteryDischargeEstimate.estimate(samples: accelerated, now: now) == nil, "abruptly changing workload produced a stable-looking forecast")
            var rebound = history
            rebound[55] = sample(at: history[55].timestamp, battery: 53)
            try harness.check(BatteryDischargeEstimate.estimate(samples: rebound, now: now) == nil, "battery rebound/recalibration was extrapolated")
            let conflict = history + [sample(at: now.addingTimeInterval(-5 * 60), battery: 90)]
            try harness.check(BatteryDischargeEstimate.estimate(samples: conflict, now: now) == nil, "conflicting simultaneous battery readings were silently picked")
        }
    }

    private static func readings(endingAt end: Date, minutes: Int, duration: TimeInterval = 60,
                                 level: (Int) -> Double) -> [SystemSample] {
        (0...minutes).map { minute in
            sample(at: end.addingTimeInterval(Double(minute - minutes) * 60), battery: level(minute), duration: duration)
        }
    }

    private static func sample(at date: Date, battery: Double?, power: PowerSource = .battery,
                               charging: Bool? = false, duration: TimeInterval = 60) -> SystemSample {
        SystemSample(timestamp: date, duration: duration, foregroundApp: "Fixture", foregroundBundleID: nil,
                     category: .other, isIdle: false, cpuPercent: 20, loadAverage1m: 0, loadAverage5m: 0,
                     memoryUsedBytes: 1_000, memoryTotalBytes: 2_000, memoryPressure: .low, swapUsedBytes: 0,
                     thermalLevel: .nominal, batteryPercent: battery, powerSource: power, isCharging: charging,
                     diskReadBytes: 0, diskWriteBytes: 0, networkReceivedBytes: 0, networkSentBytes: 0,
                     monitorCPUPercent: 0, monitorMemoryBytes: 0, monitorDiskWriteBytes: 0, samplingInterval: 60)
    }
}
