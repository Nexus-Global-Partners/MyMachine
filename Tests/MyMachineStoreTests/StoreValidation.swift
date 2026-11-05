import Darwin
import Foundation

@main
@MainActor
struct StoreValidation {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ detail: String) { errorDescription = detail }
    }

    private final class MemoryPreferences: UserDefaults {
        private var enabled = false

        override func bool(forKey defaultName: String) -> Bool { enabled }
        override func set(_ value: Bool, forKey defaultName: String) { enabled = value }
        override func synchronize() -> Bool { true }
    }

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let base: URL
            switch arguments.first {
            case "--sandbox" where arguments.count == 2:
                let support = try StoreHistory.containerDirectory().deletingLastPathComponent()
                guard let id = Bundle.main.bundleIdentifier,
                      support.path.contains("/Library/Containers/\(id)/Data/") else {
                    throw Failure("Launch did not resolve Application Support inside the validation app container.")
                }
                let outside = URL(fileURLWithPath: arguments[1])
                do {
                    try Data("outside".utf8).write(to: outside)
                } catch {
                    // The script has already verified that this test path is writable
                    // from the parent process. The sandbox app must be denied.
                    print("PASS  container path and blocked out-of-container write")
                }
                guard !FileManager.default.fileExists(atPath: outside.path) else {
                    throw Failure("Validation app wrote outside its container without a Save Panel grant.")
                }
                base = support
            case "--fixtures" where arguments.count == 2:
                base = URL(fileURLWithPath: arguments[1], isDirectory: true)
            default:
                throw Failure("Provide --fixtures DIRECTORY or --sandbox OUTSIDE_TEST_FILE.")
            }

            let fixtures = base.appendingPathComponent("StoreValidation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixtures) }

            try await validateHistory(in: fixtures.appendingPathComponent("history"))
            try await validateLifecycle(in: fixtures.appendingPathComponent("lifecycle"))
            try await validatePendingErase(in: fixtures.appendingPathComponent("erase"))
            print("Store validation passed.")
        } catch {
            FileHandle.standardError.write(Data("FAIL  \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func validateHistory(in directory: URL) async throws {
        let history = try StoreHistory(directory: directory)
        let now = Date()
        let beforeRetention = makeReading(at: now.addingTimeInterval(-StoreHistory.retentionWindow - 1), cpu: 42)
        let unavailable = makeReading(at: now.addingTimeInterval(-12), cpu: nil)
        let observedZero = makeReading(at: now.addingTimeInterval(-1), cpu: 0)
        let sleep = StoreSleepSpan(start: now.addingTimeInterval(-10), end: now.addingTimeInterval(-2))
        let firstSaved = try await history.append(beforeRetention, sleep: [])
        let secondSaved = try await history.append(unavailable, sleep: [])
        let thirdSaved = try await history.append(observedZero, sleep: [sleep])
        try check(firstSaved && secondSaved && thirdSaved, "Fixture samples failed to persist.")

        try await history.prune(at: now)
        let loaded = try await history.load(at: now)
        let all = try await history.database.samples(from: .distantPast, to: .distantFuture)
        try check(all.count == 2, "Retention did not remove the expired row from the database.")
        try check(loaded.readings.map(\.id) == [unavailable.id, observedZero.id], "History lost its sample order.")
        try check(loaded.readings[0].cpuPercent == nil && loaded.readings[0].memoryTotal == nil,
                  "Unavailable measurements were converted to zero.")
        try check(loaded.readings[1].cpuPercent == 0, "A measured zero was lost.")
        try check(loaded.sleep.map(\.id) == [sleep.id], "Paired sleep events were lost.")
        try check(StoreSleepSpan.observedSpans(from: [sleep.events[1]]).isEmpty, "An unpaired wake became confirmed sleep.")
        try check(all.allSatisfy {
            $0.foregroundApp.isEmpty && $0.foregroundBundleID == nil && $0.manualActivity == nil &&
                $0.fanRPM == nil && $0.gpuPercent == nil && $0.performanceCorePercent == nil
        }, "A Store row contained excluded app or sensor data.")
        let csv = StoreHistory.csv(readings: loaded.readings, sleep: loaded.sleep)
        let rows = csv.split(separator: "\n")
        try check(rows.count == 5 && rows.allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 9 },
                  "CSV lost a column or an event.")
        try check(csv.contains(",sleep,") && csv.contains(",wake,") && csv.contains(",sample,0.0,"),
                  "CSV did not preserve sleep and measured zero.")
        print("PASS  private history, retention, missing values, sleep pairs, CSV")
    }

    private static func validateLifecycle(in directory: URL) async throws {
        let preferences = MemoryPreferences()
        var monitor: StoreMonitor? = StoreMonitor(
            defaults: preferences, directory: directory, samplingInterval: .milliseconds(250), observeSleep: false
        )
        try await validateRecording(monitor!)
        monitor = nil

        let reopened = StoreMonitor(defaults: preferences, directory: directory, observeSleep: false)
        await reopened.prepare()
        try check(reopened.state == .ready && !reopened.readings.isEmpty, "Pause or history did not survive relaunch.")
        await reopened.eraseHistory()
        try check(reopened.state == .ready && reopened.readings.isEmpty && reopened.sleepSpans.isEmpty,
                  "Explicit erase did not clear readings and sleep.")
        print("PASS  consent, live CPU and memory, sleep/wake, pause, relaunch, erase")
    }

    private static func validateRecording(_ monitor: StoreMonitor) async throws {
        await monitor.prepare()
        try await Task.sleep(for: .milliseconds(300))
        try check(monitor.state == .ready && monitor.readings.isEmpty,
                  "Fresh launch recorded before Start Monitoring.")
        monitor.startMonitoring()
        try await waitFor("No valid live CPU and memory readings.") {
            monitor.readings.contains { reading in
                guard let cpu = reading.cpuPercent, let used = reading.memoryUsed,
                      let total = reading.memoryTotal else { return false }
                return (0...100).contains(cpu) && total > 0 && used <= total
            }
        }
        try check(monitor.readings.first?.cpuPercent == nil, "The initial CPU baseline was presented as a reading.")

        monitor.willSleep()
        try await Task.sleep(for: .milliseconds(300))
        let beforeWake = monitor.readings.count
        try await Task.sleep(for: .milliseconds(400))
        try check(monitor.state == .sleeping && monitor.readings.count == beforeWake,
                  "Monitoring continued during sleep.")
        monitor.didWake()
        try await waitFor("Sleep/wake events did not reach the history.") { !monitor.sleepSpans.isEmpty }
        try check(monitor.readings[beforeWake].cpuPercent == nil, "Wake reused a pre-sleep CPU baseline.")
        monitor.pauseMonitoring()
        try await Task.sleep(for: .milliseconds(300))
        let paused = monitor.readings.count
        try await Task.sleep(for: .milliseconds(400))
        try check(monitor.state == .ready && monitor.readings.count == paused,
                  "Monitoring continued after pause.")
    }

    private static func validatePendingErase(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try LocalEraseReceipt.requested.persist(in: directory)
        let preferences = MemoryPreferences()
        preferences.set(true, forKey: "storeMonitoringEnabled")
        let monitor = StoreMonitor(defaults: preferences, directory: directory, observeSleep: false)
        await monitor.prepare()
        monitor.startMonitoring()
        try check(monitor.state == .cleanupRequired && monitor.readings.isEmpty,
                  "A pending erase did not block auto-resume and manual start.")
        await monitor.eraseHistory()
        try check(monitor.state == .ready && !preferences.bool(forKey: "storeMonitoringEnabled"),
                  "Cleanup did not require a fresh Start Monitoring action.")
        print("PASS  pending erase blocks recording across relaunch")
    }

    private static func makeReading(at date: Date, cpu: Double?) -> StoreReading {
        StoreReading(timestamp: date, cpuPercent: cpu, cpuDuration: cpu == nil ? 0 : 1,
                     memoryUsed: nil, memoryTotal: nil, batteryPercent: nil, powerSource: .unknown,
                     isCharging: nil, thermal: .unknown)
    }

    private static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while !condition() && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(condition(), message)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }
}
