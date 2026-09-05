import AppKit
import DailyMacCore
import Foundation
import ServiceManagement
import SwiftUI

enum CollectionState: Equatable {
    case starting
    case monitoring
    case paused
    case sleeping
    case failed(String)

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .monitoring: return "Monitoring"
        case .paused: return "Paused"
        case .sleeping: return "Asleep"
        case .failed: return "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .starting: return "Preparing the local monitor."
        case .monitoring: return "Observing app identity and machine behavior locally."
        case .paused: return "No activity or performance telemetry is being collected."
        case .sleeping: return "Collection is suspended while the Mac sleeps."
        case .failed(let message): return message
        }
    }

    var symbol: String {
        switch self {
        case .starting: return "ellipsis.circle"
        case .monitoring: return "circle.fill"
        case .paused: return "pause.circle.fill"
        case .sleeping: return "moon.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

enum DiagnosisHandoffState: Equatable {
    case idle
    case preparing
    case copied
    case copiedWithoutOpening(String)
    case failed(String)

    var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }

    var buttonTitle: String {
        switch self {
        case .idle: return "Diagnose My Machine"
        case .preparing: return "Preparing…"
        case .copied: return "Copied — paste within 10 min"
        case .copiedWithoutOpening(let destination): return "Copied — \(destination) didn’t open"
        case .failed: return "Try Diagnosis Again"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "stethoscope"
        case .preparing: return "ellipsis"
        case .copied, .copiedWithoutOpening: return "checkmark"
        case .failed: return "arrow.clockwise"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Prepare a private 24-hour brief for an external assistant."
        case .preparing:
            return "Preparing a private 24-hour brief locally."
        case .copied:
            return "Copied on this Mac. While MY MACHINE remains open, it clears this copy after about 10 minutes if you do not replace it. Nothing is sent until you paste and send it."
        case .copiedWithoutOpening(let destination):
            return "The brief was copied, but \(destination) could not be opened. Paste it within 10 minutes wherever you prefer."
        case .failed(let message):
            return message
        }
    }
}

/// Everything required to render one monitoring timeline, committed as a
/// single value so views never briefly mix readings from different refreshes.
struct MonitoringDisplayState: Equatable {
    let snapshot: MonitoringSnapshot
    let samples: [SystemSample]
    let backgroundPoints: [BackgroundActivityPoint]
    let events: [ActivityEvent]
    let appContributors: [AppComputeContribution]
    let dataThrough: Date?
    let refreshedAt: Date
}

@MainActor
final class AppModel: ObservableObject {
    @Published var collectionState: CollectionState = .starting
    @Published var settings: MonitoringSettings = .default
    @Published var todayReport: DailyReport?
    @Published private(set) var currentActivitySession: CurrentActivitySession?
    @Published var todaySamples: [SystemSample] = []
    @Published var todayChartSamples: [SystemSample] = []
    @Published var monitoringRange: MonitoringRange = .twentyFourHours
    @Published private(set) var monitoringContent: MonitoringDisplayState?
    @Published var monitoringIsRefreshing = false
    @Published private(set) var menuBarMonitoringRange: MonitoringRange = .oneHour
    @Published private(set) var menuBarMonitoringContent: MonitoringDisplayState?
    @Published private(set) var menuBarIsRefreshing = false
    @Published private(set) var menuBarRefreshMessage: String?
    @Published var reports: [DailyReport] = []
    @Published var processImpacts: [ProcessImpact] = []
    @Published var latestSystem: SystemSample?
    @Published var trend7 = TrendSummary(days: 7, activeDuration: 0, averageDailyCPU: 0, mostUsedCategory: nil, notableChange: nil, narrative: "Building a baseline.")
    @Published var trend30 = TrendSummary(days: 30, activeDuration: 0, averageDailyCPU: 0, mostUsedCategory: nil, notableChange: nil, narrative: "Building a baseline.")
    @Published var lastUpdated: Date?
    @Published var processCoverage = "Process attribution has not been sampled yet."
    @Published var databaseSize: UInt64 = 0
    @Published var errorMessage: String?
    @Published var loginItemEnabled = false
    @Published var loginItemNeedsApproval = false
    @Published var notificationDeliveryEnabled = false
    @Published var notificationNeedsApproval = false
    var currentSessionDuration: TimeInterval? {
        let now = Date()
        guard let session = currentActivitySession,
              now.timeIntervalSince(session.lastActiveAt) <= TimelineSemantics.currentSessionInterruptionTolerance else {
            return nil
        }
        return session.duration(endingAt: now)
    }

    @Published var notificationStatusDetail = "Preparing private report-ready notifications."
    @Published private(set) var diagnosisState: DiagnosisHandoffState = .idle

    let dataDirectoryURL: URL
    private let store: SQLiteStore?
    private lazy var sampler = TelemetrySampler()
    private let insights = InsightEngine()
    private var detector = EventDetector()
    private var monitorTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lastReportRefresh: Date?
    private var lastMonitoringRefresh: Date?
    private var monitoringRefreshGeneration = 0
    private var menuBarRefreshGeneration = 0
    private var menuBarRefreshTask: Task<Void, Never>?
    private var diagnosisTask: Task<Void, Never>?
    private var diagnosisFeedbackTask: Task<Void, Never>?
    private var diagnosisClipboardClearTask: Task<Void, Never>?
    private var diagnosisGeneration = 0
    private var diagnosisClipboardChangeCount: Int?
    private var lastRetentionDate: Date?
    private var lastDayKey = DayBoundaries.key(for: Date())
    private var lastSampleTimestamp: Date?
    private var needsFreshBaseline = true
    private var collectionReady = false
    private var notificationConfigurationGeneration = 0
    private var dataEpoch = 0
    private var dataEraseInProgress = false
    private var shouldResumeAfterDataErase = false

    var monitoringSnapshot: MonitoringSnapshot? { monitoringContent?.snapshot }
    var monitoringSamples: [SystemSample] { monitoringContent?.samples ?? [] }
    var monitoringBackgroundPoints: [BackgroundActivityPoint] { monitoringContent?.backgroundPoints ?? [] }
    var monitoringEvents: [ActivityEvent] { monitoringContent?.events ?? [] }
    var monitoringAppContributors: [AppComputeContribution] { monitoringContent?.appContributors ?? [] }
    var monitoringDataThrough: Date? { monitoringContent?.dataThrough }

    init() {
        do {
            let opened = try SQLiteStore()
            store = opened
            dataDirectoryURL = opened.directoryURL
        } catch {
            store = nil
            dataDirectoryURL = SQLiteStore.defaultDirectoryURL()
            let message = Self.friendlyStorageError
            collectionState = .failed(message)
            errorMessage = message
        }
        restoreCriticalPreferencesIfPresent()
        installWorkspaceObservers()
        updateLoginItemStatus()
        Task { await bootstrap() }
    }

    deinit {
        monitorTask?.cancel()
        menuBarRefreshTask?.cancel()
        diagnosisTask?.cancel()
        diagnosisFeedbackTask?.cancel()
        diagnosisClipboardClearTask?.cancel()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func acceptCollectionConsent() {
        settings.collectionConsentGranted = true
        startMonitoring()
    }

    func startMonitoring() {
        guard store != nil, collectionReady, !dataEraseInProgress else { return }
        guard settings.hasCollectionConsent else {
            AppRoute.shared.requestMonitoring()
            return
        }
        settings.isPaused = false
        settings.pauseUntil = nil
        persistCriticalPreferencesSynchronously()
        prepareForCollectionGap()
        persistSettings()
        collectionState = .monitoring
        record(ActivityEvent(timestamp: Date(), type: .note, title: "Monitoring resumed", explanation: "MY MACHINE resumed local collection. It will not reconstruct the paused interval.", severity: .information))
        restartMonitorLoop()
    }

    func pauseIndefinitely() {
        settings.isPaused = true
        settings.pauseUntil = nil
        persistCriticalPreferencesSynchronously()
        prepareForCollectionGap()
        persistSettings()
        collectionState = .paused
        record(ActivityEvent(timestamp: Date(), type: .note, title: "Monitoring paused", explanation: "No telemetry is collected while paused, and the missing interval will remain a visible gap.", severity: .information))
        stopMonitorLoop()
    }

    func pauseForOneHour() {
        settings.isPaused = false
        settings.pauseUntil = Date().addingTimeInterval(3_600)
        persistCriticalPreferencesSynchronously()
        prepareForCollectionGap()
        persistSettings()
        collectionState = .paused
        record(ActivityEvent(timestamp: Date(), type: .note, title: "Monitoring paused for one hour", explanation: "No telemetry is collected during the pause, and MY MACHINE will resume automatically.", severity: .information))
        restartMonitorLoop()
    }

    func pauseUntilTomorrow() {
        settings.isPaused = false
        let calendar = Calendar.autoupdatingCurrent
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
        settings.pauseUntil = next
        persistCriticalPreferencesSynchronously()
        prepareForCollectionGap()
        persistSettings()
        collectionState = .paused
        record(ActivityEvent(timestamp: Date(), type: .note, title: "Monitoring paused until tomorrow", explanation: "No telemetry is collected during the pause, and MY MACHINE will resume on the next local day.", severity: .information))
        restartMonitorLoop()
    }

    func persistSettings() {
        guard let store else { return }
        let current = settings
        let epoch = dataEpoch
        Task {
            do {
                try await store.saveSettings(current)
                try await RetentionCoordinator.finalizeThenRetain(store: store, settings: current) {
                    try await self.finalizeUnreportedDays()
                }
                let refreshed = try await store.reports()
                guard epoch == self.dataEpoch, !self.dataEraseInProgress else { return }
                self.reports = refreshed
            }
            catch { await show(error) }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLoginPreference = enabled
        persistCriticalPreferencesSynchronously()
        persistSettings()
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Launch at login could not be changed: \(error.localizedDescription)"
        }
        updateLoginItemStatus()
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDirectoryURL])
    }

    func exportToday() {
        guard let report = todayReport else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MY MACHINE \(report.dayKey).md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ReportRenderer.markdown(report).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "The report could not be exported: \(error.localizedDescription)"
        }
    }

    func diagnoseMachine() {
        guard !diagnosisState.isPreparing else { return }
        guard let store, !dataEraseInProgress else {
            diagnosisState = .failed("Monitoring history is not available just now. Nothing was copied or sent.")
            return
        }

        diagnosisGeneration &+= 1
        let generation = diagnosisGeneration
        let diagnosisEpoch = dataEpoch
        let endingAt = Date()
        let interval = MonitoringRange.twentyFourHours.interval(endingAt: endingAt)
        let destination = settings.diagnosisDestination ?? .copyOnly
        let includeNames = settings.includesDiagnosisApplicationNames
        let currentTrend7 = trend7
        let currentTrend30 = trend30
        diagnosisFeedbackTask?.cancel()
        diagnosisState = .preparing

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try await store.samples(in: interval)
                let appResources = try await store.appResourceSamples(in: interval)
                let notableEvents = try await store.events(from: interval.start, to: interval.end)
                let sleepWakeEvents = try await store.sleepWakeEvents(in: interval, includingPrevious: true)
                guard !Task.isCancelled,
                      generation == self.diagnosisGeneration,
                      diagnosisEpoch == self.dataEpoch,
                      !self.dataEraseInProgress else { return }

                let renderTask = Task.detached(priority: .userInitiated) {
                    let snapshot = InsightEngine().makeMonitoringSnapshot(
                        range: .twentyFourHours,
                        endingAt: endingAt,
                        samples: samples,
                        appResourceSamples: appResources
                    )
                    var eventsByID: [UUID: ActivityEvent] = [:]
                    for event in notableEvents + sleepWakeEvents {
                        eventsByID[event.id] = event
                    }
                    return DiagnosisBriefRenderer.render(
                        snapshot: snapshot,
                        samples: samples,
                        events: Array(eventsByID.values),
                        trend7: currentTrend7,
                        trend30: currentTrend30,
                        includeApplicationNames: includeNames
                    )
                }
                let brief = await renderTask.value
                guard !Task.isCancelled,
                      generation == self.diagnosisGeneration,
                      diagnosisEpoch == self.dataEpoch,
                      !self.dataEraseInProgress else { return }

                let pasteboard = NSPasteboard.general
                pasteboard.prepareForNewContents(with: .currentHostOnly)
                guard pasteboard.setString(brief.markdown, forType: .string) else {
                    self.diagnosisState = .failed("The private brief could not be copied. Nothing was opened or sent.")
                    self.diagnosisTask = nil
                    return
                }
                let changeCount = pasteboard.changeCount
                self.diagnosisClipboardChangeCount = changeCount
                self.scheduleDiagnosisClipboardClear(changeCount: changeCount)

                if let destinationURL = self.diagnosisURL(for: destination) {
                    if NSWorkspace.shared.open(destinationURL) {
                        self.diagnosisState = .copied
                    } else {
                        self.diagnosisState = .copiedWithoutOpening(destination.name)
                    }
                } else {
                    self.diagnosisState = .copied
                }
                self.diagnosisTask = nil
                self.scheduleDiagnosisFeedbackReset(generation: generation)
            } catch {
                guard generation == self.diagnosisGeneration else { return }
                self.diagnosisTask = nil
                self.diagnosisState = .failed("The 24-hour brief could not be prepared just now. Monitoring is still running, and nothing was copied or sent.")
            }
        }
        diagnosisTask = task
    }

    func eraseAllData() {
        guard let store else { return }
        dataEpoch &+= 1
        diagnosisGeneration &+= 1
        diagnosisTask?.cancel()
        diagnosisTask = nil
        diagnosisFeedbackTask?.cancel()
        diagnosisFeedbackTask = nil
        clearDiagnosisClipboardIfOwned()
        diagnosisState = .idle
        let eraseEpoch = dataEpoch
        dataEraseInProgress = true
        shouldResumeAfterDataErase = shouldResumeAfterDataErase || monitorTask != nil
        stopMonitorLoop()
        prepareForCollectionGap()
        NotificationCoordinator.shared.cancelReportNotifications()
        clearPublishedHistory()
        Task {
            do {
                try await store.eraseAllData()
                guard eraseEpoch == dataEpoch else { return }
                databaseSize = await store.databaseSizeBytes()
                detector.resetAfterGap()
                await sampler.resetDeltas()
                dataEraseInProgress = false
                let shouldResume = shouldResumeAfterDataErase
                shouldResumeAfterDataErase = false
                if shouldResume { beginLoopIfNeeded() }
            } catch {
                if eraseEpoch == dataEpoch {
                    dataEraseInProgress = false
                    let shouldResume = shouldResumeAfterDataErase
                    shouldResumeAfterDataErase = false
                    if shouldResume { beginLoopIfNeeded() }
                }
                await show(error)
            }
        }
    }

    func refreshNow() {
        Task {
            do {
                try await refreshTodayReport(force: true)
                try await refreshMonitoring(force: true)
            }
            catch { await show(error) }
        }
    }

    func selectMonitoringRange(_ range: MonitoringRange) {
        guard monitoringRange != range else { return }
        monitoringRange = range
        Task {
            do { try await refreshMonitoring(force: true) }
            catch { await show(error) }
        }
    }

    func refreshMonitoringIfNeeded() {
        Task {
            do { try await refreshMonitoring(force: false) }
            catch { await show(error) }
        }
    }

    /// Called for every menu-bar presentation. Existing content stays visible
    /// while one coalesced, database-only refresh prepares the selected range.
    func menuBarDidOpen() {
        beginMenuBarRefreshIfNeeded(endingAt: Date())
    }

    func refreshMenuBarNow() {
        restartMenuBarRefresh(endingAt: Date())
    }

    func selectMenuBarMonitoringRange(_ range: MonitoringRange) {
        guard menuBarMonitoringRange != range else { return }
        menuBarMonitoringRange = range
        restartMenuBarRefresh(endingAt: Date())
    }

    private func restartMenuBarRefresh(endingAt now: Date) {
        menuBarRefreshGeneration &+= 1
        menuBarRefreshTask?.cancel()
        menuBarRefreshTask = nil
        menuBarIsRefreshing = false
        beginMenuBarRefreshIfNeeded(endingAt: now)
    }

    func setBriefingNotifications(_ enabled: Bool) {
        settings.briefingNotificationsEnabled = enabled
        notificationConfigurationGeneration &+= 1
        persistCriticalPreferencesSynchronously()
        persistSettings()
        if enabled {
            Task { await configureBriefingNotifications() }
        } else {
            NotificationCoordinator.shared.setDeliveryActive(false)
            notificationDeliveryEnabled = false
            notificationNeedsApproval = false
            notificationStatusDetail = "Proactive briefings are off. Monitoring and reports continue locally."
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func diagnosisURL(for destination: DiagnosisDestination) -> URL? {
        switch destination {
        case .copyOnly: return nil
        case .chatGPT: return URL(string: "https://chatgpt.com/")
        case .claude: return URL(string: "https://claude.ai/new")
        }
    }

    private func scheduleDiagnosisFeedbackReset(generation: Int) {
        diagnosisFeedbackTask?.cancel()
        diagnosisFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, generation == self.diagnosisGeneration else { return }
            if !self.diagnosisState.isPreparing { self.diagnosisState = .idle }
            self.diagnosisFeedbackTask = nil
        }
    }

    private func scheduleDiagnosisClipboardClear(changeCount: Int) {
        diagnosisClipboardClearTask?.cancel()
        diagnosisClipboardClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard let self, !Task.isCancelled,
                  self.diagnosisClipboardChangeCount == changeCount,
                  NSPasteboard.general.changeCount == changeCount else { return }
            NSPasteboard.general.clearContents()
            self.diagnosisClipboardChangeCount = nil
            self.diagnosisClipboardClearTask = nil
        }
    }

    private func clearDiagnosisClipboardIfOwned() {
        diagnosisClipboardClearTask?.cancel()
        diagnosisClipboardClearTask = nil
        guard let changeCount = diagnosisClipboardChangeCount,
              NSPasteboard.general.changeCount == changeCount else {
            diagnosisClipboardChangeCount = nil
            return
        }
        NSPasteboard.general.clearContents()
        diagnosisClipboardChangeCount = nil
    }

    private func bootstrap() async {
        guard let store else { return }
        do {
            settings = try await store.loadSettings()
            restoreCriticalPreferencesIfPresent()
            try await RetentionCoordinator.finalizeThenRetain(store: store, settings: settings) {
                try await self.finalizeUnreportedDays()
            }
            lastRetentionDate = Date()
            latestSystem = try await store.latestSample()
            lastSampleTimestamp = latestSystem?.timestamp
            lastUpdated = latestSystem?.timestamp
            processImpacts = try await store.latestProcessImpacts()
            try await refreshTodayReport(force: true)
            try await refreshMonitoring(force: true)
            databaseSize = await store.databaseSizeBytes()
            collectionReady = true
            persistCriticalPreferencesSynchronously()
            collectionState = isCurrentlyPaused ? .paused : .monitoring
            attemptLoginRegistrationIfAppropriate()
            if !settings.hasCollectionConsent { AppRoute.shared.requestMonitoring() }
            if !isCurrentlyPaused || settings.pauseUntil != nil { beginLoopIfNeeded() }
            if settings.briefingNotificationsEnabled == true {
                Task { await self.configureBriefingNotifications() }
            } else {
                notificationStatusDetail = "Proactive briefings are off. Monitoring and reports continue locally."
            }
        } catch {
            await show(error)
        }
    }

    private func beginLoopIfNeeded() {
        guard monitorTask == nil, store != nil, collectionReady, settings.hasCollectionConsent, !dataEraseInProgress else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isCurrentlyPaused {
                    self.collectionState = .paused
                    guard let resumeAt = self.settings.pauseUntil else {
                        self.monitorTask = nil
                        return
                    }
                    let delay = max(1, resumeAt.timeIntervalSinceNow)
                    try? await Task.sleep(nanoseconds: UInt64(min(delay, 86_400) * 1_000_000_000))
                    if Task.isCancelled { return }
                    continue
                }
                if case .sleeping = self.collectionState {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                if self.needsFreshBaseline {
                    self.needsFreshBaseline = false
                    self.detector.resetAfterGap()
                    await self.sampler.resetDeltas()
                    if self.isCurrentlyPaused { continue }
                    if case .sleeping = self.collectionState { continue }
                }
                self.collectionState = .monitoring
                let activity = ProcessInfo.processInfo.beginActivity(options: .background, reason: "Completing a brief local telemetry sample")
                let result = await self.sampler.sample(settings: self.settings)
                ProcessInfo.processInfo.endActivity(activity)
                if Task.isCancelled { return }
                if self.isCurrentlyPaused {
                    self.needsFreshBaseline = true
                    continue
                }
                if case .sleeping = self.collectionState {
                    self.needsFreshBaseline = true
                    continue
                }
                await self.handle(result)
                let nanos = UInt64(max(5, result.nextInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    private func stopMonitorLoop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func restartMonitorLoop() {
        stopMonitorLoop()
        beginLoopIfNeeded()
    }

    private var isCurrentlyPaused: Bool {
        if !settings.hasCollectionConsent { return true }
        if settings.isPaused { return true }
        if let pausedUntil = settings.pauseUntil {
            if pausedUntil > Date() { return true }
            settings.pauseUntil = nil
            prepareForCollectionGap()
            persistCriticalPreferencesSynchronously()
            persistSettings()
            record(ActivityEvent(timestamp: Date(), type: .note, title: "Monitoring resumed automatically", explanation: "The requested pause ended. Collection resumed without reconstructing the paused interval.", severity: .information))
        }
        return false
    }

    private func handle(_ result: TelemetryResult) async {
        guard let store, !dataEraseInProgress else { return }
        let sampleEpoch = dataEpoch
        var events: [ActivityEvent] = []
        if let previous = lastSampleTimestamp {
            let gap = result.system.timestamp.timeIntervalSince(previous)
            if result.baselineResetAfterGap || gap < 0 || gap > max(120, result.system.samplingInterval * 4) {
                detector.resetAfterGap()
                events.append(ActivityEvent(
                    timestamp: result.system.timestamp,
                    type: .note,
                    title: "Monitoring resumed after a data gap",
                    explanation: "MY MACHINE did not observe the preceding \(Formatters.duration(gap)) and will not infer what happened during it. The gap may reflect sleep, a pause, the app being closed, or a restart.",
                    severity: .notable
                ))
            }
        }
        events.append(contentsOf: detector.observe(result.system))
        do {
            let storeGeneration = await store.currentDataGeneration()
            guard sampleEpoch == dataEpoch, !dataEraseInProgress else { return }
            let saved = try await store.save(
                sample: result.system,
                processes: result.processes,
                appResources: result.appResources,
                events: events,
                ifDataGeneration: storeGeneration
            )
            guard saved, sampleEpoch == dataEpoch, !dataEraseInProgress else { return }
            latestSystem = result.system
            currentActivitySession = TimelineSemantics.updatingCurrentActivitySession(
                currentActivitySession,
                with: result.system
            )
            lastSampleTimestamp = result.system.timestamp
            lastUpdated = result.system.timestamp
            if result.attemptedProcessCount > 0 {
                let percent = Double(result.observedProcessCount) / Double(result.attemptedProcessCount) * 100
                processCoverage = "Observed counters for \(result.observedProcessCount) of \(result.attemptedProcessCount) running processes (\(Formatters.percent(percent))). Protected and very short-lived processes may be missing."
            }
            if !result.processes.isEmpty {
                let refreshedImpacts = try await store.latestProcessImpacts()
                guard sampleEpoch == dataEpoch, !dataEraseInProgress else { return }
                processImpacts = refreshedImpacts
            }
            let newDay = DayBoundaries.key(for: result.system.timestamp)
            if newDay != lastDayKey {
                let previous = lastDayKey
                lastDayKey = newDay
                try await generateReport(dayKey: previous, publishAsToday: false)
                try await refreshTodayReport(force: true)
            } else if todayReport?.sampleCount == 0 || lastReportRefresh == nil || Date().timeIntervalSince(lastReportRefresh!) >= 120 {
                try await refreshTodayReport(force: true)
            }
            if lastMonitoringRefresh == nil || Date().timeIntervalSince(lastMonitoringRefresh!) >= 120 {
                try await refreshMonitoring(force: true)
            }
            if lastRetentionDate == nil || Date().timeIntervalSince(lastRetentionDate!) >= 86_400 {
                try await RetentionCoordinator.finalizeThenRetain(store: store, settings: settings) {
                    try await self.finalizeUnreportedDays()
                }
                lastRetentionDate = Date()
            }
            let refreshedDatabaseSize = await store.databaseSizeBytes()
            guard sampleEpoch == dataEpoch, !dataEraseInProgress else { return }
            databaseSize = refreshedDatabaseSize
        } catch {
            await show(error)
        }
    }

    private func refreshTodayReport(force: Bool) async throws {
        if !force, let lastReportRefresh, Date().timeIntervalSince(lastReportRefresh) < 300 { return }
        let key = DayBoundaries.key(for: Date())
        try await generateReport(dayKey: key, publishAsToday: true)
    }

    private func refreshMonitoring(force: Bool, endingAt now: Date = Date()) async throws {
        guard store != nil, !dataEraseInProgress else { return }
        if !force, let lastMonitoringRefresh, now.timeIntervalSince(lastMonitoringRefresh) < 120 { return }

        monitoringRefreshGeneration &+= 1
        let generation = monitoringRefreshGeneration
        let refreshEpoch = dataEpoch
        let range = monitoringRange
        monitoringIsRefreshing = true

        let content: MonitoringDisplayState
        do {
            content = try await makeMonitoringContent(range: range, endingAt: now, limit: 720)
        } catch {
            if generation == monitoringRefreshGeneration { monitoringIsRefreshing = false }
            throw error
        }

        guard generation == monitoringRefreshGeneration,
              refreshEpoch == dataEpoch,
              !dataEraseInProgress,
              range == monitoringRange else { return }
        monitoringContent = content
        lastMonitoringRefresh = now
        monitoringIsRefreshing = false
    }

    private func makeMonitoringContent(
        range: MonitoringRange,
        endingAt now: Date,
        limit: Int
    ) async throws -> MonitoringDisplayState {
        guard let store else { throw StoreError.cannotOpen("local history is unavailable") }
        let interval = range.interval(endingAt: now)
        let samples = try await store.samples(in: interval)
        let appResources = try await store.appResourceSamples(in: interval)
        let sleepWakeEvents = try await store.sleepWakeEvents(in: interval, includingPrevious: true)
        let snapshot = insights.makeMonitoringSnapshot(
            range: range,
            endingAt: now,
            samples: samples,
            appResourceSamples: appResources
        )
        let backgroundActivityPoints = insights.makeBackgroundActivityPoints(
            samples: appResources,
            systemSamples: samples,
            in: interval,
            limit: limit
        )
        let appContributors = insights.makeAppComputeContributors(
            samples: appResources,
            in: interval,
            limit: 3
        )
        let visibleEventDates = sleepWakeEvents
            .map(\.timestamp)
            .filter { interval.contains($0) }
        let dataThrough = (
            samples.map(\.timestamp)
                + appResources.map(\.timestamp)
                + visibleEventDates
        ).max()

        return MonitoringDisplayState(
            snapshot: snapshot,
            samples: samples,
            backgroundPoints: backgroundActivityPoints,
            events: sleepWakeEvents,
            appContributors: appContributors,
            dataThrough: dataThrough,
            refreshedAt: Date()
        )
    }

    @discardableResult
    private func beginMenuBarRefreshIfNeeded(endingAt now: Date) -> Task<Void, Never>? {
        if let menuBarRefreshTask { return menuBarRefreshTask }
        guard let store, !dataEraseInProgress else { return nil }

        menuBarRefreshGeneration &+= 1
        let generation = menuBarRefreshGeneration
        let refreshEpoch = dataEpoch
        let range = menuBarMonitoringRange
        menuBarIsRefreshing = true
        menuBarRefreshMessage = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await self.makeMonitoringContent(
                    range: range,
                    endingAt: now,
                    limit: 720
                )
                let sessionSamples = try await store.samples(
                    in: DateInterval(start: now.addingTimeInterval(-86_400), end: now)
                )
                let currentSession = TimelineSemantics.currentActivitySession(
                    from: sessionSamples,
                    endingAt: now
                )
                guard !Task.isCancelled,
                      generation == self.menuBarRefreshGeneration,
                      refreshEpoch == self.dataEpoch,
                      !self.dataEraseInProgress,
                      range == self.menuBarMonitoringRange else { return }
                self.menuBarMonitoringContent = content
                self.currentActivitySession = currentSession
            } catch {
                guard generation == self.menuBarRefreshGeneration else { return }
                self.menuBarRefreshMessage = self.menuBarMonitoringContent == nil
                    ? "Recent history could not be prepared just now."
                    : "Could not refresh just now. Cached history is still shown."
            }

            guard generation == self.menuBarRefreshGeneration else { return }
            self.menuBarIsRefreshing = false
            self.menuBarRefreshTask = nil
        }
        menuBarRefreshTask = task
        return task
    }

    private func generateReport(dayKey: String, publishAsToday: Bool) async throws {
        guard let store, let interval = DayBoundaries.interval(for: dayKey), !dataEraseInProgress else { return }
        let reportEpoch = dataEpoch
        let storeGeneration = await store.currentDataGeneration()
        guard reportEpoch == dataEpoch, !dataEraseInProgress else { return }
        let samples = try await store.samples(from: interval.start, to: interval.end)
        let processes = try await store.processSamples(from: interval.start, to: interval.end)
        let events = try await store.events(from: interval.start, to: interval.end)
        let history = try await store.reports(limit: 365).filter { $0.dayKey != dayKey }
        guard reportEpoch == dataEpoch, !dataEraseInProgress else { return }
        let report = insights.makeReport(dayKey: dayKey, timezone: .autoupdatingCurrent, samples: samples, processSamples: processes, events: events, historicalReports: history)
        if !samples.isEmpty {
            let saved = try await store.save(report: report, ifDataGeneration: storeGeneration)
            guard saved else { return }
        }
        guard reportEpoch == dataEpoch, !dataEraseInProgress else { return }
        if publishAsToday {
            todayReport = report
            todaySamples = samples
            todayChartSamples = downsample(samples, limit: 720)
            lastReportRefresh = Date()
            if notificationDeliveryEnabled {
                await NotificationCoordinator.shared.refreshNotifications(for: report)
                guard reportEpoch == dataEpoch, !dataEraseInProgress else { return }
            }
        }
        var all = try await store.reports(limit: 365)
        guard reportEpoch == dataEpoch, !dataEraseInProgress else { return }
        if publishAsToday, samples.isEmpty { all.insert(report, at: 0) }
        reports = all
        let completed = all.filter { $0.dayKey != DayBoundaries.key(for: Date()) }
        trend7 = insights.makeTrend(reports: completed, days: 7)
        trend30 = insights.makeTrend(reports: completed, days: 30)
    }

    private func finalizeUnreportedDays() async throws {
        guard let store else { return }
        let startOfToday = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        let timestamps = try await store.sampleTimestamps(before: startOfToday)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        var newestByKey: [String: Date] = [:]
        for timestamp in timestamps {
            let key = formatter.string(from: timestamp)
            newestByKey[key] = max(newestByKey[key] ?? .distantPast, timestamp)
        }
        for key in newestByKey.keys.sorted() {
            if let existing = try? await store.report(dayKey: key),
               let newest = newestByKey[key], existing.generatedAt >= newest { continue }
            try await generateReport(dayKey: key, publishAsToday: false)
        }
    }

    private func downsample(_ samples: [SystemSample], limit: Int) -> [SystemSample] {
        guard samples.count > limit else { return samples }
        let stride = Double(samples.count) / Double(limit)
        return (0..<limit).map { samples[min(samples.count - 1, Int(Double($0) * stride))] }
    }

    private func record(_ event: ActivityEvent) {
        guard let store, !dataEraseInProgress else { return }
        let eventEpoch = dataEpoch
        Task {
            guard eventEpoch == dataEpoch, !dataEraseInProgress else { return }
            let storeGeneration = await store.currentDataGeneration()
            guard eventEpoch == dataEpoch, !dataEraseInProgress else { return }
            do { try await store.save(event: event, ifDataGeneration: storeGeneration) }
            catch { await show(error) }
        }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: NSNotification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                Task { @MainActor in handler(notification) }
            }
            observers.append(token)
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard self.collectionReady, !self.isCurrentlyPaused else { return }
            let name = Self.safeName(app.localizedName)
            self.record(ActivityEvent(timestamp: Date(), type: .appLaunched, title: "App opened: \(name)", explanation: "macOS reported that \(name) launched. This records only the app identity, not what it displayed.", severity: .information))
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard self.collectionReady, !self.isCurrentlyPaused else { return }
            let name = Self.safeName(app.localizedName)
            self.record(ActivityEvent(timestamp: Date(), type: .appQuit, title: "App closed: \(name)", explanation: "macOS reported that \(name) quit.", severity: .information))
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard self.collectionReady, !self.isCurrentlyPaused else { return }
            let name = Self.safeName(app.localizedName)
            self.record(ActivityEvent(timestamp: Date(), type: .foregroundChanged, title: "Foreground changed to \(name)", explanation: "\(name) became the frontmost app. This does not imply attention or reveal the open window.", severity: .information))
        }
        observe(NSWorkspace.willSleepNotification) { [weak self] _ in
            guard let self else { return }
            guard self.collectionReady else { return }
            let wasCollecting = !self.isCurrentlyPaused
            self.collectionState = .sleeping
            self.prepareForCollectionGap()
            if wasCollecting {
                self.record(ActivityEvent(timestamp: Date(), type: .sleep, title: "Mac went to sleep", explanation: "Collection stopped for sleep; sleep time is excluded from active-use estimates.", severity: .information))
            }
        }
        observe(NSWorkspace.didWakeNotification) { [weak self] _ in
            guard let self else { return }
            guard self.collectionReady else { return }
            let paused = self.isCurrentlyPaused
            self.collectionState = paused ? .paused : .monitoring
            self.prepareForCollectionGap()
            if !paused {
                self.record(ActivityEvent(timestamp: Date(), type: .wake, title: "Mac woke", explanation: "Collection resumed with fresh counter baselines so sleep is not mistaken for activity.", severity: .information))
            }
            Task {
                do { try await self.finalizeUnreportedDays() }
                catch { await self.show(error) }
            }
        }
        let dayToken = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    let old = self.lastDayKey
                    self.lastDayKey = DayBoundaries.key(for: Date())
                    try await self.generateReport(dayKey: old, publishAsToday: false)
                    if let store = self.store {
                        try await RetentionCoordinator.finalizeThenRetain(store: store, settings: self.settings) {
                            try await self.finalizeUnreportedDays()
                        }
                        self.lastRetentionDate = Date()
                        self.databaseSize = await store.databaseSizeBytes()
                    }
                    try await self.refreshTodayReport(force: true)
                    try await self.refreshMonitoring(force: true)
                } catch {
                    await self.show(error)
                }
            }
        }
        observers.append(dayToken)
        let timezoneToken = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lastDayKey = DayBoundaries.key(for: Date())
                do {
                    try await self.refreshTodayReport(force: true)
                    try await self.refreshMonitoring(force: true)
                }
                catch { await self.show(error) }
            }
        }
        observers.append(timezoneToken)
        let activationToken = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.collectionReady else { return }
                self.updateLoginItemStatus()
                do { try await self.refreshMonitoring(force: false) }
                catch { await self.show(error) }
                guard self.settings.briefingNotificationsEnabled == true else { return }
                await self.configureBriefingNotifications()
            }
        }
        observers.append(activationToken)
    }

    private func updateLoginItemStatus() {
        let status = SMAppService.mainApp.status
        loginItemEnabled = status == .enabled
        loginItemNeedsApproval = status == .requiresApproval
    }

    private func configureBriefingNotifications() async {
        notificationConfigurationGeneration &+= 1
        let generation = notificationConfigurationGeneration
        guard settings.briefingNotificationsEnabled == true else {
            NotificationCoordinator.shared.setDeliveryActive(false)
            return
        }
        NotificationCoordinator.shared.setDeliveryActive(true)
        let authorization = await NotificationCoordinator.shared.prepareIfAppropriate()
        guard generation == notificationConfigurationGeneration,
              settings.briefingNotificationsEnabled == true else { return }
        switch authorization {
        case .enabled:
            notificationDeliveryEnabled = true
            notificationNeedsApproval = false
            notificationStatusDetail = "Private report-ready notifications are on. MY MACHINE sends one when the first reliable briefing is ready, then around 18:00 on later days. Lock-screen text never includes app names, process names, metrics, or report details."
            if let todayReport {
                await NotificationCoordinator.shared.refreshNotifications(for: todayReport)
            }
        case .denied:
            NotificationCoordinator.shared.setDeliveryActive(false)
            notificationDeliveryEnabled = false
            notificationNeedsApproval = true
            notificationStatusDetail = "macOS notifications are off for MY MACHINE. Monitoring still works; Notification Settings can enable private report-ready alerts."
        case .inactive:
            NotificationCoordinator.shared.setDeliveryActive(false)
            notificationDeliveryEnabled = false
            notificationNeedsApproval = false
            notificationStatusDetail = "Notifications activate automatically after MY MACHINE is installed in Applications. Monitoring is unaffected."
        case .failed:
            NotificationCoordinator.shared.setDeliveryActive(false)
            notificationDeliveryEnabled = false
            notificationNeedsApproval = false
            notificationStatusDetail = "MY MACHINE could not confirm notification delivery. Monitoring and local reports continue normally."
        }
    }

    private func attemptLoginRegistrationIfAppropriate() {
        guard ApplicationInstallation.isCanonicalApplicationsInstall,
              ProcessInfo.processInfo.environment["DAILYMAC_DISABLE_LOGIN_REGISTRATION"] != "1",
              settings.launchAtLoginPreference == true,
              SMAppService.mainApp.status == .notRegistered else { return }
        do { try SMAppService.mainApp.register() }
        catch { errorMessage = "MY MACHINE could not enable Launch at Login automatically: \(error.localizedDescription)" }
        updateLoginItemStatus()
    }

    private func prepareForCollectionGap() {
        needsFreshBaseline = true
        detector.resetAfterGap()
    }

    private func clearPublishedHistory() {
        monitoringRefreshGeneration &+= 1
        menuBarRefreshGeneration &+= 1
        menuBarRefreshTask?.cancel()
        menuBarRefreshTask = nil
        todayReport = nil
        currentActivitySession = nil
        todaySamples = []
        todayChartSamples = []
        monitoringContent = nil
        monitoringIsRefreshing = false
        menuBarMonitoringContent = nil
        menuBarIsRefreshing = false
        menuBarRefreshMessage = nil
        reports = []
        processImpacts = []
        latestSystem = nil
        lastUpdated = nil
        lastReportRefresh = nil
        lastMonitoringRefresh = nil
        lastSampleTimestamp = nil
        databaseSize = 0
        processCoverage = "Process attribution has not been sampled yet."
        trend7 = TrendSummary(days: 7, activeDuration: 0, averageDailyCPU: 0, mostUsedCategory: nil, notableChange: nil, narrative: "Building a baseline.")
        trend30 = TrendSummary(days: 30, activeDuration: 0, averageDailyCPU: 0, mostUsedCategory: nil, notableChange: nil, narrative: "Building a baseline.")
    }

    private func restoreCriticalPreferencesIfPresent() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.consentKey) != nil {
            settings.collectionConsentGranted = defaults.bool(forKey: Self.consentKey)
        }
        if defaults.object(forKey: Self.pauseFlagKey) != nil {
            settings.isPaused = defaults.bool(forKey: Self.pauseFlagKey)
            settings.pauseUntil = defaults.object(forKey: Self.pauseUntilKey) as? Date
        }
        if defaults.object(forKey: Self.loginPreferenceKey) != nil {
            settings.launchAtLoginPreference = defaults.bool(forKey: Self.loginPreferenceKey)
        }
        if defaults.object(forKey: Self.notificationPreferenceKey) != nil {
            settings.briefingNotificationsEnabled = defaults.bool(forKey: Self.notificationPreferenceKey)
        }
    }

    private func persistCriticalPreferencesSynchronously() {
        let defaults = UserDefaults.standard
        defaults.set(settings.hasCollectionConsent, forKey: Self.consentKey)
        defaults.set(settings.isPaused, forKey: Self.pauseFlagKey)
        if let pauseUntil = settings.pauseUntil { defaults.set(pauseUntil, forKey: Self.pauseUntilKey) }
        else { defaults.removeObject(forKey: Self.pauseUntilKey) }
        if let preference = settings.launchAtLoginPreference { defaults.set(preference, forKey: Self.loginPreferenceKey) }
        else { defaults.removeObject(forKey: Self.loginPreferenceKey) }
        if let preference = settings.briefingNotificationsEnabled { defaults.set(preference, forKey: Self.notificationPreferenceKey) }
        else { defaults.removeObject(forKey: Self.notificationPreferenceKey) }
        defaults.synchronize()
    }

    private func show(_ error: Error) async {
        monitoringIsRefreshing = false
        stopMonitorLoop()
        collectionReady = false
        let message: String
        if case StoreError.cleanupIncomplete = error {
            message = error.localizedDescription
        } else {
            message = Self.friendlyStorageError
        }
        errorMessage = message
        collectionState = .failed(message)
    }

    private static func safeName(_ value: String?) -> String {
        let clean = (value ?? "Application").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(clean).prefix(120))
    }

    private static let friendlyStorageError = "MY MACHINE could not safely update its local history, so monitoring stopped rather than showing incomplete conclusions. Existing data remains on this Mac. Quit and reopen the app; if this returns, the data folder in Settings can be preserved or removed before a fresh start."
    private static let consentKey = "collectionConsentGranted"
    private static let pauseFlagKey = "privacyPauseEnabled"
    private static let pauseUntilKey = "privacyPauseUntil"
    private static let loginPreferenceKey = "launchAtLoginPreference"
    private static let notificationPreferenceKey = "briefingNotificationsEnabled"
}
