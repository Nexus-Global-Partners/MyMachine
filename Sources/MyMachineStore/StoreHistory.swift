import Foundation

struct StoreReading: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let cpuPercent: Double?
    let cpuDuration: TimeInterval
    let memoryUsed: UInt64?
    let memoryTotal: UInt64?
    let batteryPercent: Double?
    let powerSource: PowerSource
    let isCharging: Bool?
    let thermal: ThermalLevel

    init(
        id: UUID = UUID(),
        timestamp: Date,
        cpuPercent: Double?,
        cpuDuration: TimeInterval,
        memoryUsed: UInt64?,
        memoryTotal: UInt64?,
        batteryPercent: Double?,
        powerSource: PowerSource,
        isCharging: Bool?,
        thermal: ThermalLevel
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.cpuDuration = cpuDuration
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.batteryPercent = batteryPercent
        self.powerSource = powerSource
        self.isCharging = isCharging
        self.thermal = thermal
    }

    init(sample: SystemSample) {
        self.init(
            id: sample.id,
            timestamp: sample.timestamp,
            cpuPercent: sample.duration > 0 ? sample.cpuPercent : nil,
            cpuDuration: sample.duration,
            memoryUsed: sample.memoryTotalBytes > 0 ? sample.memoryUsedBytes : nil,
            memoryTotal: sample.memoryTotalBytes > 0 ? sample.memoryTotalBytes : nil,
            batteryPercent: sample.batteryPercent,
            powerSource: sample.powerSource,
            isCharging: sample.isCharging,
            thermal: sample.thermalLevel
        )
    }

    var sample: SystemSample {
        // The shared schema has fields for direct-distribution metrics. Store
        // history never supplies app identities, input, or other sensor data.
        SystemSample(
            id: id, timestamp: timestamp, duration: cpuDuration,
            foregroundApp: "", foregroundBundleID: nil, category: .other, isIdle: false,
            cpuPercent: cpuPercent ?? 0, loadAverage1m: 0, loadAverage5m: 0,
            memoryUsedBytes: memoryUsed ?? 0, memoryTotalBytes: memoryTotal ?? 0,
            memoryPressure: .low, swapUsedBytes: 0, thermalLevel: thermal,
            batteryPercent: batteryPercent, powerSource: powerSource, isCharging: isCharging,
            diskReadBytes: 0, diskWriteBytes: 0, networkReceivedBytes: 0, networkSentBytes: 0,
            monitorCPUPercent: 0, monitorMemoryBytes: 0, monitorDiskWriteBytes: 0,
            samplingInterval: StoreHistory.samplingSeconds
        )
    }
}

struct StoreSleepSpan: Identifiable, Equatable, Sendable {
    let id: UUID
    let start: Date
    let end: Date

    init(id: UUID = UUID(), start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }

    var events: [ActivityEvent] {
        [
            ActivityEvent(timestamp: start, type: .sleep, title: "Mac went to sleep",
                          explanation: "Monitoring paused for sleep.", severity: .information, sleepCycleID: id),
            ActivityEvent(timestamp: end, type: .wake, title: "Mac woke",
                          explanation: "Monitoring resumed with a new CPU baseline.", severity: .information, sleepCycleID: id)
        ]
    }

    static func observedSpans(from events: [ActivityEvent]) -> [StoreSleepSpan] {
        var starts: [UUID: Date] = [:]
        var spans: [StoreSleepSpan] = []
        for event in events {
            guard let id = event.sleepCycleID else { continue }
            if event.type == .sleep {
                starts[id] = event.timestamp
            } else if event.type == .wake, let start = starts.removeValue(forKey: id), start < event.timestamp {
                spans.append(StoreSleepSpan(id: id, start: start, end: event.timestamp))
            }
        }
        return spans
    }
}

struct StoreHistory: Sendable {
    static let samplingSeconds: TimeInterval = 15
    static let retentionDays = 3
    static let retentionWindow = TimeInterval(retentionDays) * 86_400

    let database: SQLiteStore

    init(directory: URL) throws {
        // An explicit directory disables SQLiteStore's direct-release migration.
        database = try SQLiteStore(directoryURL: directory)
    }

    static func containerDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MyMachine", isDirectory: true)
    }

    func prune(at now: Date) async throws {
        var settings = MonitoringSettings.default
        settings.rawRetentionDays = Self.retentionDays
        settings.eventRetentionDays = Self.retentionDays
        settings.reportRetentionDays = Self.retentionDays
        try await database.performRetention(settings: settings, now: now)
    }

    func load(at now: Date) async throws -> (readings: [StoreReading], sleep: [StoreSleepSpan]) {
        let start = now.addingTimeInterval(-Self.retentionWindow)
        let end = now.addingTimeInterval(0.001)
        let readings = try await database.samples(from: start, to: end).map(StoreReading.init)
        let events = try await database.events(from: start, to: end)
        return (readings, StoreSleepSpan.observedSpans(from: events))
    }

    func append(_ reading: StoreReading, sleep: [StoreSleepSpan]) async throws -> Bool {
        try await database.save(sample: reading.sample, processes: [], events: sleep.flatMap(\.events))
    }

    static func csv(readings: [StoreReading], sleep: [StoreSleepSpan]) -> String {
        let dates = ISO8601DateFormatter()
        var rows: [(Date, String)] = readings.map { reading in
            let fields = [
                dates.string(from: reading.timestamp),
                "sample",
                reading.cpuPercent.map { String($0) } ?? "",
                reading.memoryUsed.map { String($0) } ?? "",
                reading.memoryTotal.map { String($0) } ?? "",
                reading.batteryPercent.map { String($0) } ?? "",
                reading.powerSource.rawValue,
                reading.isCharging.map { String($0) } ?? "",
                reading.thermal.rawValue
            ]
            return (reading.timestamp, fields.joined(separator: ","))
        }
        for span in sleep {
            rows.append((span.start, dates.string(from: span.start) + ",sleep,,,,,,,"))
            rows.append((span.end, dates.string(from: span.end) + ",wake,,,,,,,"))
        }
        let header = "timestamp_utc,event,cpu_percent,memory_used_bytes,memory_total_bytes,battery_percent,power_source,charging,thermal_pressure"
        return ([header] + rows.sorted { $0.0 < $1.0 }.map(\.1)).joined(separator: "\n") + "\n"
    }
}
