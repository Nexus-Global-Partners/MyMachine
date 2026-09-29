import DailyMacCore
import Foundation

enum InstrumentHistoryValidation {
    static func run(harness: ValidationHarness) async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let window = DateInterval(start: start, duration: 3_600)
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
    }

    private static func sample(_ date: Date, duration: Double, cpu: Double = 20, rpm: Double? = nil) -> SystemSample {
        SystemSample(timestamp: date, duration: duration, foregroundApp: "Test", foregroundBundleID: nil,
                     category: .other, isIdle: false, cpuPercent: cpu, loadAverage1m: 1, loadAverage5m: 1,
                     memoryUsedBytes: 4_000, memoryTotalBytes: 8_000, memoryPressure: .low,
                     swapUsedBytes: 0, thermalLevel: .nominal, batteryPercent: nil,
                     powerSource: .unknown, isCharging: nil, diskReadBytes: 0, diskWriteBytes: 0,
                     networkReceivedBytes: 0, networkSentBytes: 0, monitorCPUPercent: 0,
                     monitorMemoryBytes: 0, monitorDiskWriteBytes: 0, samplingInterval: duration,
                     fanRPM: rpm, fanMaximumRPM: rpm == nil ? nil : 5_000)
    }
}
