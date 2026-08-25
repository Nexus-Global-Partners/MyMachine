import Foundation

/// Enforces the data-safety ordering: raw input is never expired until every
/// required aggregate has been saved successfully.
public enum RetentionCoordinator {
    @MainActor
    public static func finalizeThenRetain(
        store: SQLiteStore,
        settings: MonitoringSettings,
        finalize: @MainActor () async throws -> Void
    ) async throws {
        try await finalize()
        try await store.performRetention(settings: settings)
    }
}
