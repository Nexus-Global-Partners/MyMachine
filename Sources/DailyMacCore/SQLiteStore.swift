import Foundation
import SQLite3
import Darwin

public enum StoreError: LocalizedError {
    case cannotOpen(String)
    case statement(String)
    case write(String)
    case cleanupIncomplete

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let detail): return "MY MACHINE could not open its local data store: \(detail)"
        case .statement(let detail): return "MY MACHINE could not prepare a local database operation: \(detail)"
        case .write(let detail): return "MY MACHINE could not save local monitoring data: \(detail)"
        case .cleanupIncomplete: return "Local history cleanup could not finish. Close tools reading the database and reopen MY MACHINE, or retry Delete All Collected Data if you were deleting history. Separate backups and exports are not removed."
        }
    }
}

public actor SQLiteStore {
    public nonisolated let directoryURL: URL
    public nonisolated let databaseURL: URL

    private var db: OpaquePointer?
    private var dataGeneration: UInt64 = 0
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directoryURL: URL? = nil) throws {
        let requested = (directoryURL ?? SQLiteStore.defaultDirectoryURL()).standardizedFileURL
        if directoryURL == nil {
            try Self.migrateLegacyDirectoryIfNeeded(to: requested)
        }
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.securePath(requested, directory: true)
        // SQLite NOFOLLOW also rejects symlinked ancestors. Resolve system aliases
        // only after verifying that the selected store itself is not a symlink.
        guard let resolved = realpath(requested.path, nil) else {
            throw StoreError.cannotOpen("Storage location could not be resolved")
        }
        defer { free(resolved) }
        let selected = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        self.directoryURL = selected
        self.databaseURL = selected.appendingPathComponent("DailyMac.sqlite", isDirectory: false)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970

        try Self.secureStoreFiles(databaseURL: databaseURL)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw StoreError.cannotOpen(detail)
        }
        var opened = handle
        _ = sqlite3_busy_timeout(opened, 5_000)
        var healthy = true
        do {
            try Self.configure(opened)
            healthy = try Self.quickCheck(opened)
        } catch {
            if Self.isCorruptionCode(sqlite3_errcode(opened)) {
                healthy = false
            } else {
                sqlite3_close(opened)
                throw error
            }
        }
        if !healthy {
            sqlite3_close(opened)
            try Self.preserveCorruptStore(databaseURL: databaseURL, directoryURL: selected)
            var replacement: OpaquePointer?
            guard sqlite3_open_v2(databaseURL.path, &replacement, flags, nil) == SQLITE_OK, let replacement else {
                let detail = replacement.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown recovery error"
                if let replacement { sqlite3_close(replacement) }
                throw StoreError.cannotOpen(detail)
            }
            opened = replacement
            _ = sqlite3_busy_timeout(opened, 5_000)
            try Self.configure(opened)
        }
        db = opened
        try Self.createSchema(opened)
        try Self.secureStoreFiles(databaseURL: databaseURL)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public static func defaultDirectoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["DAILYMAC_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MY MACHINE", isDirectory: true)
    }

    private static func migrateLegacyDirectoryIfNeeded(to destination: URL) throws {
        let manager = FileManager.default
        let legacy = destination.deletingLastPathComponent().appendingPathComponent("Daily Mac", isDirectory: true)
        guard !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: legacy.path) else { return }
        try manager.moveItem(at: legacy, to: destination)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    }

    public func currentDataGeneration() -> UInt64 { dataGeneration }

    @discardableResult
    public func save(
        sample: SystemSample,
        processes: [ProcessSample],
        appResources: [AppResourceSample] = [],
        events: [ActivityEvent] = [],
        ifDataGeneration expectedGeneration: UInt64? = nil
    ) throws -> Bool {
        if let expectedGeneration, expectedGeneration != dataGeneration { return false }
        try transaction {
            try insert(sample)
            for process in processes { try insert(process) }
            for resource in appResources { try insert(resource) }
            for event in events { try insert(event) }
        }
        return true
    }

    @discardableResult
    public func save(event: ActivityEvent, ifDataGeneration expectedGeneration: UInt64? = nil) throws -> Bool {
        if let expectedGeneration, expectedGeneration != dataGeneration { return false }
        try insert(event)
        return true
    }

    @discardableResult
    public func save(report: DailyReport, ifDataGeneration expectedGeneration: UInt64? = nil) throws -> Bool {
        if let expectedGeneration, expectedGeneration != dataGeneration { return false }
        guard let db else { throw StoreError.write("database is closed") }
        let sql = """
        INSERT INTO daily_reports(day_key, generated_at, timezone_id, report_json)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(day_key) DO UPDATE SET
          generated_at=excluded.generated_at,
          timezone_id=excluded.timezone_id,
          report_json=excluded.report_json;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(report.dayKey, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, report.generatedAt.timeIntervalSince1970)
        bind(report.timezoneIdentifier, to: 3, in: statement)
        let json = String(data: try encoder.encode(report), encoding: .utf8) ?? "{}"
        bind(json, to: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.write(String(cString: sqlite3_errmsg(db))) }
        return true
    }

    public func samples(from start: Date, to end: Date) throws -> [SystemSample] {
        try readSamples(
            from: start,
            to: end,
            predicate: "timestamp >= ? AND timestamp < ?"
        )
    }

    /// Reads samples whose measured interval ends inside a rolling window. A sample ending
    /// exactly at the start belongs to the preceding window, while one ending at `end` is
    /// included. Callers clip the first sample's duration to the window boundary.
    public func samples(in interval: DateInterval) throws -> [SystemSample] {
        try readSamples(
            from: interval.start,
            to: interval.end,
            predicate: "timestamp > ? AND timestamp <= ?"
        )
    }

    private func readSamples(from start: Date, to end: Date, predicate: String) throws -> [SystemSample] {
        let statement = try prepare("""
        SELECT id, timestamp, duration, foreground_app, foreground_bundle, category, is_idle,
               cpu_percent, load_1m, load_5m, memory_used, memory_total, memory_pressure,
               swap_used, thermal, battery_percent, power_source, is_charging,
               disk_read, disk_write, network_received, network_sent,
               monitor_cpu, monitor_memory, monitor_disk_write, sampling_interval,
               keyboard_events, pointer_events, click_events, scroll_events,
               gpu_percent, performance_core_percent, efficiency_core_percent,
               performance_core_contribution
        FROM system_samples WHERE \(predicate) ORDER BY timestamp;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var result: [SystemSample] = []
        while try nextRow(statement) {
            guard let id = UUID(uuidString: text(statement, 0)),
                  let category = WorkCategory(rawValue: text(statement, 5)),
                  let pressure = MemoryPressureLevel(rawValue: text(statement, 12)),
                  let thermal = ThermalLevel(rawValue: text(statement, 14)),
                  let power = PowerSource(rawValue: text(statement, 16)) else { continue }
            let battery: Double? = sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 15)
            let charging: Bool? = sqlite3_column_type(statement, 17) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 17) != 0
            let gpu: Double? = sqlite3_column_type(statement, 30) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 30)
            let performanceCore: Double? = sqlite3_column_type(statement, 31) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 31)
            let efficiencyCore: Double? = sqlite3_column_type(statement, 32) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 32)
            let performanceContribution: Double? = sqlite3_column_type(statement, 33) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 33)
            let manualActivity: ManualActivityCounts? = {
                guard sqlite3_column_type(statement, 26) != SQLITE_NULL,
                      sqlite3_column_type(statement, 27) != SQLITE_NULL,
                      sqlite3_column_type(statement, 28) != SQLITE_NULL,
                      sqlite3_column_type(statement, 29) != SQLITE_NULL else { return nil }
                return ManualActivityCounts(
                    keyboardEvents: uint64(statement, 26),
                    pointerEvents: uint64(statement, 27),
                    clickEvents: uint64(statement, 28),
                    scrollEvents: uint64(statement, 29)
                )
            }()
            result.append(SystemSample(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                duration: sqlite3_column_double(statement, 2),
                foregroundApp: text(statement, 3),
                foregroundBundleID: optionalText(statement, 4),
                category: category,
                isIdle: sqlite3_column_int(statement, 6) != 0,
                cpuPercent: sqlite3_column_double(statement, 7),
                performanceCorePercent: performanceCore,
                efficiencyCorePercent: efficiencyCore,
                performanceCoreContributionPercent: performanceContribution,
                gpuPercent: gpu,
                loadAverage1m: sqlite3_column_double(statement, 8),
                loadAverage5m: sqlite3_column_double(statement, 9),
                memoryUsedBytes: uint64(statement, 10),
                memoryTotalBytes: uint64(statement, 11),
                memoryPressure: pressure,
                swapUsedBytes: uint64(statement, 13),
                thermalLevel: thermal,
                batteryPercent: battery,
                powerSource: power,
                isCharging: charging,
                diskReadBytes: uint64(statement, 18),
                diskWriteBytes: uint64(statement, 19),
                networkReceivedBytes: uint64(statement, 20),
                networkSentBytes: uint64(statement, 21),
                monitorCPUPercent: sqlite3_column_double(statement, 22),
                monitorMemoryBytes: uint64(statement, 23),
                monitorDiskWriteBytes: uint64(statement, 24),
                samplingInterval: sqlite3_column_double(statement, 25),
                manualActivity: manualActivity
            ))
        }
        return result
    }

    public func processSamples(from start: Date, to end: Date) throws -> [ProcessSample] {
        try readProcessSamples(from: start, to: end, predicate: "timestamp >= ? AND timestamp < ?")
    }

    public func processSamples(in interval: DateInterval) throws -> [ProcessSample] {
        try readProcessSamples(from: interval.start, to: interval.end, predicate: "timestamp > ? AND timestamp <= ?")
    }

    private func readProcessSamples(from start: Date, to end: Date, predicate: String) throws -> [ProcessSample] {
        let statement = try prepare("""
        SELECT id, timestamp, pid, process_start, name, bundle_id,
               parent_pid, owner_name, owner_bundle_id, owner_relation, is_foreground,
               cpu_percent, memory_bytes, disk_read, disk_write, energy_nj
        FROM process_samples WHERE \(predicate) ORDER BY timestamp;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var result: [ProcessSample] = []
        while try nextRow(statement) {
            guard let id = UUID(uuidString: text(statement, 0)) else { continue }
            let parentPID: Int32? = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Int32(sqlite3_column_int(statement, 6))
            let relation = optionalText(statement, 9).flatMap(ProcessOwnerRelation.init(rawValue:))
            let energy: UInt64? = sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil : uint64(statement, 15)
            result.append(ProcessSample(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                processID: Int32(sqlite3_column_int(statement, 2)),
                processStart: uint64(statement, 3),
                name: text(statement, 4),
                bundleID: optionalText(statement, 5),
                isForeground: sqlite3_column_int(statement, 10) != 0,
                cpuPercent: sqlite3_column_double(statement, 11),
                memoryBytes: uint64(statement, 12),
                diskReadBytes: uint64(statement, 13),
                diskWriteBytes: uint64(statement, 14),
                energyNanojoules: energy,
                parentProcessID: parentPID,
                ownerName: optionalText(statement, 7),
                ownerBundleID: optionalText(statement, 8),
                ownerRelation: relation
            ))
        }
        return result
    }

    public func appResourceSamples(in interval: DateInterval) throws -> [AppResourceSample] {
        let statement = try prepare("""
        SELECT id, timestamp, duration, owner_name, owner_bundle_id, is_foreground,
               cpu_percent, memory_bytes, disk_read, disk_write,
               process_count, worker_count, agent_worker_count, worker_names
        FROM app_resource_samples
        WHERE timestamp > ? AND timestamp <= ?
        ORDER BY timestamp;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
        var result: [AppResourceSample] = []
        while try nextRow(statement) {
            guard let id = UUID(uuidString: text(statement, 0)) else { continue }
            let workerNames: [String]
            if let data = text(statement, 13).data(using: .utf8),
               let decoded = try? decoder.decode([String].self, from: data) {
                workerNames = decoded
            } else {
                workerNames = []
            }
            result.append(AppResourceSample(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                duration: sqlite3_column_double(statement, 2),
                ownerName: text(statement, 3),
                ownerBundleID: optionalText(statement, 4),
                isForeground: sqlite3_column_int(statement, 5) != 0,
                cpuPercent: sqlite3_column_double(statement, 6),
                memoryBytes: uint64(statement, 7),
                diskReadBytes: uint64(statement, 8),
                diskWriteBytes: uint64(statement, 9),
                processCount: Int(sqlite3_column_int(statement, 10)),
                workerCount: Int(sqlite3_column_int(statement, 11)),
                agentWorkerCount: Int(sqlite3_column_int(statement, 12)),
                workerNames: workerNames
            ))
        }
        return result
    }

    public func events(from start: Date, to end: Date) throws -> [ActivityEvent] {
        let statement = try prepare("""
        SELECT id, timestamp, type, title, explanation, severity
        FROM events WHERE timestamp >= ? AND timestamp < ? ORDER BY timestamp;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var result: [ActivityEvent] = []
        while try nextRow(statement) {
            if let event = activityEvent(from: statement) { result.append(event) }
        }
        return result
    }

    /// Returns only explicit macOS sleep/wake transitions for a monitoring window.
    /// The most recent transition before the window is included so callers can
    /// establish the state at the leading edge without interpreting a sample gap.
    public func sleepWakeEvents(in interval: DateInterval, includingPrevious: Bool = true) throws -> [ActivityEvent] {
        var result: [ActivityEvent] = []

        if includingPrevious {
            let previous = try prepare("""
            SELECT id, timestamp, type, title, explanation, severity
            FROM events
            WHERE type IN ('sleep', 'wake') AND timestamp < ?
            ORDER BY timestamp DESC LIMIT 1;
            """)
            defer { sqlite3_finalize(previous) }
            sqlite3_bind_double(previous, 1, interval.start.timeIntervalSince1970)
            if try nextRow(previous),
               let event = activityEvent(from: previous) {
                result.append(event)
            }
        }

        let window = try prepare("""
        SELECT id, timestamp, type, title, explanation, severity
        FROM events
        WHERE type IN ('sleep', 'wake') AND timestamp >= ? AND timestamp <= ?
        ORDER BY timestamp;
        """)
        defer { sqlite3_finalize(window) }
        sqlite3_bind_double(window, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(window, 2, interval.end.timeIntervalSince1970)
        while try nextRow(window) {
            if let event = activityEvent(from: window) { result.append(event) }
        }

        return result
    }

    public func report(dayKey: String) throws -> DailyReport? {
        let statement = try prepare("SELECT report_json FROM daily_reports WHERE day_key = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(dayKey, to: 1, in: statement)
        guard try nextRow(statement),
              let data = text(statement, 0).data(using: .utf8) else { return nil }
        return try decoder.decode(DailyReport.self, from: data)
    }

    public func reports(limit: Int = 365) throws -> [DailyReport] {
        let statement = try prepare("SELECT report_json FROM daily_reports ORDER BY day_key DESC LIMIT ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
        var result: [DailyReport] = []
        while try nextRow(statement) {
            guard let data = text(statement, 0).data(using: .utf8) else {
                throw StoreError.statement("A retained report could not be read safely")
            }
            let report = try decoder.decode(DailyReport.self, from: data)
            result.append(report)
        }
        return result
    }

    public func latestSample() throws -> SystemSample? {
        let statement = try prepare("SELECT timestamp FROM system_samples ORDER BY timestamp DESC LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        guard try nextRow(statement) else { return nil }
        let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        return try samples(from: date.addingTimeInterval(-0.001), to: date.addingTimeInterval(0.001)).first
    }

    public func latestProcessImpacts(limit: Int = 8) throws -> [ProcessImpact] {
        let statement = try prepare("""
        SELECT timestamp, pid, name, owner_name, owner_bundle_id, owner_relation,
               cpu_percent, memory_bytes, disk_read + disk_write, is_foreground
        FROM process_samples
        WHERE timestamp = (SELECT MAX(timestamp) FROM process_samples)
          AND (cpu_percent >= 50 OR memory_bytes >= 2000000000 OR disk_read + disk_write >= 250000000 OR is_foreground = 1)
        ORDER BY cpu_percent DESC, memory_bytes DESC LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
        var result: [ProcessImpact] = []
        while try nextRow(statement) {
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let pid = Int32(sqlite3_column_int(statement, 1))
            let name = text(statement, 2)
            let ownerName = optionalText(statement, 3)
            let ownerBundleID = optionalText(statement, 4)
            let ownerRelation = optionalText(statement, 5).flatMap(ProcessOwnerRelation.init(rawValue:))
            let cpu = sqlite3_column_double(statement, 6)
            let memory = uint64(statement, 7)
            let disk = uint64(statement, 8)
            let foreground = sqlite3_column_int(statement, 9) != 0
            result.append(ProcessImpact(timestamp: timestamp, name: name, processID: pid, cpuPercent: cpu, memoryBytes: memory, diskBytes: disk, isForeground: foreground, interpretation: PracticalInterpreter.process(name: name, cpu: cpu, memory: memory, diskBytes: disk, isForeground: foreground), ownerName: ownerName, ownerBundleID: ownerBundleID, ownerRelation: ownerRelation))
        }
        return result
    }

    public func sampleTimestamps(before end: Date) throws -> [Date] {
        let statement = try prepare("SELECT timestamp FROM system_samples WHERE timestamp < ? ORDER BY timestamp;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, end.timeIntervalSince1970)
        var result: [Date] = []
        while try nextRow(statement) {
            result.append(Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)))
        }
        return result
    }

    public func loadSettings() throws -> MonitoringSettings {
        let statement = try prepare("SELECT value FROM metadata WHERE key = 'settings' LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        guard try nextRow(statement) else { return .default }
        guard let data = text(statement, 0).data(using: .utf8) else {
            throw StoreError.statement("Settings could not be read safely")
        }
        return try decoder.decode(MonitoringSettings.self, from: data)
    }

    public func saveSettings(_ settings: MonitoringSettings) throws {
        let json = String(data: try encoder.encode(settings), encoding: .utf8) ?? "{}"
        let statement = try prepare("INSERT INTO metadata(key, value) VALUES('settings', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
        defer { sqlite3_finalize(statement) }
        bind(json, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.write(lastError()) }
    }

    public func databaseSizeBytes() -> UInt64 {
        let urls = [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")]
        return urls.reduce(0) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            return partial + size
        }
    }

    public func performRetention(settings: MonitoringSettings, now: Date = Date()) throws {
        let rawDays = min(max(1, settings.rawRetentionDays), settings.effectiveNamedHistoryRetentionDays)
        let rawCutoff = now.addingTimeInterval(-Double(rawDays) * 86_400)
        let eventCutoff = now.addingTimeInterval(-Double(max(1, settings.eventRetentionDays)) * 86_400)
        let reportCutoff = now.addingTimeInterval(-Double(max(1, settings.reportRetentionDays)) * 86_400)
        let namedCutoff = now.addingTimeInterval(-Double(settings.effectiveNamedHistoryRetentionDays) * 86_400)
        try transaction {
            try execute("DELETE FROM app_resource_samples WHERE timestamp < \(rawCutoff.timeIntervalSince1970);")
            try execute("DELETE FROM process_samples WHERE timestamp < \(rawCutoff.timeIntervalSince1970);")
            try execute("DELETE FROM system_samples WHERE timestamp < \(rawCutoff.timeIntervalSince1970);")
            try execute("DELETE FROM events WHERE timestamp < \(rawCutoff.timeIntervalSince1970) AND type IN ('appLaunched','appQuit','foregroundChanged');")
            try execute("DELETE FROM events WHERE timestamp < \(eventCutoff.timeIntervalSince1970);")
            try execute("DELETE FROM daily_reports WHERE generated_at < \(reportCutoff.timeIntervalSince1970);")
            // Older performance events may also contain foreground names in prose.
            let events = try prepare("UPDATE events SET title = ?, explanation = ? WHERE timestamp < ?;")
            defer { sqlite3_finalize(events) }
            bind("Historical machine event", to: 1, in: events)
            bind("Original details expired under your named-history retention settings.", to: 2, in: events)
            sqlite3_bind_double(events, 3, namedCutoff.timeIntervalSince1970)
            guard sqlite3_step(events) == SQLITE_DONE else { throw StoreError.write(lastError()) }
            // Reports can embed names in prose, not only in the applications array.
            let statement = try prepare("SELECT report_json FROM daily_reports WHERE day_key < ?;")
            defer { sqlite3_finalize(statement) }
            bind(DayBoundaries.key(for: namedCutoff), to: 1, in: statement)
            var expired: [DailyReport] = []
            while try nextRow(statement) {
                guard let data = text(statement, 0).data(using: .utf8) else {
                    throw StoreError.statement("A retained report could not be read safely")
                }
                let report = try decoder.decode(DailyReport.self, from: data)
                if report.applicationDetailsRemoved != true { expired.append(report) }
            }
            for report in expired {
                try save(report: ReportPrivacy.removingApplicationDetails(from: report))
            }
        }
        try removeRecoveryArchives(olderThan: rawCutoff)
        try truncateJournal()
    }

    public func eraseAllData() throws {
        dataGeneration &+= 1
        try transaction {
            try execute("DELETE FROM app_resource_samples;")
            try execute("DELETE FROM process_samples;")
            try execute("DELETE FROM system_samples;")
            try execute("DELETE FROM events;")
            try execute("DELETE FROM daily_reports;")
        }
        // Recovery folders contain the same private telemetry as the active
        // store. An explicit erase must cover them as well.
        try removeRecoveryArchives(olderThan: nil)

        do {
            try truncateJournal()
            try execute("VACUUM;")
            // VACUUM itself writes to the WAL: verify cleanup after it as well.
            try truncateJournal()
        } catch {
            throw StoreError.cleanupIncomplete
        }
    }

    private func truncateJournal() throws {
        guard let db else { throw StoreError.cleanupIncomplete }
        let result = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard result == SQLITE_OK else { throw StoreError.cleanupIncomplete }
    }

    /// Never turn a read failure into an empty or partial history.
    private func nextRow(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StoreError.statement(lastError())
        }
    }

    private func removeRecoveryArchives(olderThan cutoff: Date?) throws {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let contents = try manager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        for url in contents where url.lastPathComponent.hasPrefix("Recovery-") {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isDirectory == true else { continue }
            if let cutoff,
               let modified = values.contentModificationDate,
               modified >= cutoff {
                continue
            }
            try manager.removeItem(at: url)
        }
    }

    private func insert(_ sample: SystemSample) throws {
        let statement = try prepare("""
        INSERT OR IGNORE INTO system_samples(
          id, timestamp, duration, foreground_app, foreground_bundle, category, is_idle,
          cpu_percent, load_1m, load_5m, memory_used, memory_total, memory_pressure,
          swap_used, thermal, battery_percent, power_source, is_charging,
          disk_read, disk_write, network_received, network_sent,
          monitor_cpu, monitor_memory, monitor_disk_write, sampling_interval,
          keyboard_events, pointer_events, click_events, scroll_events,
          gpu_percent, performance_core_percent, efficiency_core_percent,
          performance_core_contribution
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(sample.id.uuidString, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, sample.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, sample.duration)
        bind(sample.foregroundApp, to: 4, in: statement)
        bindOptional(sample.foregroundBundleID, to: 5, in: statement)
        bind(sample.category.rawValue, to: 6, in: statement)
        sqlite3_bind_int(statement, 7, sample.isIdle ? 1 : 0)
        sqlite3_bind_double(statement, 8, sample.cpuPercent)
        sqlite3_bind_double(statement, 9, sample.loadAverage1m)
        sqlite3_bind_double(statement, 10, sample.loadAverage5m)
        bind(sample.memoryUsedBytes, to: 11, in: statement)
        bind(sample.memoryTotalBytes, to: 12, in: statement)
        bind(sample.memoryPressure.rawValue, to: 13, in: statement)
        bind(sample.swapUsedBytes, to: 14, in: statement)
        bind(sample.thermalLevel.rawValue, to: 15, in: statement)
        if let value = sample.batteryPercent { sqlite3_bind_double(statement, 16, value) } else { sqlite3_bind_null(statement, 16) }
        bind(sample.powerSource.rawValue, to: 17, in: statement)
        if let value = sample.isCharging { sqlite3_bind_int(statement, 18, value ? 1 : 0) } else { sqlite3_bind_null(statement, 18) }
        bind(sample.diskReadBytes, to: 19, in: statement)
        bind(sample.diskWriteBytes, to: 20, in: statement)
        bind(sample.networkReceivedBytes, to: 21, in: statement)
        bind(sample.networkSentBytes, to: 22, in: statement)
        sqlite3_bind_double(statement, 23, sample.monitorCPUPercent)
        bind(sample.monitorMemoryBytes, to: 24, in: statement)
        bind(sample.monitorDiskWriteBytes, to: 25, in: statement)
        sqlite3_bind_double(statement, 26, sample.samplingInterval)
        if let activity = sample.manualActivity {
            bind(activity.keyboardEvents, to: 27, in: statement)
            bind(activity.pointerEvents, to: 28, in: statement)
            bind(activity.clickEvents, to: 29, in: statement)
            bind(activity.scrollEvents, to: 30, in: statement)
        } else {
            for index in 27...30 { sqlite3_bind_null(statement, Int32(index)) }
        }
        if let value = sample.gpuPercent { sqlite3_bind_double(statement, 31, value) }
        else { sqlite3_bind_null(statement, 31) }
        if let value = sample.performanceCorePercent { sqlite3_bind_double(statement, 32, value) }
        else { sqlite3_bind_null(statement, 32) }
        if let value = sample.efficiencyCorePercent { sqlite3_bind_double(statement, 33, value) }
        else { sqlite3_bind_null(statement, 33) }
        if let value = sample.performanceCoreContributionPercent { sqlite3_bind_double(statement, 34, value) }
        else { sqlite3_bind_null(statement, 34) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.write(lastError()) }
    }

    private func insert(_ sample: ProcessSample) throws {
        let statement = try prepare("""
        INSERT OR IGNORE INTO process_samples(
          id, timestamp, pid, process_start, name, bundle_id,
          parent_pid, owner_name, owner_bundle_id, owner_relation, is_foreground,
          cpu_percent, memory_bytes, disk_read, disk_write, energy_nj
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(sample.id.uuidString, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, sample.timestamp.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, sample.processID)
        bind(sample.processStart, to: 4, in: statement)
        bind(sample.name, to: 5, in: statement)
        bindOptional(sample.bundleID, to: 6, in: statement)
        if let value = sample.parentProcessID { sqlite3_bind_int(statement, 7, value) } else { sqlite3_bind_null(statement, 7) }
        bindOptional(sample.ownerName, to: 8, in: statement)
        bindOptional(sample.ownerBundleID, to: 9, in: statement)
        bindOptional(sample.ownerRelation?.rawValue, to: 10, in: statement)
        sqlite3_bind_int(statement, 11, sample.isForeground ? 1 : 0)
        sqlite3_bind_double(statement, 12, sample.cpuPercent)
        bind(sample.memoryBytes, to: 13, in: statement)
        bind(sample.diskReadBytes, to: 14, in: statement)
        bind(sample.diskWriteBytes, to: 15, in: statement)
        if let value = sample.energyNanojoules { bind(value, to: 16, in: statement) } else { sqlite3_bind_null(statement, 16) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.write(lastError()) }
    }

    private func insert(_ sample: AppResourceSample) throws {
        let statement = try prepare("""
        INSERT OR IGNORE INTO app_resource_samples(
          id, timestamp, duration, owner_name, owner_bundle_id, is_foreground,
          cpu_percent, memory_bytes, disk_read, disk_write,
          process_count, worker_count, agent_worker_count, worker_names
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(sample.id.uuidString, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, sample.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, sample.duration)
        bind(sample.ownerName, to: 4, in: statement)
        bindOptional(sample.ownerBundleID, to: 5, in: statement)
        sqlite3_bind_int(statement, 6, sample.isForeground ? 1 : 0)
        sqlite3_bind_double(statement, 7, sample.cpuPercent)
        bind(sample.memoryBytes, to: 8, in: statement)
        bind(sample.diskReadBytes, to: 9, in: statement)
        bind(sample.diskWriteBytes, to: 10, in: statement)
        sqlite3_bind_int(statement, 11, Int32(sample.processCount))
        sqlite3_bind_int(statement, 12, Int32(sample.workerCount))
        sqlite3_bind_int(statement, 13, Int32(sample.agentWorkerCount))
        let workerJSON = String(data: (try? encoder.encode(sample.workerNames)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        bind(workerJSON, to: 14, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.write(lastError()) }
    }

    private func insert(_ event: ActivityEvent) throws {
        let statement = try prepare("INSERT OR IGNORE INTO events(id, timestamp, type, title, explanation, severity) VALUES(?,?,?,?,?,?);")
        defer { sqlite3_finalize(statement) }
        bind(event.id.uuidString, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
        bind(event.type.rawValue, to: 3, in: statement)
        bind(event.title, to: 4, in: statement)
        bind(event.explanation, to: 5, in: statement)
        sqlite3_bind_int(statement, 6, Int32(event.severity.rawValue))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.write(lastError()) }
    }

    private func activityEvent(from statement: OpaquePointer) -> ActivityEvent? {
        guard let id = UUID(uuidString: text(statement, 0)),
              let type = ActivityEventType(rawValue: text(statement, 2)),
              let severity = EventSeverity(rawValue: Int(sqlite3_column_int(statement, 5))) else { return nil }
        return ActivityEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            type: type,
            title: text(statement, 3),
            explanation: text(statement, 4),
            severity: severity
        )
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw StoreError.statement("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.statement(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw StoreError.write("database is closed") }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw StoreError.write(detail)
        }
    }

    private func lastError() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed" }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bindOptional(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value { bind(value, to: index, in: statement) } else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: UInt64, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, Int64(bitPattern: value))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    private func uint64(_ statement: OpaquePointer, _ column: Int32) -> UInt64 {
        UInt64(bitPattern: sqlite3_column_int64(statement, column))
    }

    private static func configure(_ db: OpaquePointer) throws {
        let settings = [
            "PRAGMA busy_timeout=5000;",
            "PRAGMA journal_mode=WAL;",
            "PRAGMA synchronous=NORMAL;",
            "PRAGMA foreign_keys=ON;",
            "PRAGMA secure_delete=ON;",
            "PRAGMA auto_vacuum=INCREMENTAL;"
        ]
        for sql in settings {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw StoreError.cannotOpen(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func createSchema(_ db: OpaquePointer) throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS metadata(
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS system_samples(
          id TEXT PRIMARY KEY,
          timestamp REAL NOT NULL,
          duration REAL NOT NULL,
          foreground_app TEXT NOT NULL,
          foreground_bundle TEXT,
          category TEXT NOT NULL,
          is_idle INTEGER NOT NULL,
          cpu_percent REAL NOT NULL,
          load_1m REAL NOT NULL,
          load_5m REAL NOT NULL,
          memory_used INTEGER NOT NULL,
          memory_total INTEGER NOT NULL,
          memory_pressure TEXT NOT NULL,
          swap_used INTEGER NOT NULL,
          thermal TEXT NOT NULL,
          battery_percent REAL,
          power_source TEXT NOT NULL,
          is_charging INTEGER,
          disk_read INTEGER NOT NULL,
          disk_write INTEGER NOT NULL,
          network_received INTEGER NOT NULL,
          network_sent INTEGER NOT NULL,
          monitor_cpu REAL NOT NULL,
          monitor_memory INTEGER NOT NULL,
          monitor_disk_write INTEGER NOT NULL,
          sampling_interval REAL NOT NULL,
          keyboard_events INTEGER,
          pointer_events INTEGER,
          click_events INTEGER,
          scroll_events INTEGER,
          gpu_percent REAL,
          performance_core_percent REAL,
          efficiency_core_percent REAL,
          performance_core_contribution REAL
        );
        CREATE INDEX IF NOT EXISTS system_samples_time ON system_samples(timestamp);
        CREATE TABLE IF NOT EXISTS process_samples(
          id TEXT PRIMARY KEY,
          timestamp REAL NOT NULL,
          pid INTEGER NOT NULL,
          process_start INTEGER NOT NULL,
          name TEXT NOT NULL,
          bundle_id TEXT,
          parent_pid INTEGER,
          owner_name TEXT,
          owner_bundle_id TEXT,
          owner_relation TEXT,
          is_foreground INTEGER NOT NULL,
          cpu_percent REAL NOT NULL,
          memory_bytes INTEGER NOT NULL,
          disk_read INTEGER NOT NULL,
          disk_write INTEGER NOT NULL,
          energy_nj INTEGER
        );
        CREATE INDEX IF NOT EXISTS process_samples_time ON process_samples(timestamp);
        CREATE TABLE IF NOT EXISTS app_resource_samples(
          id TEXT PRIMARY KEY,
          timestamp REAL NOT NULL,
          duration REAL NOT NULL,
          owner_name TEXT NOT NULL,
          owner_bundle_id TEXT,
          is_foreground INTEGER NOT NULL,
          cpu_percent REAL NOT NULL,
          memory_bytes INTEGER NOT NULL,
          disk_read INTEGER NOT NULL,
          disk_write INTEGER NOT NULL,
          process_count INTEGER NOT NULL,
          worker_count INTEGER NOT NULL,
          agent_worker_count INTEGER NOT NULL DEFAULT 0,
          worker_names TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS app_resource_samples_time ON app_resource_samples(timestamp);
        CREATE INDEX IF NOT EXISTS app_resource_samples_owner_time ON app_resource_samples(owner_bundle_id, owner_name, timestamp);
        CREATE TABLE IF NOT EXISTS events(
          id TEXT PRIMARY KEY,
          timestamp REAL NOT NULL,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          explanation TEXT NOT NULL,
          severity INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_time ON events(timestamp);
        CREATE TABLE IF NOT EXISTS daily_reports(
          day_key TEXT PRIMARY KEY,
          generated_at REAL NOT NULL,
          timezone_id TEXT NOT NULL,
          report_json TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        try addColumnIfMissing(db, table: "process_samples", column: "parent_pid", definition: "INTEGER")
        try addColumnIfMissing(db, table: "process_samples", column: "owner_name", definition: "TEXT")
        try addColumnIfMissing(db, table: "process_samples", column: "owner_bundle_id", definition: "TEXT")
        try addColumnIfMissing(db, table: "process_samples", column: "owner_relation", definition: "TEXT")
        try addColumnIfMissing(db, table: "system_samples", column: "keyboard_events", definition: "INTEGER")
        try addColumnIfMissing(db, table: "system_samples", column: "pointer_events", definition: "INTEGER")
        try addColumnIfMissing(db, table: "system_samples", column: "click_events", definition: "INTEGER")
        try addColumnIfMissing(db, table: "system_samples", column: "scroll_events", definition: "INTEGER")
        try addColumnIfMissing(db, table: "system_samples", column: "gpu_percent", definition: "REAL")
        try addColumnIfMissing(db, table: "system_samples", column: "performance_core_percent", definition: "REAL")
        try addColumnIfMissing(db, table: "system_samples", column: "efficiency_core_percent", definition: "REAL")
        try addColumnIfMissing(db, table: "system_samples", column: "performance_core_contribution", definition: "REAL")
        guard sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS process_samples_owner_time ON process_samples(owner_bundle_id, owner_name, timestamp); PRAGMA user_version=5;", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func addColumnIfMissing(
        _ db: OpaquePointer,
        table: String,
        column: String,
        definition: String
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1), String(cString: value) == column {
                exists = true
                break
            }
        }
        sqlite3_finalize(statement)
        guard !exists else { return }
        guard sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func quickCheck(_ db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &statement, nil)
        if isCorruptionCode(prepareResult) { return false }
        guard prepareResult == SQLITE_OK, let statement else {
            throw StoreError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        if isCorruptionCode(stepResult) { return false }
        guard stepResult == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw StoreError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        return String(cString: value).lowercased() == "ok"
    }

    private static func isCorruptionCode(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    private static func preserveCorruptStore(databaseURL: URL, directoryURL: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let recovery = directoryURL.appendingPathComponent("Recovery-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for source in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")] where FileManager.default.fileExists(atPath: source.path) {
            let destination = recovery.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    private static func secureStoreFiles(databaseURL: URL) throws {
        for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")] where FileManager.default.fileExists(atPath: url.path) {
            try securePath(url, directory: false)
        }
    }

    private static func securePath(_ url: URL, directory: Bool) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StoreError.cannotOpen("Storage must not be a symbolic link and must be accessible") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else {
            throw StoreError.cannotOpen("Storage must be owned by the current user and use ordinary private files")
        }
        let mode: mode_t = directory ? 0o700 : 0o600
        guard fchmod(descriptor, mode) == 0 else { throw StoreError.cannotOpen("Owner-only storage permissions could not be applied") }
        // Mode bits alone do not override extended ACL grants. Keep restrictive
        // ACLs, but refuse unexpected grants rather than silently changing them.
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin returns ENOENT when this open file has no extended ACL.
            if errno == ENOENT { return }
            throw StoreError.cannotOpen("Storage access rules could not be verified")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var entryID = ACL_FIRST_ENTRY
        while acl_get_entry(acl, entryID.rawValue, &entry) == 0 {
            var tag = ACL_UNDEFINED_TAG
            guard let entry, acl_get_tag_type(entry, &tag) == 0, tag != ACL_EXTENDED_ALLOW else {
                throw StoreError.cannotOpen("Storage has an unexpected extended access grant")
            }
            entryID = ACL_NEXT_ENTRY
        }
    }
}
