import AppKit
import Foundation
import OSLog
import ServiceManagement

enum StoreMonitorState: Equatable {
    case loading
    case ready
    case recording
    case sleeping
    case erasing
    case cleanupRequired
    case unavailable

    var title: String {
        switch self {
        case .loading: return "Opening history"
        case .ready: return "Monitoring paused"
        case .recording: return "Recording on this Mac"
        case .sleeping: return "Mac asleep"
        case .erasing: return "Deleting local history"
        case .cleanupRequired: return "Local cleanup required"
        case .unavailable: return "History unavailable"
        }
    }
}

@MainActor
final class StoreMonitor: ObservableObject {
    @Published private(set) var state: StoreMonitorState = .loading
    @Published private(set) var readings: [StoreReading] = []
    @Published private(set) var sleepSpans: [StoreSleepSpan] = []
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var message: String?

    private static let monitoringEnabledKey = "storeMonitoringEnabled"
    private let defaults: UserDefaults
    private let samplingInterval: Duration
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MyMachineStore", category: "Monitoring")
    private let history: StoreHistory?
    private var startupBegan = false
    private var samplingTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cpuTracker = HostCPUTracker()
    private var lastTick: (wall: Date, instant: ContinuousClock.Instant)?
    private var nextPrune: ContinuousClock.Instant?
    private var sleepStart: Date?
    private var pendingSleep: [StoreSleepSpan] = []
    private var dataRevision = 0

    init(defaults: UserDefaults = .standard, directory: URL? = nil,
         samplingInterval: Duration = .seconds(StoreHistory.samplingSeconds), observeSleep: Bool = true) {
        self.defaults = defaults
        self.samplingInterval = samplingInterval
        do {
            self.history = try StoreHistory(directory: directory ?? StoreHistory.containerDirectory())
        } catch {
            self.history = nil
            state = .unavailable
            message = "MyMachine could not open its private history. Quit and reopen it to try again."
            logger.error("History open failed: \(error.localizedDescription, privacy: .private)")
        }
        if observeSleep { installSleepObservers() }
    }

    deinit {
        samplingTask?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var latest: StoreReading? { readings.last }
    var canErase: Bool { history != nil && state != .loading && state != .erasing }
    var canExport: Bool {
        (!readings.isEmpty || !sleepSpans.isEmpty) && [.ready, .recording, .sleeping].contains(state)
    }

    func prepare() async {
        guard let history, !startupBegan else { return }
        startupBegan = true
        refreshLoginStatus()
        do {
            guard try await !history.database.hasPendingEraseCleanup() else {
                requireCleanup()
                return
            }
            let now = Date()
            try await history.prune(at: now)
            let stored = try await history.load(at: now)
            readings = stored.readings
            sleepSpans = stored.sleep
            nextPrune = clock.now.advanced(by: .seconds(3_600))
            state = .ready
            if defaults.bool(forKey: Self.monitoringEnabledKey) { beginRecording() }
        } catch {
            fail(error)
        }
    }

    func startMonitoring() {
        guard state == .ready else { return }
        persistMonitoringPreference(true)
        beginRecording()
    }

    func pauseMonitoring() {
        guard state == .recording || state == .sleeping else { return }
        persistMonitoringPreference(false)
        samplingTask?.cancel()
        sleepStart = nil
        pendingSleep.removeAll()
        state = .ready
    }

    func willSleep(at date: Date = Date()) {
        guard state == .recording else { return }
        sleepStart = date
        samplingTask?.cancel()
        state = .sleeping
    }

    func didWake(at date: Date = Date()) {
        guard state == .sleeping else { return }
        if let sleepStart, sleepStart < date {
            pendingSleep.append(StoreSleepSpan(start: sleepStart, end: date))
        }
        sleepStart = nil
        beginRecording()
    }

    func eraseHistory() async {
        guard let history, canErase else { return }
        persistMonitoringPreference(false)
        state = .erasing
        message = nil
        dataRevision &+= 1
        samplingTask?.cancel()
        await samplingTask?.value
        readings.removeAll()
        sleepSpans.removeAll()
        pendingSleep.removeAll()
        sleepStart = nil

        do {
            guard try await history.database.eraseAllData() else {
                requireCleanup()
                return
            }
            nextPrune = clock.now.advanced(by: .seconds(3_600))
            state = .ready
            message = "Local history deleted."
        } catch {
            logger.error("Local erase failed: \(error.localizedDescription, privacy: .private)")
            requireCleanup()
        }
    }

    func exportHistory() {
        guard canExport else { return }
        let revision = dataRevision
        let cutoff = Date().addingTimeInterval(-StoreHistory.retentionWindow)
        let export = StoreHistory.csv(
            readings: readings.filter { $0.timestamp >= cutoff },
            sleep: sleepSpans.filter { $0.start >= cutoff }
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MyMachine History.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url, dataRevision == revision, canExport else { return }
        do {
            try export.write(to: url, atomically: true, encoding: .utf8)
            message = "History exported."
        } catch {
            logger.error("History export failed: \(error.localizedDescription, privacy: .private)")
            message = "The selected location could not be used. Choose a different location and try again."
        }
    }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            logger.error("Login item update failed: \(error.localizedDescription, privacy: .private)")
            message = "Launch at Login could not be changed. Check Login Items in System Settings."
        }
        refreshLoginStatus()
    }

