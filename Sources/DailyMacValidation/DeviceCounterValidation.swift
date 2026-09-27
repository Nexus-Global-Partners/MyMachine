import DailyMacCore

enum DeviceCounterValidation {
    static func run(harness: ValidationHarness) async {
        await harness.run("network and disk deltas exclude new and reset devices") {
            let first: [UInt64: DeviceByteCounters] = [
                1: DeviceByteCounters(read: 1_000, written: 2_000),
                2: DeviceByteCounters(read: 10_000, written: 20_000)
            ]
            let baseline = TelemetrySemantics.continuingDeviceBytes(current: first, previous: [:])
            try harness.check(baseline == DeviceByteCounters(read: 0, written: 0),
                              "initial lifetime counters became interval traffic")

            let second: [UInt64: DeviceByteCounters] = [
                1: DeviceByteCounters(read: 1_030, written: 2_050),
                2: DeviceByteCounters(read: 10_020, written: 20_010),
                3: DeviceByteCounters(read: 9_000_000_000, written: 8_000_000_000)
            ]
            let continuing = TelemetrySemantics.continuingDeviceBytes(current: second, previous: first)
            try harness.check(continuing == DeviceByteCounters(read: 50, written: 60),
                              "a newly appeared device's lifetime total caused a traffic spike")

            let third: [UInt64: DeviceByteCounters] = [
                1: DeviceByteCounters(read: 1_050, written: 2_080),
                3: DeviceByteCounters(read: 9_000_000_040, written: 8_000_000_070)
            ]
            let continuedNewDevice = TelemetrySemantics.continuingDeviceBytes(current: third, previous: second)
            try harness.check(continuedNewDevice == DeviceByteCounters(read: 60, written: 100),
                              "a device was not counted after its baseline was established")

            let fourth: [UInt64: DeviceByteCounters] = [
                1: DeviceByteCounters(read: 10, written: 2_100),
                2: DeviceByteCounters(read: 10_100, written: 20_100),
                3: DeviceByteCounters(read: 9_000_000_050, written: 8_000_000_080)
            ]
            let resetAndReappearance = TelemetrySemantics.continuingDeviceBytes(current: fourth, previous: third)
            try harness.check(resetAndReappearance == DeviceByteCounters(read: 10, written: 10),
                              "a reset or reappearing device was interpreted as observed interval traffic")
        }
    }
}
