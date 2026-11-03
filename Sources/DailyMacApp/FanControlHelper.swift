import DailyMacCore
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import SystemConfiguration
import ServiceManagement

enum FanControlHelper {
    /// Used only by the explicit administrator installer AFTER stopping the old
    /// root-owned service. It cannot accept a target or arbitrary recovery path.
    static func restoreAndExit() -> Never {
        guard geteuid() == 0 else { exit(EX_NOPERM) }
        do {
            try FanControlInstallation.verify(requireReady: false)
            _ = try FanControlServiceIdentity.ownRequirement()
            let aliasPath = "/Applications/MY MACHINE (Official).app"
            if symlink(FanControlInstallation.appPath, aliasPath) != 0 && errno != EEXIST {
                fputs("Could not create the Applications shortcut.\n", stderr)
            }
            let journal = try FanControlJournalStore()
            if let record = try journal.load() {
                let engine = try FanControlEngine(journal: journal.save)
                do { _ = try engine.recoverOwnedControl(from: record) }
                catch FanControlError.externalControl {
                    // Another controller owns the current target. Recovery may
                    // relinquish our stale journal without touching that target.
                    guard try journal.load() == nil else { throw FanControlError.externalControl }
                }
            }
            guard try journal.load() == nil else { exit(EX_TEMPFAIL) }
            let service = SMAppService.daemon(plistName: FanControlServiceIdentity.plistName)
            // A replacement executable requires registration by the user
            // again. The installer has already stopped any running instance.
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            exit(EX_OK)
        } catch {
            fputs("Automatic fan restoration is not confirmed: \(error.localizedDescription)\n", stderr)
            exit(EX_TEMPFAIL)
        }
    }
    /// This entry runs before NSApplication/AppModel are created. A plain app
    /// launch never registers the helper and never invokes the hardware writer.
    static func run() -> Never {
        guard geteuid() == 0 else {
            fputs("Fan helper must be launched by the approved macOS service.\n", stderr)
            exit(EX_NOPERM)
        }
        do {
            try FanControlInstallation.verify()
            let server = try FanControlServer(serviceName: FanControlServiceIdentity.name)
            try server.start()
            withExtendedLifetime(server) { CFRunLoopRun() }
            exit(EX_OK)
        } catch {
            fputs("Fan helper could not start: \(error.localizedDescription)\n", stderr)
            exit(EX_UNAVAILABLE)
        }
    }
}

private final class FanControlServer: NSObject, NSXPCListenerDelegate {
    private let requirement: String
    private let engine: FanControlEngine
    private let journal: FanControlJournalStore
    private let queue = DispatchQueue(label: "local.mymachine.fancontrol.serial")
    private let listener = NSXPCListener(machServiceName: FanControlServiceIdentity.name)
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var owner: UUID?
    private var unregistering = false
    private var ownerUID: uid_t?
    private var heartbeatAt: ContinuousClock.Instant?
    private var restorationError: String?
    private var powerPort: IONotificationPortRef?
    private var powerConnection: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var lastModeCheck = ContinuousClock.now

    init(serviceName: String) throws {
        requirement = try FanControlServiceIdentity.ownRequirement()
        let store = try FanControlJournalStore()
        journal = store
        engine = try FanControlEngine(journal: store.save)
        super.init()
        listener.delegate = self
    }

