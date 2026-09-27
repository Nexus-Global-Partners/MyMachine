import DailyMacCore
import Foundation
import SQLite3

enum AppCPUCalibrationValidation {
    static func run(harness: ValidationHarness) async {
        await harness.run("CPU calibration JSON preserves unknown legacy provenance") {
            let process = process(at: reference, version: 1)
            let app = app(at: reference, version: 1)
            let system = system(at: reference, version: 1)
            try harness.check(process.cpuMeasurementVersion == 1 && app.cpuMeasurementVersion == 1 && system.monitorCPUMeasurementVersion == 1, "new measurements lost calibration")
            let legacyProcess = try withoutKey("cpuMeasurementVersion", value: process)
            let legacyApp = try withoutKey("cpuMeasurementVersion", value: app)
            let legacySystem = try withoutKey("monitorCPUMeasurementVersion", value: system)
            try harness.check(legacyProcess.cpuMeasurementVersion == nil && legacyApp.cpuMeasurementVersion == nil && legacySystem.monitorCPUMeasurementVersion == nil, "legacy JSON acquired invented calibration")
            try harness.check(legacySystem.cpuPercent == 60 && legacyProcess.cpuPercent == 200, "decoding silently rescaled history")
        }

        await harness.run("CPU provenance migration preserves legacy values and marks only new rows calibrated") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DailyMacCPUCalibration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var handle: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("DailyMac.sqlite").path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
                throw ValidationFailure.failed("could not create isolated legacy fixture")
            }
            let result = sqlite3_exec(handle, legacySchema, nil, nil, nil)
            let detail = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            try harness.check(result == SQLITE_OK, "legacy schema fixture failed: \(detail)")
            let store = try SQLiteStore(directoryURL: directory)
            let window = DateInterval(start: reference.addingTimeInterval(-1), end: reference.addingTimeInterval(120))
            let oldProcesses = try await store.processSamples(in: window)
            let oldApps = try await store.appResourceSamples(in: window)
            let oldSystems = try await store.samples(in: window)
            try harness.check(oldProcesses.count == 1 && oldProcesses[0].cpuMeasurementVersion == 0 && oldProcesses[0].cpuPercent == 7, "process migration changed legacy data or calibration")
            try harness.check(oldApps.count == 1 && oldApps[0].cpuMeasurementVersion == 0 && oldApps[0].cpuPercent == 9, "app migration changed legacy data or calibration")
            try harness.check(oldSystems.count == 1 && oldSystems[0].monitorCPUMeasurementVersion == 0 && oldSystems[0].monitorCPUPercent == 0.1 && oldSystems[0].cpuPercent == 60, "monitor migration changed whole-machine CPU or marked legacy calibrated")
            let oldImpacts = try await store.latestProcessImpacts()
            try harness.check(oldImpacts.isEmpty, "legacy impact escaped calibration filter")
            let now = reference.addingTimeInterval(30)
            try await store.save(sample: system(at: now, version: 1), processes: [process(at: now, version: 1)], appResources: [app(at: now, version: 1)])
            let newSystems = try await store.samples(in: window)
            let newProcesses = try await store.processSamples(in: window)
            let newApps = try await store.appResourceSamples(in: window)
            let newImpacts = try await store.latestProcessImpacts()
            try harness.check(newSystems.last?.monitorCPUMeasurementVersion == 1 && newProcesses.last?.cpuMeasurementVersion == 1 && newApps.last?.cpuMeasurementVersion == 1, "new provenance failed SQLite round trip")
            try harness.check(newSystems.first?.monitorCPUMeasurementVersion == 0 && newProcesses.first?.cpuPercent == 7 && newApps.first?.cpuPercent == 9, "saving current data rewrote legacy rows")
            try harness.check(newImpacts.count == 1, "calibrated process impact disappeared")
        }

        await harness.run("app CPU summaries exclude legacy and whole mixed-version collections") {
            let interval = DateInterval(start: reference, duration: 600)
            let first = reference.addingTimeInterval(60)
            let second = reference.addingTimeInterval(120)
            let current = app(at: second, version: 1)
            let legacy = app(at: first, version: 0, name: "Legacy", cpu: 9_999)
            let contaminated = app(at: first, version: 1, name: "Partial", cpu: 8_888)
            let engine = InsightEngine()
            let values = [legacy, contaminated, current]
            let summaries = engine.makeBackgroundAppSummaries(samples: values, in: interval)
            try harness.check(summaries.count == 1 && summaries[0].ownerName == "Current" && summaries[0].averageCPUPercent == 200 && summaries[0].observedDuration == 30, "partial calibration distorted app summary")
            let sparseContributors = engine.makeAppComputeContributors(samples: values, in: interval)
            try harness.check(sparseContributors.isEmpty, "one calibrated collection bypassed the contributor coverage gate")
            // Four contiguous 30-second calibrated collections reach the existing
            // two-minute evidence floor. The earlier mixed collection stays out.
            let calibratedRun = (0..<4).map {
                app(at: second.addingTimeInterval(Double($0) * 30), version: 1)
            }
            let contributors = engine.makeAppComputeContributors(samples: [legacy, contaminated] + calibratedRun, in: interval)
            try harness.check(contributors.count == 1 && contributors[0].ownerName == "Current", "legacy or mixed-frame app share was retained after sufficient calibrated coverage")
            try harness.check(contributors[0].observedDuration == 120 && contributors[0].cpuCoreSeconds == 240 && contributors[0].observedCPUSharePercent == 100, "mixed collection changed calibrated duration, CPU work, or share")
            try harness.check(engine.makeBackgroundAppSummaries(samples: [legacy], in: interval).isEmpty, "legacy-only CPU was exported")
        }

        await harness.run("diagnosis omits unknown monitor CPU without losing system CPU or memory") {
            let legacy = system(at: reference, version: nil, monitorCPU: 99)
            let missing = system(at: reference.addingTimeInterval(15), version: nil, monitorCPU: 0)
            let oldEvidence = try evidence(samples: [legacy, missing])
            let oldFootprint = oldEvidence["monitorFootprint"] as! [String: Any]
            try harness.check(oldFootprint["cpuAveragePercent"] == nil && oldFootprint["cpuPeakPercent"] == nil, "uncalibrated monitor CPU was represented as numeric evidence")
            try harness.check(oldFootprint["memoryAverageMB"] != nil, "valid monitor memory was removed")
            let current = system(at: reference.addingTimeInterval(30), version: 1, monitorCPU: 2)
            let mixedEvidence = try evidence(samples: [legacy, missing, current])
            let footprint = mixedEvidence["monitorFootprint"] as! [String: Any]
            try harness.check((footprint["cpuAveragePercent"] as? Double) == 2 && (footprint["cpuPeakPercent"] as? Double) == 2, "unknown intervals diluted calibrated footprint")
            let snapshot = InsightEngine().makeMonitoringSnapshot(range: .oneHour, endingAt: current.timestamp, samples: [legacy, missing, current])
            try harness.check(snapshot.averageCPU == 60, "whole-machine history was incorrectly discarded")
        }

        await harness.run("daily CPU attribution excludes uncalibrated processes but retains daily totals") {
            let samples = (1...12).map { system(at: reference.addingTimeInterval(Double($0) * 15), version: nil) }
            let legacyProcesses = samples.map { process(at: $0.timestamp, version: nil, name: "LegacyUnitSentinel") }
            let report = InsightEngine().makeReport(dayKey: "2026-09-07", timezone: TimeZone(secondsFromGMT: 0)!, samples: samples, processSamples: legacyProcesses, events: [])
            let json = String(data: try JSONEncoder().encode(report), encoding: .utf8)!
            try harness.check(report.averageCPU == 60 && report.activeDuration == 180, "daily system aggregate changed")
            try harness.check(!json.contains("LegacyUnitSentinel") && json.contains("uncalibrated"), "legacy process attribution was not honestly withheld")
        }
    }

    private static let reference = Date(timeIntervalSince1970: 1_000)

    private static func withoutKey<T: Codable>(_ key: String, value: T) throws -> T {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        object.removeValue(forKey: key)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func process(at date: Date, version: Int?, name: String = "Current") -> ProcessSample {
        ProcessSample(timestamp: date, processID: 8, processStart: 2, name: name, bundleID: "com.fixture.current", isForeground: false, cpuPercent: 200, memoryBytes: 200, diskReadBytes: 0, diskWriteBytes: 0, energyNanojoules: nil, cpuMeasurementVersion: version)
    }

    private static func app(at date: Date, version: Int?, name: String = "Current", cpu: Double = 200) -> AppResourceSample {
        AppResourceSample(timestamp: date, duration: 30, ownerName: name, ownerBundleID: "com.fixture.\(name)", isForeground: false, cpuPercent: cpu, memoryBytes: 200, diskReadBytes: 0, diskWriteBytes: 0, processCount: 1, workerCount: 0, workerNames: [], cpuMeasurementVersion: version)
    }

    private static func system(at date: Date, version: Int?, monitorCPU: Double = 2) -> SystemSample {
        SystemSample(timestamp: date, duration: 15, foregroundApp: "Fixture", foregroundBundleID: nil, category: .writing, isIdle: false,
                     cpuPercent: 60, gpuPercent: 40, loadAverage1m: 1, loadAverage5m: 1,
                     memoryUsedBytes: 8_000_000_000, memoryTotalBytes: 16_000_000_000, memoryPressure: .low,
                     swapUsedBytes: 0, thermalLevel: .nominal, batteryPercent: nil, powerSource: .battery, isCharging: nil,
                     diskReadBytes: 0, diskWriteBytes: 0, networkReceivedBytes: 0, networkSentBytes: 0,
                     monitorCPUPercent: monitorCPU, monitorMemoryBytes: 1_000_000, monitorDiskWriteBytes: 0,
                     samplingInterval: 15, monitorCPUMeasurementVersion: version)
    }

    private static func evidence(samples: [SystemSample]) throws -> [String: Any] {
        let snapshot = InsightEngine().makeMonitoringSnapshot(range: .oneHour, endingAt: samples.last!.timestamp, samples: samples)
        let trend = TrendSummary(days: 7, activeDuration: 0, averageDailyCPU: 0, mostUsedCategory: nil, notableChange: nil, narrative: "unused")
        let brief = DiagnosisBriefRenderer.render(snapshot: snapshot, samples: samples, events: [], trend7: trend, trend30: trend, includeApplicationNames: false)
        let json = brief.markdown.components(separatedBy: "<machine_evidence>\n")[1].components(separatedBy: "\n</machine_evidence>")[0]
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private static let legacySchema = """
    CREATE TABLE system_samples(
      id TEXT PRIMARY KEY, timestamp REAL NOT NULL, duration REAL NOT NULL,
      foreground_app TEXT NOT NULL, foreground_bundle TEXT, category TEXT NOT NULL,
      is_idle INTEGER NOT NULL, cpu_percent REAL NOT NULL, load_1m REAL NOT NULL,
      load_5m REAL NOT NULL, memory_used INTEGER NOT NULL, memory_total INTEGER NOT NULL,
      memory_pressure TEXT NOT NULL, swap_used INTEGER NOT NULL, thermal TEXT NOT NULL,
      battery_percent REAL, power_source TEXT NOT NULL, is_charging INTEGER,
      disk_read INTEGER NOT NULL, disk_write INTEGER NOT NULL,
      network_received INTEGER NOT NULL, network_sent INTEGER NOT NULL,
      monitor_cpu REAL NOT NULL, monitor_memory INTEGER NOT NULL,
      monitor_disk_write INTEGER NOT NULL, sampling_interval REAL NOT NULL
    );
    INSERT INTO system_samples VALUES('00000000-0000-0000-0000-000000000001',1000,15,'Legacy',NULL,'Writing',0,60,1,1,100,200,'low',0,'nominal',80,'battery',0,0,0,0,0,0.1,50,0,15);
    CREATE TABLE process_samples(
      id TEXT PRIMARY KEY, timestamp REAL NOT NULL, pid INTEGER NOT NULL,
      process_start INTEGER NOT NULL, name TEXT NOT NULL, bundle_id TEXT,
      is_foreground INTEGER NOT NULL, cpu_percent REAL NOT NULL,
      memory_bytes INTEGER NOT NULL, disk_read INTEGER NOT NULL,
      disk_write INTEGER NOT NULL, energy_nj INTEGER
    );
    INSERT INTO process_samples VALUES('00000000-0000-0000-0000-000000000002',1000,7,1,'Legacy',NULL,1,7,100,0,0,NULL);
    CREATE TABLE app_resource_samples(
      id TEXT PRIMARY KEY, timestamp REAL NOT NULL, duration REAL NOT NULL,
      owner_name TEXT NOT NULL, owner_bundle_id TEXT, is_foreground INTEGER NOT NULL,
      cpu_percent REAL NOT NULL, memory_bytes INTEGER NOT NULL, disk_read INTEGER NOT NULL,
      disk_write INTEGER NOT NULL, process_count INTEGER NOT NULL, worker_count INTEGER NOT NULL,
      agent_worker_count INTEGER NOT NULL DEFAULT 0, worker_names TEXT NOT NULL
    );
    INSERT INTO app_resource_samples VALUES('00000000-0000-0000-0000-000000000003',1000,30,'Legacy','com.fixture.legacy',0,9,100,0,0,1,0,0,'[]');
    PRAGMA user_version=5;
    """
}
