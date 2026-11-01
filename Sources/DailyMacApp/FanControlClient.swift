import Combine
import AppKit
import DailyMacCore
import Darwin
import Foundation
import Security

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

    private init() {}

    /// Read-only. Merely opening a popover never registers the privileged service.
    func refresh() {
        guard !requestInFlight else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
        switch installedHelperState() {
        case .enabled:
            availability = .enabled
            poll()
        case .needsApproval:
            availability = .needsApproval
            probeReadOnly()
        case .notEnabled:
            availability = .notEnabled
            probeReadOnly()
        case .checking, .unsupported:
            availability = .notEnabled
            probeReadOnly()
        }
    }

    /// Ad-hoc open-source builds cannot use SMAppService LaunchDaemons (which
    /// require notarization). The explicit installer uses normal administrator
    /// authorization; the monitoring app never supplies credentials itself.
    func enable() {
        guard !isBusy else { return }
        errorMessage = nil
        do {
            _ = try FanControlServiceIdentity.ownRequirement()
            guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/MY MACHINE.app" else {
                throw FanControlError.unavailable("Use the packaged MY MACHINE app to enable fan control.")
            }
            openInstaller(removing: false)
        } catch { errorMessage = error.localizedDescription }
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
                // Do not kill the watchdog until owned fan restoration succeeds.
                if installedHelperState() == .enabled {
                    let current = try await request { $0.status(withReply: $1) }
                    if current.ownsManualControl { snapshot = try await request { $0.automatic(withReply: $1) } }
                }
                openInstaller(removing: true)
            } catch { errorMessage = error.localizedDescription }
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
        let installed = installedHelperState()
        guard installed == .enabled else {
            if availability == .enabled {
                shutdown()
                snapshot = nil
                refresh()
            } else if installed == .needsApproval { availability = .needsApproval }
            return
        }
        availability = .enabled
        guard !requestInFlight, !isBusy else { return }
        requestInFlight = true
        Task {
            defer { requestInFlight = false }
            do {
                let remote = try proxy()
                if snapshot?.ownsManualControl == true { remote.heartbeat { _ in } }
                snapshot = try await request { $0.status(withReply: $1) }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                snapshot = nil // Never leave a confirmed-looking slider on a dead helper.
                availability = .needsApproval // Settings offers repair/reinstall after an unavailable service.
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

    private func openInstaller(removing: Bool) {
        let filename = removing ? "Remove Fan Control.command" : "Install Fan Control.command"
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(filename),
              FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "This app package does not contain the fan-control installer."; return
        }
        let alert = NSAlert()
        alert.messageText = removing ? "Remove fan control?" : "Enable fan control?"
        alert.informativeText = removing
            ? "The administrator installer will restore fans owned by MY MACHINE to Auto, stop the helper, and remove its root-owned copy. Monitoring keeps working."
            : "Fan control needs a one-time administrator installation. The installer copies this signed local app into a protected system folder and installs a narrow fan helper. Your password is entered only in the macOS sudo prompt in Terminal. The helper returns owned fans to Auto after disconnect, sleep, overheating, or lost heartbeat. Setup does not apply a manual fan target. Updates first return any fan control owned by MY MACHINE to Auto."
        alert.addButton(withTitle: "Open Installer")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if NSWorkspace.shared.open(url) {
            availability = .needsApproval
            errorMessage = nil
        } else { errorMessage = "The installer could not be opened. Open \(filename) from this app's Resources folder." }
    }

    private func installedHelperState() -> FanControlAvailability {
        let path = "/Library/PrivilegedHelperTools/local.mymachine.fancontrol.app"
        let plist = "/Library/LaunchDaemons/" + FanControlServiceIdentity.plistName
        for entry in [path, plist] {
            var info = stat()
            guard lstat(entry, &info) == 0 else { return .notEnabled }
            guard info.st_uid == 0, info.st_mode & S_IFMT != S_IFLNK, info.st_mode & 0o022 == 0 else { return .needsApproval }
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code, let requirementText = try? FanControlServiceIdentity.ownRequirement() else { return .needsApproval }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement, SecStaticCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else { return .needsApproval }
        return .enabled
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
