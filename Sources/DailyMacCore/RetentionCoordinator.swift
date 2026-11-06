import Foundation

enum RetentionError: Error { case inputsChanged }

/// Enforces the data-safety ordering: raw input is never expired until every
/// required aggregate has been saved successfully.
public enum RetentionCoordinator {
    @MainActor
    public static func finalizeThenRetain(
        store: SQLiteStore,
        settings: MonitoringSettings,
        finalize: @MainActor () async throws -> Void
    ) async throws {
        let now = Date()
        for attempt in 0..<3 {
            let revision = await store.currentTelemetryRevision()
            try await finalize()
            do {
                try await store.performRetention(settings: settings, now: now, ifTelemetryRevision: revision)
                return
            } catch RetentionError.inputsChanged {
                guard attempt < 2 else { throw StoreError.write("Local history changed before retention could be verified.") }
                try await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
            }
        }
    }
}
