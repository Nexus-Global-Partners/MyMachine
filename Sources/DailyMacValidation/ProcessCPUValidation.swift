import DailyMacCore
import Darwin
import Foundation

enum ProcessCPUValidation {
    static func run(harness: ValidationHarness) async {
        await harness.run("process CPU converts Intel and Apple Silicon Mach timebases") {
            let intel = cpu(user: 700_000_000, system: 300_000_000, elapsed: 2, numerator: 1, denominator: 1)
            let silicon = cpu(user: 16_800_000, system: 7_200_000, elapsed: 2, numerator: 125, denominator: 3)
            try harness.check(intel == 50, "Intel 1:1 Mach ticks did not produce 50% of one core")
            try harness.check(abs((silicon ?? -1) - 50) < 0.000_001, "Apple Silicon CPU ticks were mistaken for nanoseconds")
            let multicore = cpu(user: 96_000_000, system: 24_000_000, elapsed: 1, numerator: 125, denominator: 3)
            try harness.check(abs((multicore ?? -1) - 500) < 0.000_001, "process CPU was incorrectly capped or normalized to whole-machine capacity")
        }

        await harness.run("process CPU preserves small deltas and cannot overflow integer totals") {
            let nearLimit = TelemetrySemantics.processCPUPercent(
                currentUserTicks: .max, currentSystemTicks: .max,
                previousUserTicks: .max - 12_000_000,
                previousSystemTicks: .max - 12_000_000,
                elapsed: 1, timebaseNumerator: 125, timebaseDenominator: 3
            )
            try harness.check(abs((nearLimit ?? -1) - 100) < 0.000_001, "large cumulative counters lost precision before differencing")
            let sumBeyondUInt64 = cpu(user: .max, system: .max, elapsed: 1, numerator: .max, denominator: 1)
            try harness.check(sumBeyondUInt64?.isFinite == true && (sumBeyondUInt64 ?? 0) > 1e18, "CPU conversion wrapped or overflowed a UInt64 sum/timebase multiplication")
            try harness.check(cpu(user: 0, system: 0, elapsed: 30, numerator: 125, denominator: 3) == 0, "measured zero CPU was withheld")
        }

        await harness.run("process CPU rejects counter resets and invalid time evidence") {
            let resetUser = TelemetrySemantics.processCPUPercent(
                currentUserTicks: 99, currentSystemTicks: 200,
                previousUserTicks: 100, previousSystemTicks: 100,
                elapsed: 1, timebaseNumerator: 1, timebaseDenominator: 1
            )
            let resetSystem = TelemetrySemantics.processCPUPercent(
                currentUserTicks: 200, currentSystemTicks: 99,
                previousUserTicks: 100, previousSystemTicks: 100,
                elapsed: 1, timebaseNumerator: 1, timebaseDenominator: 1
            )
            try harness.check(resetUser == nil && resetSystem == nil, "a reset CPU counter was accepted as a valid process delta")
            for duration in [0.0, -1.0, .nan, .infinity, .leastNonzeroMagnitude] {
                try harness.check(cpu(user: 1, system: 1, elapsed: duration, numerator: 125, denominator: 3) == nil, "invalid elapsed time produced a numeric CPU claim")
            }
            try harness.check(cpu(user: 1, system: 1, elapsed: 1, numerator: 0, denominator: 3) == nil, "zero timebase numerator was accepted")
            try harness.check(cpu(user: 1, system: 1, elapsed: 1, numerator: 125, denominator: 0) == nil, "zero timebase denominator was accepted")
        }
    }

    /// Independent calibration against POSIX getrusage for this process only.
    /// About 50 ms of local arithmetic is enough to separate correct conversion
    /// from the former 41.67x error; this is not a system stress test.
    static func runLive(harness: ValidationHarness) async {
        await harness.run("live process CPU agrees with independent POSIX getrusage") {
            var timebase = mach_timebase_info_data_t()
            try harness.check(mach_timebase_info(&timebase) == KERN_SUCCESS, "host Mach timebase unavailable")
            let beforePOSIX = try posixCPUSeconds()
            let beforeMach = try machCPUTicks()
            let started = ProcessInfo.processInfo.systemUptime
            var checksum: UInt64 = 1
            repeat {
                for value in 0..<2_000 {
                    checksum = checksum &* 6_364_136_223_846_793_005 &+ UInt64(value)
                }
            } while ProcessInfo.processInfo.systemUptime - started < 0.05
            let afterMach = try machCPUTicks()
            let afterPOSIX = try posixCPUSeconds()
            let expected = afterPOSIX - beforePOSIX
            guard let percent = TelemetrySemantics.processCPUPercent(
                currentUserTicks: afterMach.user, currentSystemTicks: afterMach.system,
                previousUserTicks: beforeMach.user, previousSystemTicks: beforeMach.system,
                elapsed: 1, timebaseNumerator: timebase.numer, timebaseDenominator: timebase.denom
            ) else { throw ValidationFailure.failed("live CPU delta was invalid") }
            let measured = percent / 100
            try harness.check(expected > 0.002, "live calibration received too little CPU time")
            try harness.check(abs(measured - expected) <= max(0.003, expected * 0.12), "Mach CPU \(measured)s did not match getrusage \(expected)s at timebase \(timebase.numer)/\(timebase.denom)")
            print("      CPU calibration: Mach \(String(format: "%.6f", measured))s / POSIX \(String(format: "%.6f", expected))s; timebase \(timebase.numer)/\(timebase.denom); checksum \(checksum)")
        }
    }

    private static func cpu(user: UInt64, system: UInt64, elapsed: Double, numerator: UInt32, denominator: UInt32) -> Double? {
        TelemetrySemantics.processCPUPercent(
            currentUserTicks: user, currentSystemTicks: system,
            previousUserTicks: 0, previousSystemTicks: 0,
            elapsed: elapsed, timebaseNumerator: numerator, timebaseDenominator: denominator
        )
    }

    private static func posixCPUSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw ValidationFailure.failed("getrusage failed: \(errno)")
        }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func machCPUTicks() throws -> (user: UInt64, system: UInt64) {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            let buffer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(getpid(), RUSAGE_INFO_V4, buffer)
        }
        guard result == 0 else { throw ValidationFailure.failed("proc_pid_rusage failed: \(errno)") }
        return (usage.ri_user_time, usage.ri_system_time)
    }
}