    func start() throws {
        // Recovery completes before admitting any new manual request. Records
        // whose hardware or current target no longer matches cannot be replayed.
        if let pending = try journal.load() {
            do { _ = try engine.recoverOwnedControl(from: pending) }
            catch FanControlError.externalControl {
                guard try journal.load() == nil else { throw FanControlError.externalControl }
            }
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.watchdog() }
        timer = source
        source.resume()
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: number, queue: queue)
            signalSource.setEventHandler { [weak self] in
                self?.restore()
                // A failed restoration retains the durable record for restart.
                exit(EX_OK)
            }
            signalSource.resume()
            signalSources.append(signalSource)
        }
        powerConnection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &powerPort,
            { reference, _, message, argument in
                guard let reference else { return }
                let server = Unmanaged<FanControlServer>.fromOpaque(reference).takeUnretainedValue()
                server.handlePower(message, argument: argument)
            }, &powerNotifier)
        guard powerConnection != 0, let powerPort,
              let source = IONotificationPortGetRunLoopSource(powerPort)?.takeUnretainedValue() else {
            throw FanControlError.unavailable("Fan control cannot observe system sleep; manual control remains disabled.")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard uid != 0, uid == consoleUID() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: FanControlServiceProtocol.self)
        let identifier = UUID()
        connection.exportedObject = FanControlSession(server: self, identifier: identifier, user: uid)
        connection.invalidationHandler = { [weak self] in self?.disconnected(identifier) }
        connection.interruptionHandler = { [weak self] in self?.disconnected(identifier) }
        connection.resume()
        return true
    }

    fileprivate func status(user: uid_t, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            guard user == consoleUID() else { reply(nil, "The active Mac user changed."); return }
            self.respond(reply) {
                if let error = self.restorationError { throw FanControlError.operationFailed(error) }
                return try self.engine.readState()
            }
        }
    }

    fileprivate func set(percent: Double, identifier: UUID, user: uid_t, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            guard user == consoleUID() else { reply(nil, "The active Mac user changed."); return }
            self.respond(reply) {
                guard !self.unregistering else {
                    throw FanControlError.unavailable("Fan control is being disabled.")
                }
                guard self.owner == nil || self.owner == identifier else {
                    throw FanControlError.unavailable("Another MY MACHINE session is controlling the fans.")
                }
                guard self.restorationError == nil else {
                    throw FanControlError.operationFailed(self.restorationError!)
                }
                guard !FanControlEngine.shouldRestore(thermal: currentThermal()) else {
                    self.restore()
                    throw FanControlError.unavailable("macOS needs automatic thermal control right now.")
                }
                // Ownership is set before actuation so every error/disconnect
                // path remains eligible for watchdog restoration.
                self.owner = identifier
                self.ownerUID = user
                self.heartbeatAt = .now
                return try self.engine.setAllFans(percent: percent)
            }
        }
    }

    fileprivate func automatic(user: uid_t, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            guard user == consoleUID() else { reply(nil, "The active Mac user changed."); return }
            self.respond(reply) {
                let result = try self.engine.restoreAutomatic()
                self.owner = nil; self.ownerUID = nil; self.heartbeatAt = nil; self.restorationError = nil
                return result
            }
        }
    }

    fileprivate func heartbeat(identifier: UUID, user: uid_t, reply: @escaping (Bool) -> Void) {
        queue.async {
            guard user == consoleUID(), self.owner == identifier else { reply(false); return }
            self.heartbeatAt = .now
            reply(true)
        }
    }

    fileprivate func prepareToUnregister(user: uid_t, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            guard user == consoleUID() else { reply(nil, "The active Mac user changed."); return }
            self.respond(reply) {
                let result: FanControlSnapshot
                do { result = try self.engine.restoreAutomatic() }
                catch FanControlError.externalControl {
                    guard try self.journal.load() == nil else { throw FanControlError.externalControl }
                    result = try self.engine.readState()
                }
                self.owner = nil; self.ownerUID = nil; self.heartbeatAt = nil; self.restorationError = nil
                // Stay drained even if the caller disconnects before launchd
                // finishes unregistering. A repeated disable can still retry.
                self.unregistering = true
                return result
            }
        }
    }

    private func disconnected(_ identifier: UUID) {
        queue.async {
            if self.owner == identifier { self.restore() }
        }
    }

    private func watchdog() {
        guard owner != nil || restorationError != nil else { return }
        let expired = heartbeatAt.map { $0.duration(to: .now) > .seconds(20) } ?? true
        var protectedOrUnavailable = false
        if lastModeCheck.duration(to: .now) > .seconds(5) {
            lastModeCheck = .now
            do { protectedOrUnavailable = try engine.readState().fans.contains { $0.mode == 3 } }
            catch { protectedOrUnavailable = true }
        }
        if expired || ownerUID != consoleUID() || protectedOrUnavailable || FanControlEngine.shouldRestore(thermal: currentThermal()) {
            restore()
        }
    }

    private func restore() {
        do {
            _ = try engine.restoreAutomatic()
            owner = nil; ownerUID = nil; heartbeatAt = nil; restorationError = nil
        } catch {
            restorationError = "Automatic fan restoration is not confirmed: \(error.localizedDescription)"
            // Keep ownership and journal, retry from the independent watchdog.
        }
    }

    private func handlePower(_ message: natural_t, argument: UnsafeMutableRawPointer?) {
        // Swift cannot import IOMessage.h compound macros. IOReturn.h defines
        // sys_iokit = (0x38 << 26), sub_iokit_common = 0.
        switch message {
        case 0xe0000270: // IOMessage.h: iokit_common_msg(0x270)
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case 0xe0000280: // IOMessage.h: iokit_common_msg(0x280)
            queue.sync { restore() }
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case 0xe0000300: // IOMessage.h: iokit_common_msg(0x300)
            queue.async { self.restore() } // Never reapply a manual request after wake.
        default: break
        }
    }

    private func respond(_ reply: @escaping (Data?, String?) -> Void, action: () throws -> FanControlSnapshot) {
        do { reply(try JSONEncoder().encode(action()), nil) }
        catch { reply(nil, error.localizedDescription) }
    }
}

private final class FanControlSession: NSObject, FanControlServiceProtocol {
    private weak var server: FanControlServer?
    private let identifier: UUID
    private let user: uid_t
    init(server: FanControlServer, identifier: UUID, user: uid_t) {
        self.server = server; self.identifier = identifier; self.user = user
    }
    func status(withReply reply: @escaping (Data?, String?) -> Void) { server?.status(user: user, reply: reply) }
    func setAllFans(percent: Double, withReply reply: @escaping (Data?, String?) -> Void) {
        server?.set(percent: percent, identifier: identifier, user: user, reply: reply)
    }
    func automatic(withReply reply: @escaping (Data?, String?) -> Void) { server?.automatic(user: user, reply: reply) }
    func prepareToUnregister(withReply reply: @escaping (Data?, String?) -> Void) {
        server?.prepareToUnregister(user: user, reply: reply)
    }
    func heartbeat(withReply reply: @escaping (Bool) -> Void) { server?.heartbeat(identifier: identifier, user: user, reply: reply) }
}

private func consoleUID() -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
          name != "loginwindow", uid != 0 else { return nil }
    return uid
}

private func currentThermal() -> ThermalLevel {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .unknown
    }
}
