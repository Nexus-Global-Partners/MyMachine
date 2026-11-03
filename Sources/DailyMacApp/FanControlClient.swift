import Combine
import AppKit
import DailyMacCore
import Darwin
import Foundation
import ServiceManagement

enum FanControlAvailability: Equatable {
    case checking
    case unsupported(String)
    case notEnabled
    case needsApproval
    case enabled
}

@MainActor
final class FanControlClient: ObservableObject {
    static let shared = FanControlClient()
    @Published private(set) var snapshot: FanControlSnapshot?
    @Published private(set) var availability: FanControlAvailability = .checking
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var requestInFlight = false
    private var generation = 0
    private var connectionToken = UUID()

    private var service: SMAppService { .daemon(plistName: FanControlServiceIdentity.plistName) }

    private init() {}

    /// Read-only. Merely opening a popover never registers the privileged service.
    func refresh() {
        guard !requestInFlight else { return }
        guard FanControlInstallation.isProvisioned else {
            let reason = FanControlInstallation.isOfficialLocation
                ? "Fan setup is incomplete. Run the official installer again."
                : "Manual fan control requires the official signed MY MACHINE installer."
            availability = .unsupported(reason)
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let client = self else { return }
                Task { @MainActor in client.poll() }
            }
        }
        poll()
        if availability == .notEnabled || availability == .needsApproval { probeReadOnly() }
    }

    func enable() {
        guard !isBusy else { return }
        errorMessage = nil
        do {
            try FanControlInstallation.verify()
            if service.status == .notRegistered { try service.register() }
            poll()
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setPercent(_ percent: Double) {
        guard availability == .enabled, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            defer { isBusy = false }
            do { snapshot = try await request { $0.setAllFans(percent: percent, withReply: $1) } }
            catch { invalidateUnconfirmedControl(error) }
        }
    }

    func returnToAutomatic() {
        guard availability == .enabled, !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do { snapshot = try await request { $0.automatic(withReply: $1) }; errorMessage = nil }
            catch { invalidateUnconfirmedControl(error) }
        }
    }

    func disable() {
        guard !isBusy else { return }
        errorMessage = nil
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try FanControlInstallation.verify()
                if service.status == .enabled {
                    // The helper refuses further manual requests on every
                    // connection until the service exits.
                    _ = try await request { $0.prepareToUnregister(withReply: $1) }
                }
                try await service.unregister()
                shutdown()
                snapshot = nil
                availability = .notEnabled
                errorMessage = nil
            } catch {
                invalidateUnconfirmedControl(error)
            }
        }
    }

    func shutdown() {
        generation += 1
        connectionToken = UUID()
        timer?.invalidate(); timer = nil
        connection?.invalidate(); connection = nil
        // Server invalidation restores immediately. Its independent 20-second
        // lease and durable recovery journal also cover an abrupt client exit.
    }

    private func invalidateUnconfirmedControl(_ error: Error) {
        // A lost reply does not prove no write occurred. Disconnect the lease
        // so the independent helper restores instead of retaining an unknown target.
        errorMessage = error.localizedDescription
        snapshot = nil
        connectionToken = UUID()
        connection?.invalidate(); connection = nil
    }

    private func probeReadOnly() {
        let expectedGeneration = generation
        requestInFlight = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<FanControlSnapshot, Error> in
                Result { try FanControlEngine().readState() }
            }.value
            requestInFlight = false
            guard generation == expectedGeneration else { return }
            switch result {
            case .success(let reading): snapshot = reading
            case .failure(let error): snapshot = nil; availability = .unsupported(error.localizedDescription)
            }
        }
    }

    private func poll() {
        guard !requestInFlight, !isBusy else { return }
        switch service.status {
        case .enabled:
            break
        case .notRegistered, .requiresApproval:
            if availability == .enabled {
                invalidateUnconfirmedControl(FanControlError.unavailable("Fan control approval changed."))
            }
            availability = service.status == .requiresApproval ? .needsApproval : .notEnabled
            return
        default:
            availability = .unsupported("The signed fan service is unavailable. Reinstall the official package.")
            return
        }
        requestInFlight = true
        Task {
            defer { requestInFlight = false }
            do {
                let remote = try proxy()
                if snapshot?.ownsManualControl == true { remote.heartbeat { _ in } }
                snapshot = try await request { $0.status(withReply: $1) }
                availability = .enabled
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                snapshot = nil // Never leave a confirmed-looking slider on a dead helper.
                availability = .unsupported("The approved helper is not responding. Run the official installer to repair fan control.")
                connection?.invalidate(); connection = nil; connectionToken = UUID()
            }
        }
    }

    private func proxy() throws -> FanControlServiceProtocol {
        if connection == nil {
            let identity = try FanControlServiceIdentity.ownRequirement()
            let candidate = NSXPCConnection(machServiceName: FanControlServiceIdentity.name, options: .privileged)
            candidate.setCodeSigningRequirement(identity)
            candidate.remoteObjectInterface = NSXPCInterface(with: FanControlServiceProtocol.self)
            let expectedGeneration = generation
            let token = UUID()
            connectionToken = token
            let invalidated: () -> Void = { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == expectedGeneration, self.connectionToken == token else { return }
                    self.connectionToken = UUID()
                    self.connection = nil
                    self.snapshot = nil
                    self.errorMessage = "Fan helper disconnected. Automatic restoration is handled by its watchdog."
                }
            }
            candidate.interruptionHandler = invalidated
            candidate.invalidationHandler = invalidated
            connection = candidate
            candidate.resume()
        }
        guard let remote = connection?.remoteObjectProxy as? FanControlServiceProtocol else {
            throw FanControlError.unavailable("The approved fan helper is not connected.")
        }
        return remote
    }

    private func request(_ operation: (FanControlServiceProtocol, @escaping (Data?, String?) -> Void) -> Void) async throws -> FanControlSnapshot {
        _ = try proxy()
        guard let connection else { throw FanControlError.unavailable("Fan helper is unavailable.") }
        let token = connectionToken
        let expectedGeneration = generation
        let result: FanControlSnapshot = try await withCheckedThrowingContinuation { continuation in
            let reply = FanControlReply(continuation)
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in reply.fail(error) }) as? FanControlServiceProtocol else {
                reply.fail(FanControlError.unavailable("Fan helper is unavailable.")); return
            }
            operation(remote) { data, error in
                if let error { reply.fail(FanControlError.operationFailed(error)); return }
                guard let data, data.count <= 65_536 else { reply.fail(FanControlError.unavailable("Fan helper returned an invalid response.")); return }
                do { reply.succeed(try JSONDecoder().decode(FanControlSnapshot.self, from: data)) }
                catch { reply.fail(error) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                reply.fail(FanControlError.unavailable("Fan helper did not respond. No fan change is confirmed."))
            }
        }
        guard expectedGeneration == generation, token == connectionToken else {
            throw FanControlError.unavailable("Fan helper changed before the operation was confirmed.")
        }
        return result
    }
}

/// XPC error, reply, and timeout can race; a continuation must resume only once.
private final class FanControlReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FanControlSnapshot, Error>?
    init(_ continuation: CheckedContinuation<FanControlSnapshot, Error>) { self.continuation = continuation }
    func succeed(_ result: FanControlSnapshot) { finish(.success(result)) }
    func fail(_ error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<FanControlSnapshot, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