    private func beginRecording() {
        message = nil
        cpuTracker = HostCPUTracker()
        lastTick = nil
        state = .recording
        let previousTask = samplingTask
        previousTask?.cancel()
        let interval = samplingInterval
        samplingTask = Task { [weak self] in
            // Drain an in-flight write from a previous session before sampling.
            await previousTask?.value
            while !Task.isCancelled {
                guard await self?.sample() == true else { return }
                do { try await Task.sleep(for: interval) }
                catch { return }
            }
        }
    }

    private func sample() async -> Bool {
        guard let history, state == .recording, !Task.isCancelled else { return false }
        do {
            let now = Date()
            if let nextPrune, clock.now >= nextPrune {
                try await history.prune(at: now)
                guard state == .recording, !Task.isCancelled else { return false }
                self.nextPrune = clock.now.advanced(by: .seconds(3_600))
                let cutoff = now.addingTimeInterval(-StoreHistory.retentionWindow)
                readings.removeAll { $0.timestamp < cutoff }
                sleepSpans.removeAll { $0.start < cutoff }
            }

            let reading = readSensors(at: now)
            let spans = pendingSleep
            pendingSleep.removeAll()
            guard try await history.append(reading, sleep: spans) else {
                if state != .erasing { requireCleanup() }
                return false
            }
            if state != .erasing {
                readings.append(reading)
                sleepSpans.append(contentsOf: spans)
            }
            return state == .recording
        } catch {
            if state != .erasing { fail(error) }
            return false
        }
    }

    private func readSensors(at now: Date) -> StoreReading {
        let instant = clock.now
        let elapsed: TimeInterval
        if let lastTick {
            let components = lastTick.instant.duration(to: instant).components
            elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
            let wallElapsed = now.timeIntervalSince(lastTick.wall)
            if elapsed <= 0 || elapsed > StoreHistory.samplingSeconds * 2 || abs(wallElapsed - elapsed) > 2 {
                cpuTracker = HostCPUTracker()
            }
        } else {
            elapsed = 0
        }
        lastTick = (now, instant)

        let cpu = cpuTracker.observe(SystemMetrics.readCPUCounter())
        let memory = SystemMetrics.readMemory()
        let battery = SystemMetrics.readBattery()
        return StoreReading(
            timestamp: now, cpuPercent: cpu, cpuDuration: cpu == nil ? 0 : elapsed,
            memoryUsed: memory?.used, memoryTotal: memory?.total,
            batteryPercent: battery.percent, powerSource: battery.source, isCharging: battery.charging,
            thermal: SystemMetrics.readThermal()
        )
    }

    private func persistMonitoringPreference(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.monitoringEnabledKey)
        // Flush pause before a subsequent immediate quit.
        defaults.synchronize()
    }

    private func requireCleanup() {
        persistMonitoringPreference(false)
        state = .cleanupRequired
        readings.removeAll()
        sleepSpans.removeAll()
        message = "Recording is paused until local cleanup can be confirmed. Use Delete Local History to retry."
    }

    private func fail(_ error: Error) {
        logger.error("Monitoring stopped: \(error.localizedDescription, privacy: .private)")
        persistMonitoringPreference(false)
        state = .unavailable
        message = "MyMachine could not verify its local history. Quit and reopen it to retry, or delete the local history."
    }

    private func installSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                let date = Date()
                Task { @MainActor in self?.willSleep(at: date) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                let date = Date()
                Task { @MainActor in self?.didWake(at: date) }
            }
        ]
    }
}
