import DailyMacCore
import Foundation
import SQLite3

enum StorageMaintenanceValidation {
    static func run(harness: ValidationHarness) async {
        await harness.run("retention reclaims material legacy fragmentation without losing retained data") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MyMachine-Storage-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            let database = directory.appendingPathComponent("DailyMac.sqlite")
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var settings = MonitoringSettings.default
            settings.baseSamplingInterval = 30
            try await store.saveSettings(settings)
            let event = ActivityEvent(timestamp: now, type: .note, title: "Retained sentinel", explanation: "Synthetic storage fixture", severity: .information)
            try await store.save(event: event)

            try await store.performRetention(settings: settings, now: now)
            let initialAttempts = try scalar(database, "SELECT count(*) FROM metadata WHERE key='storageMaintenanceLastAttempt';")
            try harness.check(initialAttempts == 0,
                              "small healthy store incurred a maintenance attempt")

            // A legacy NONE-mode store retains free pages after old data leaves.
            // The synthetic blob contains only zeros, never copied user data.
            try execute(database, "PRAGMA auto_vacuum=NONE; VACUUM;")
            try fragment(database)
            let originalPages = try scalar(database, "PRAGMA page_count;")
            let originalFree = try scalar(database, "PRAGMA freelist_count;")
            let pageSize = try scalar(database, "PRAGMA page_size;")
            try harness.check(originalFree * pageSize >= 32 * 1_024 * 1_024, "fixture did not create material fragmentation")

            let expiredEvent = ActivityEvent(timestamp: now.addingTimeInterval(-4 * 86_400), type: .appLaunched, title: "Expired fixture", explanation: "Synthetic storage fixture", severity: .information)
            try await store.save(event: expiredEvent)
            try execute(database, "CREATE TRIGGER reject_maintenance BEFORE INSERT ON metadata WHEN NEW.key='storageMaintenanceLastAttempt' BEGIN SELECT RAISE(FAIL,'synthetic maintenance failure'); END;")
            try await store.performRetention(settings: settings, now: now)
            let afterFailedMaintenance = try await store.events(from: now.addingTimeInterval(-5 * 86_400), to: now.addingTimeInterval(1))
            try harness.check(!afterFailedMaintenance.contains(where: { $0.id == expiredEvent.id })
                              && afterFailedMaintenance.contains(where: { $0.id == event.id }),
                              "maintenance failure prevented logical retention or damaged the sentinel")
            try execute(database, "DROP TRIGGER reject_maintenance;")

            try await store.performRetention(settings: settings, now: now)
            let compactPages = try scalar(database, "PRAGMA page_count;")
            try harness.check(compactPages < originalPages / 2, "legacy database did not shrink")
            let migratedMode = try scalar(database, "PRAGMA auto_vacuum;")
            try harness.check(migratedMode == 2, "legacy store was not migrated to incremental reclamation")
            let retainedEvents = try await store.events(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
            let retainedSettings = try await store.loadSettings()
            try harness.check(retainedEvents.contains(where: { $0.id == event.id }) && retainedSettings.baseSamplingInterval == 30,
                              "compaction altered retained history or preferences")
            let integrityIssues = try scalar(database, "SELECT count(*) FROM pragma_integrity_check WHERE integrity_check != 'ok';")
            try harness.check(integrityIssues == 0, "compaction damaged the database")

            try fragment(database)
            let freeBeforeCooldown = try scalar(database, "PRAGMA freelist_count;")
            try await store.performRetention(settings: settings, now: now.addingTimeInterval(60))
            let freeDuringCooldown = try scalar(database, "PRAGMA freelist_count;")
            try harness.check(freeDuringCooldown == freeBeforeCooldown,
                              "maintenance was repeated inside the weekly cooldown")

            try await store.performRetention(settings: settings, now: now.addingTimeInterval(8 * 86_400))
            let freeAfterIncremental = try scalar(database, "PRAGMA freelist_count;")
            try harness.check(freeAfterIncremental < freeBeforeCooldown, "incremental maintenance reclaimed no pages")
            try harness.check((freeBeforeCooldown - freeAfterIncremental) * pageSize <= 32 * 1_024 * 1_024,
                              "incremental maintenance exceeded the 32 MiB page budget")
            let finalMode = try scalar(database, "PRAGMA auto_vacuum;")
            try harness.check(finalMode == 2,
                              "incremental maintenance reverted the storage mode")
        }
    }

    private static func fragment(_ database: URL) throws {
        try execute(database, "INSERT INTO metadata(key,value) VALUES('zero-storage-fixture',zeroblob(41943040)); DELETE FROM metadata WHERE key='zero-storage-fixture'; PRAGMA wal_checkpoint(TRUNCATE);")
    }

    private static func execute(_ database: URL, _ sql: String) throws {
        try withConnection(database) { connection in
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
                throw ValidationFailure.failed(String(cString: sqlite3_errmsg(connection)))
            }
        }
    }

    private static func scalar(_ database: URL, _ sql: String) throws -> Int64 {
        try withConnection(database) { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw ValidationFailure.failed("fixture query failed") }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ValidationFailure.failed("fixture query returned no row") }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private static func withConnection<T>(_ database: URL, _ action: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let connection else { throw ValidationFailure.failed("fixture database unavailable") }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)
        return try action(connection)
    }
}
