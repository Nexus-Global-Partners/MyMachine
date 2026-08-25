import AppKit
import DailyMacCore
import Foundation
@preconcurrency import UserNotifications

enum BriefingNotificationAuthorization: Equatable {
    case inactive
    case enabled
    case denied
    case failed
}

@MainActor
final class AppRoute: ObservableObject {
    static let shared = AppRoute()

    @Published private(set) var monitoringRequestGeneration = 0
    private var pendingMonitoringRequest = false

    private init() {}

    func requestMonitoring() {
        pendingMonitoringRequest = true
        monitoringRequestGeneration &+= 1
    }

    func consumeMonitoringRequest() -> Bool {
        guard pendingMonitoringRequest else { return false }
        pendingMonitoringRequest = false
        return true
    }
}

@MainActor
final class NotificationCoordinator: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    private let center = UNUserNotificationCenter.current()
    private let firstBriefingIdentifier = "my-machine-first-briefing"
    private let dailyBriefingIdentifier = "my-machine-daily-briefing"
    private let legacyIdentifiers = ["daily-mac-first-briefing", "daily-mac-daily-briefing"]
    private let firstBriefingScheduledKey = "firstBriefingNotificationScheduled"
    private let firstBriefingDayKey = "firstBriefingNotificationDay"
    private var deliveryActive = false
    private var reconciliationGeneration = 0
    private var isReconciling = false
    private var needsReconciliation = false
    private var latestReport: DailyReport?

    private override init() {
        super.init()
    }

    func configureDelegate() {
        center.delegate = self
    }

    func setDeliveryActive(_ active: Bool) {
        reconciliationGeneration &+= 1
        deliveryActive = active
        if active {
            needsReconciliation = latestReport != nil
        } else {
            latestReport = nil
            needsReconciliation = false
            removeReportNotifications()
        }
    }

    func prepareIfAppropriate() async -> BriefingNotificationAuthorization {
        guard ApplicationInstallation.isCanonicalApplicationsInstall,
              ProcessInfo.processInfo.environment["DAILYMAC_DISABLE_NOTIFICATIONS"] != "1" else {
            return .inactive
        }

        configureDelegate()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return .enabled
        case .denied:
            return .denied
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                return granted ? .enabled : .denied
            } catch {
                return .failed
            }
        @unknown default:
            return .failed
        }
    }

    func refreshNotifications(for report: DailyReport) async {
        latestReport = report
        needsReconciliation = true
        guard deliveryActive, !isReconciling else { return }

        isReconciling = true
        defer { isReconciling = false }
        while deliveryActive, needsReconciliation {
            needsReconciliation = false
            guard let latestReport else { break }
            let generation = reconciliationGeneration
            await reconcile(report: latestReport, generation: generation)
            if deliveryActive, generation != reconciliationGeneration {
                needsReconciliation = true
            }
        }
    }

    func cancelReportNotifications() {
        reconciliationGeneration &+= 1
        latestReport = nil
        needsReconciliation = false
        removeReportNotifications()
    }

    private func reconcile(report: DailyReport, generation: Int) async {
        guard isCurrent(generation),
              let copy = BriefingNotificationPolicy.privateNotificationCopy(for: report) else { return }
        let settings = await center.notificationSettings()
        guard isCurrent(generation),
              settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional else { return }

        await scheduleFirstBriefingIfNeeded(copy: copy, generation: generation)
        guard isCurrent(generation) else { return }
        await scheduleDailyBriefing(copy: copy, generation: generation)
    }

    private func scheduleFirstBriefingIfNeeded(copy: (title: String, body: String), generation: Int) async {
        let defaults = UserDefaults.standard
        guard isCurrent(generation) else { return }
        let firstBriefingAlreadyAttempted = defaults.bool(forKey: firstBriefingScheduledKey)

        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let existingIdentifiers = Set(
            pending.map(\.identifier) + delivered.map { $0.request.identifier }
        )
        guard isCurrent(generation) else { return }
        if existingIdentifiers.contains(firstBriefingIdentifier) ||
            existingIdentifiers.contains(legacyIdentifiers[0]) {
            persistFirstBriefingScheduled(defaults: defaults)
            center.removePendingNotificationRequests(withIdentifiers: [dailyBriefingIdentifier])
            return
        }
        // A prior process may have committed the one-time attempt immediately
        // before it exited. Do not risk a duplicate immediate alert. Because the
        // successful-delivery day was not persisted, reconciliation can still
        // schedule the normal end-of-day briefing below.
        guard !firstBriefingAlreadyAttempted else { return }

        let content = notificationContent(title: copy.title, body: copy.body)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 8, repeats: false)
        let request = UNNotificationRequest(identifier: firstBriefingIdentifier, content: content, trigger: trigger)
        // Commit the one-time decision before handing the request to macOS. If the
        // app is terminated immediately after acceptance, a later launch must not
        // infer that the first briefing was never scheduled and send it again.
        // A reported scheduling failure, or an intentional cancellation while the
        // request is in flight, rolls the sentinel back so a real retry stays possible.
        persistFirstBriefingAttempt(defaults: defaults)
        do {
            try await center.add(request)
            guard isCurrent(generation) else {
                center.removePendingNotificationRequests(withIdentifiers: [firstBriefingIdentifier])
                center.removeDeliveredNotifications(withIdentifiers: [firstBriefingIdentifier])
                clearFirstBriefingScheduled(defaults: defaults)
                return
            }
            persistFirstBriefingScheduled(defaults: defaults)
            // If an earlier transient first-alert failure left today's 18:00
            // fallback pending, the successful immediate briefing replaces it.
            center.removePendingNotificationRequests(withIdentifiers: [dailyBriefingIdentifier])
        } catch {
            clearFirstBriefingScheduled(defaults: defaults)
            return
        }
    }

    private func scheduleDailyBriefing(copy: (title: String, body: String), generation: Int) async {
        let now = Date()
        let defaults = UserDefaults.standard
        let today = DayBoundaries.key(for: now)
        guard isCurrent(generation),
              defaults.string(forKey: firstBriefingDayKey) != today,
              let delivery = BriefingNotificationPolicy.nextDailyDelivery(after: now) else { return }
        let deliveryDay = DayBoundaries.key(for: delivery)
        guard deliveryDay == today else { return }
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: delivery)
        let content = notificationContent(title: copy.title, body: copy.body)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: dailyBriefingIdentifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
            guard isCurrent(generation) else {
                center.removePendingNotificationRequests(withIdentifiers: [dailyBriefingIdentifier])
                center.removeDeliveredNotifications(withIdentifiers: [dailyBriefingIdentifier])
                return
            }
        } catch {
            return
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        deliveryActive && generation == reconciliationGeneration
    }

    private func persistFirstBriefingScheduled(defaults: UserDefaults) {
        defaults.set(true, forKey: firstBriefingScheduledKey)
        defaults.set(DayBoundaries.key(for: Date()), forKey: firstBriefingDayKey)
        defaults.synchronize()
    }

    private func persistFirstBriefingAttempt(defaults: UserDefaults) {
        defaults.set(true, forKey: firstBriefingScheduledKey)
        defaults.removeObject(forKey: firstBriefingDayKey)
        defaults.synchronize()
    }

    private func clearFirstBriefingScheduled(defaults: UserDefaults) {
        defaults.removeObject(forKey: firstBriefingScheduledKey)
        defaults.removeObject(forKey: firstBriefingDayKey)
        defaults.synchronize()
    }

    private func removeReportNotifications() {
        let identifiers = [firstBriefingIdentifier, dailyBriefingIdentifier] + legacyIdentifiers
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func notificationContent(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "my-machine-briefings"
        content.userInfo = ["destination": "today"]
        return content
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let allowedIdentifiers = Set([firstBriefingIdentifier, dailyBriefingIdentifier] + legacyIdentifiers)
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              allowedIdentifiers.contains(response.notification.request.identifier) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            AppRoute.shared.requestMonitoring()
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}

@MainActor
final class DailyMacApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCoordinator.shared.configureDelegate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppRoute.shared.requestMonitoring()
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
}
