import DailyMacCore
import CoreGraphics
import Darwin
import Foundation
import SQLite3

enum ValidationFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

final class ValidationHarness {
    private(set) var passed = 0
    private(set) var failed = 0

    func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("PASS  \(name)")
        } catch {
            failed += 1
            print("FAIL  \(name): \(error)")
        }
    }

    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ValidationFailure.failed(message) }
    }
}

@main
struct DailyMacValidation {
    static func main() async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        print("MY MACHINE validation starting")
        let harness = ValidationHarness()

        await harness.run("DST and local-day boundaries") {
            let timezone = try require(TimeZone(identifier: "America/Los_Angeles"), "timezone unavailable")
            let spring = try require(DayBoundaries.interval(for: "2026-03-08", timezone: timezone), "spring interval unavailable")
            let fall = try require(DayBoundaries.interval(for: "2026-11-01", timezone: timezone), "fall interval unavailable")
            try harness.check(abs(spring.duration - 23 * 60 * 60) < 1, "spring-forward day was not 23 hours")
            try harness.check(abs(fall.duration - 25 * 60 * 60) < 1, "fall-back day was not 25 hours")
        }

        await harness.run("rolling ranges use absolute elapsed time") {
            let timezone = try require(TimeZone(identifier: "America/Los_Angeles"), "timezone unavailable")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timezone
            let end = try require(
                calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)),
                "rolling-range fixture unavailable"
            )
            let expected: [(MonitoringRange, TimeInterval)] = [
                (.oneHour, 3_600),
                (.sixHours, 21_600),
                (.twentyFourHours, 86_400)
            ]
            for (range, duration) in expected {
                let interval = range.interval(endingAt: end)
                try harness.check(interval.end == end, "\(range.label) range changed its captured end")
                try harness.check(abs(interval.duration - duration) < 0.001, "\(range.label) was treated as a calendar interval")
            }
        }

        await harness.run("permission-free manual activity counters use safe deltas") {
            try harness.check(
                TelemetrySemantics.eventCounterDelta(current: 105, previous: 100) == 5,
                "ordinary event-counter delta was inaccurate"
            )
            try harness.check(
                TelemetrySemantics.eventCounterDelta(current: 3, previous: UInt32.max - 2) == 6,
                "event-counter rollover was not handled"
            )
            try harness.check(
                TelemetrySemantics.eventCounterDelta(current: 5, previous: 500) == nil,
                "WindowServer-style counter reset was mistaken for a huge activity burst"
            )

            let quiet = ManualActivityCounts(keyboardEvents: 0, pointerEvents: 0, clickEvents: 0, scrollEvents: 0)
            let active = ManualActivityCounts(keyboardEvents: 45, pointerEvents: 900, clickEvents: 12, scrollEvents: 300)
            try harness.check(quiet.intensity(over: 15) == 0, "measured quiet interval did not produce zero intensity")
            try harness.check(active.intensity(over: 15) > 0.5 && active.intensity(over: 15) <= 1, "active interval did not produce a bounded intensity")

            let sampler = TelemetrySampler()
            let first = await sampler.sample(settings: .default, now: Date(timeIntervalSince1970: 1_780_000_000))
            let second = await sampler.sample(settings: .default, now: Date(timeIntervalSince1970: 1_780_000_001))
            try harness.check(first.system.manualActivity == nil, "first cumulative counter reading was presented as interval activity")
            try harness.check(second.system.manualActivity != nil, "second cumulative counter reading did not produce content-free deltas")
            if let gpu = second.system.gpuPercent {
                try harness.check((0...100).contains(gpu), "graphics-driver activity escaped its honest percentage range")
            }
            let coreValues = [
                second.system.performanceCorePercent,
                second.system.efficiencyCorePercent,
                second.system.performanceCoreContributionPercent
            ]
            let hasHeterogeneousCores = (sysctlInteger("hw.perflevel1.logicalcpu") ?? 0) > 0
            if hasHeterogeneousCores {
                try harness.check(coreValues.allSatisfy { $0 != nil }, "Apple Silicon core clusters were not measured")
            } else {
                try harness.check(coreValues.allSatisfy { $0 == nil }, "unsupported core topology produced a guessed split")
            }
            if let performance = second.system.performanceCorePercent,
               let efficiency = second.system.efficiencyCorePercent,
               let contribution = second.system.performanceCoreContributionPercent {
                try harness.check((0...100).contains(performance), "performance-core utilization escaped its honest range")
                try harness.check((0...100).contains(efficiency), "efficiency-core utilization escaped its honest range")
                try harness.check(contribution >= 0 && contribution <= second.system.cpuPercent + 0.001, "core contribution exceeded aggregate CPU")
            }
            await sampler.resetDeltas()
            let afterReset = await sampler.sample(settings: .default, now: Date(timeIntervalSince1970: 1_780_000_002))
            try harness.check(afterReset.system.manualActivity == nil, "counter reset did not restore baseline semantics")
        }

        await harness.run("legacy Codable samples default manual activity to unavailable") {
            let original = sample(
                manualActivity: ManualActivityCounts(
                    keyboardEvents: 8,
                    pointerEvents: 80,
                    clickEvents: 3,
                    scrollEvents: 20
                )
            )
            let encoded = try JSONEncoder().encode(original)
            var object = try require(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                "sample JSON was not an object"
            )
            object.removeValue(forKey: "manualActivity")
            object.removeValue(forKey: "gpuPercent")
            object.removeValue(forKey: "performanceCorePercent")
            object.removeValue(forKey: "efficiencyCorePercent")
            object.removeValue(forKey: "performanceCoreContributionPercent")
            let legacyPayload = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(SystemSample.self, from: legacyPayload)
            try harness.check(decoded.manualActivity == nil, "missing legacy manual-activity field did not decode as unavailable")
            try harness.check(decoded.gpuPercent == nil, "missing legacy graphics field did not decode as unavailable")
            try harness.check(
                decoded.performanceCorePercent == nil
                    && decoded.efficiencyCorePercent == nil
                    && decoded.performanceCoreContributionPercent == nil,
                "missing legacy core-cluster fields did not decode as unavailable"
            )
        }

        await harness.run("mixed core telemetry stays aggregate-only") {
            let measured = sample(
                cpu: 40,
                performanceCore: 55,
                efficiencyCore: 30,
                performanceContribution: 18
            )
            let legacyOrUnavailable = sample(cpu: 80)
            try harness.check(
                CoreDistributionSemantics.hasCompleteCoverage(in: [measured]),
                "a complete measured core reading was withheld"
            )
            try harness.check(
                !CoreDistributionSemantics.hasCompleteCoverage(in: [measured, legacyOrUnavailable]),
                "a mixed measured/unavailable bucket invented a per-core split"
            )
        }

        await harness.run("rolling SQLite boundaries follow sample interval ends") {
            let directory = temporaryDirectory(prefix: "DailyMacRollingBoundary")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let end = start.addingTimeInterval(3_600)
            for timestamp in [start, start.addingTimeInterval(1), end, end.addingTimeInterval(1)] {
                try await store.save(sample: sample(at: timestamp), processes: [])
            }
            let selected = try await store.samples(in: DateInterval(start: start, end: end))
            try harness.check(selected.count == 2, "rolling query did not apply an open-start, closed-end boundary")
            try harness.check(selected.first?.timestamp == start.addingTimeInterval(1), "rolling query included the sample ending at the window start")
            try harness.check(selected.last?.timestamp == end, "rolling query excluded the sample ending at the captured end")
        }

        await harness.run("rolling snapshots clip boundary samples and withhold sparse claims") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let end = start.addingTimeInterval(3_600)
            let baseline = sample(at: start.addingTimeInterval(5), duration: 0, interval: 60, app: "Baseline", cpu: 0)
            let clipped = sample(at: start.addingTimeInterval(10), duration: 60, interval: 60, app: "App A", bundle: "example.a", cpu: 100, pressure: .elevated)
            let full = sample(at: start.addingTimeInterval(70), duration: 60, interval: 60, app: "App B", bundle: "example.b", cpu: 0)
            let afterEnd = sample(at: end.addingTimeInterval(1), duration: 60, interval: 60, app: "Outside", cpu: 100)
            let engine = InsightEngine()
            let sparse = engine.makeMonitoringSnapshot(range: .oneHour, endingAt: end, samples: [baseline, clipped, full, afterEnd])
            try harness.check(sparse.sampleCount == 2, "baseline-only reading was counted as a usable rolling sample")
            try harness.check(abs(sparse.observedDuration - 70) < 0.001, "sample crossing the rolling cutoff was not clipped")
            try harness.check(abs(sparse.activeDuration - 70) < 0.001, "clipped active duration was inaccurate")
            try harness.check(abs(sparse.averageCPU - (1_000 / 70)) < 0.001, "rolling CPU average did not use clipped duration")
            try harness.check(abs(sparse.elevatedMemoryDuration - 10) < 0.001, "elevated-memory duration was not clipped")
            try harness.check(sparse.totalDiskBytes == 1_750_000, "rolling disk total did not proportionally clip its boundary interval")
            try harness.check(sparse.totalNetworkBytes == 2_625_000, "rolling network total did not proportionally clip its boundary interval")
            try harness.check(sparse.applications.first?.name == "App B", "top application ignored clipped duration")
            try harness.check(!sparse.supportsNarrative, "a clipped 70-second fragment passed the evidence gate")
            try harness.check(sparse.insights.count == 1 && sparse.insights[0].title.contains("Building"), "sparse rolling data produced performance conclusions")

            let third = sample(at: start.addingTimeInterval(130), duration: 60, interval: 60, app: "App B", bundle: "example.b", cpu: 10)
            let supported = engine.makeMonitoringSnapshot(range: .oneHour, endingAt: end, samples: [baseline, clipped, full, third])
            try harness.check(supported.supportsNarrative, "130 seconds of genuine continuous coverage did not pass the evidence gate")
            try harness.check(supported.insights.count <= 3, "rolling snapshot emitted too many concise insights")
            let prose = supported.insights.flatMap { [$0.title, $0.explanation] }.joined(separator: " ").lowercased()
            for forbidden in ["today", "tomorrow", "productivity", "caused"] {
                try harness.check(!prose.contains(forbidden), "rolling insight used daily or unsupported wording: \(forbidden)")
            }
        }

        await harness.run("rolling gauge changes require defensible runs") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let end = start.addingTimeInterval(3_600)
            var samples: [SystemSample] = []
            for index in 1...6 {
                let item = sample(
                    at: start.addingTimeInterval(Double(index) * 600),
                    duration: 600,
                    interval: 600,
                    pressure: index <= 2 ? .elevated : .low,
                    swap: UInt64(index - 1) * 200_000_000,
                    battery: Double(81 - index),
                    power: .battery,
                    charging: false
                )
                samples.append(item)
            }
            let engine = InsightEngine()
            let continuous = engine.makeMonitoringSnapshot(range: .oneHour, endingAt: end, samples: samples)
            try harness.check(continuous.swapChangeBytes == 1_000_000_000, "continuous swap change was not retained")
            try harness.check(continuous.batteryChangePercent == -5, "continuous discharging run was not summarized")
            try harness.check(abs(continuous.elevatedMemoryDuration - 1_200) < 0.001, "elevated-memory duration was inaccurate")

            let gapped = engine.makeMonitoringSnapshot(range: .oneHour, endingAt: end, samples: [samples[0], samples[1], samples[4], samples[5]])
            try harness.check(gapped.swapChangeBytes == nil, "swap change was inferred across an unobserved gap")
        }

        await harness.run("rolling chart stays bounded without hiding spikes or gaps") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let end = start.addingTimeInterval(86_400)
            var samples: [SystemSample] = []
            var timestamp = start.addingTimeInterval(15)
            for index in 0..<1_000 {
                if index == 500 { timestamp = timestamp.addingTimeInterval(300) }
                samples.append(sample(
                    at: timestamp,
                    duration: 15,
                    interval: 15,
                    cpu: index == 333 ? 99 : Double(index % 70),
                    pressure: index == 444 ? .high : .low
                ))
                timestamp = timestamp.addingTimeInterval(15)
            }
            let points = InsightEngine().makeMonitoringChartPoints(
                samples: samples,
                in: DateInterval(start: start, end: end),
                limit: 60
            )
            try harness.check(points.count <= 60, "rolling chart exceeded its point budget")
            try harness.check(points.first?.timestamp == samples.first?.timestamp && points.last?.timestamp == samples.last?.timestamp, "rolling chart lost a window endpoint")
            try harness.check(points.contains { $0.cpuPercent == 99 }, "rolling chart downsampling hid the CPU spike")
            try harness.check(points.contains { $0.memoryPressure == .high }, "rolling chart downsampling hid elevated memory pressure")
            try harness.check(Set(points.map(\.segment)).count >= 2, "rolling chart bridged an unobserved gap")
        }

        await harness.run("rolling chart preserves non-CPU events for every metric mode") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let end = start.addingTimeInterval(4_000)
            var samples: [SystemSample] = []
            for index in 1...240 {
                samples.append(sample(
                    at: start.addingTimeInterval(Double(index) * 15),
                    duration: 15,
                    interval: 15,
                    cpu: index == 40 ? 98 : 20,
                    memory: index == 70 ? 15_500_000_000 : 8_000_000_000,
                    pressure: index == 90 ? .high : .low,
                    thermal: index == 150 ? .serious : .nominal,
                    battery: index == 180 ? 12 : 75,
                    diskRead: index == 110 ? 9_000_000_000 : 1_000,
                    diskWrite: 0,
                    networkReceived: index == 130 ? 8_000_000_000 : 1_000,
                    networkSent: 0,
                    manualActivity: ManualActivityCounts(
                        keyboardEvents: index == 195 ? 500 : 1,
                        pointerEvents: index == 200 ? 10_000 : 1,
                        clickEvents: index == 205 ? 200 : 1,
                        scrollEvents: index == 210 ? 8_000 : 1
                    )
                ))
            }
            let points = InsightEngine().makeMonitoringChartPoints(
                samples: samples,
                in: DateInterval(start: start, end: end),
                limit: 36
            )
            try harness.check(points.count <= 36, "multi-metric chart exceeded its point budget")
            try harness.check(points.contains { $0.cpuPercent == 98 }, "CPU extreme disappeared")
            try harness.check(points.contains { $0.memoryUsedBytes == 15_500_000_000 }, "memory extreme disappeared")
            try harness.check(points.contains { $0.memoryPressure == .high }, "pressure event disappeared")
            try harness.check(points.contains { $0.diskReadBytes == 9_000_000_000 }, "disk burst disappeared")
            try harness.check(points.contains { $0.networkReceivedBytes == 8_000_000_000 }, "network burst disappeared")
            try harness.check(points.contains { $0.batteryPercent == 12 }, "battery extreme disappeared")
            try harness.check(points.contains { $0.thermalLevel == .serious }, "thermal concern disappeared")
            try harness.check(points.contains { $0.manualActivity?.keyboardEvents == 500 }, "keyboard-activity extreme disappeared")
            try harness.check(points.contains { $0.manualActivity?.pointerEvents == 10_000 }, "pointer-activity extreme disappeared")
            try harness.check(points.contains { $0.manualActivity?.clickEvents == 200 }, "click-activity extreme disappeared")
            try harness.check(points.contains { $0.manualActivity?.scrollEvents == 8_000 }, "scroll-activity extreme disappeared")
            try harness.check(points.allSatisfy { ($0.manualActivityIntensity ?? 0) >= 0 && ($0.manualActivityIntensity ?? 0) <= 1 }, "manual-activity intensity left its 0...1 range")
        }

        await harness.run("process ownership follows app families without inspecting work content") {
            let applications = [
                RunningApplicationIdentity(processID: 100, name: "Conductor", bundleID: "com.conductor.app", isUserApplication: true),
                RunningApplicationIdentity(processID: 300, name: "Conductor Web Content", bundleID: "com.apple.WebKit.WebContent", isUserApplication: false),
                RunningApplicationIdentity(processID: 400, name: "Unrelated Service", bundleID: "example.service", isUserApplication: false)
            ]
            let processes = [
                ProcessLineageIdentity(processID: 100, parentProcessID: 1, processStart: 10),
                ProcessLineageIdentity(processID: 110, parentProcessID: 100, processStart: 20),
                ProcessLineageIdentity(processID: 120, parentProcessID: 110, processStart: 30),
                ProcessLineageIdentity(processID: 121, parentProcessID: 120, processStart: 40),
                ProcessLineageIdentity(processID: 130, parentProcessID: 110, processStart: 31),
                ProcessLineageIdentity(processID: 131, parentProcessID: 130, processStart: 41),
                ProcessLineageIdentity(processID: 300, parentProcessID: 1, processStart: 25),
                ProcessLineageIdentity(processID: 400, parentProcessID: 1, processStart: 25),
                ProcessLineageIdentity(processID: 500, parentProcessID: 100, processStart: 5)
            ]
            let owners = ProcessOwnershipResolver.resolve(processes: processes, applications: applications)
            try harness.check(owners[100]?.relation == .application, "application root was not identified")
            try harness.check(owners[120]?.name == "Conductor" && owners[120]?.relation == .descendant, "agent descendant was not owned by Conductor")
            try harness.check(owners[121]?.name == "Conductor", "tool descendant lost the app owner")
            try harness.check(owners[300]?.name == "Conductor" && owners[300]?.relation == .relatedHelper, "OS-named WebKit helper was not related to Conductor")
            try harness.check(owners[400] == nil, "unrelated helper was falsely attributed")
            try harness.check(owners[500] == nil, "PID reuse race was falsely attributed")

            let namedWorkers: [(String, Int32)] = [("codex", 120), ("node", 121), ("codex", 130), ("node", 131)]
            let agentCount = namedWorkers.filter { name, pid in
                AgentWorkerClassifier.isAgentRoot(name: name, relation: owners[pid]?.relation)
            }.count
            try harness.check(agentCount == 2, "two agent roots were confused with all descendant workers")
        }

        await harness.run("accessory helpers attach while standalone menu apps remain roots") {
            let applications = [
                RunningApplicationIdentity(processID: 100, name: "Conductor", bundleID: "com.conductor.app", role: .regular),
                RunningApplicationIdentity(processID: 200, name: "Browser", bundleID: "company.thebrowser.Browser", role: .regular),
                RunningApplicationIdentity(processID: 300, name: "Conductor Web Content", bundleID: "com.apple.WebKit.WebContent", role: .accessory),
                RunningApplicationIdentity(processID: 301, name: "Browser Helper", bundleID: "company.thebrowser.browser.helper", role: .accessory),
                RunningApplicationIdentity(processID: 302, name: "Conductor Graphics and Media", bundleID: "com.apple.WebKit.GPU", role: .accessory),
                RunningApplicationIdentity(processID: 303, name: "AutoFill (Conductor)", bundleID: "com.apple.SafariPlatformSupport.Helper", role: .background),
                RunningApplicationIdentity(processID: 400, name: "CleanShot X", bundleID: "pl.maketheweb.cleanshotx", role: .accessory),
                RunningApplicationIdentity(processID: 401, name: "Maccy", bundleID: "org.p0deje.Maccy", role: .accessory),
                RunningApplicationIdentity(processID: 402, name: "MY MACHINE", bundleID: "local.mymachine.app", role: .accessory)
            ]
            let processes = applications.map {
                ProcessLineageIdentity(processID: $0.processID, parentProcessID: 1, processStart: UInt64($0.processID))
            } + [ProcessLineageIdentity(processID: 410, parentProcessID: 400, processStart: 1_000)]
            let owners = ProcessOwnershipResolver.resolve(processes: processes, applications: applications)
            try harness.check(owners[300]?.name == "Conductor" && owners[300]?.relation == .relatedHelper, "accessory WebKit helper became a separate app root")
            try harness.check(owners[301]?.name == "Browser" && owners[301]?.relation == .relatedHelper, "accessory bundle helper became a separate app root")
            try harness.check(owners[302]?.name == "Conductor" && owners[302]?.relation == .relatedHelper, "accessory graphics helper became a separate app root")
            try harness.check(owners[303]?.name == "Conductor" && owners[303]?.relation == .relatedHelper, "OS host-marked background helper was not attached")
            for (pid, name) in [(400, "CleanShot X"), (401, "Maccy"), (402, "MY MACHINE")] {
                try harness.check(owners[Int32(pid)]?.name == name && owners[Int32(pid)]?.relation == .application, "standalone accessory app \(name) did not remain a root")
            }
            try harness.check(owners[410]?.name == "CleanShot X" && owners[410]?.relation == .descendant, "standalone menu app could not own a descendant")
        }

        await harness.run("background summaries separate residence, activity, and overlap") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let end = start.addingTimeInterval(60)
            let resources = [
                AppResourceSample(
                    timestamp: start.addingTimeInterval(30), duration: 30,
                    ownerName: "Conductor", ownerBundleID: "com.conductor.app", isForeground: false,
                    cpuPercent: 15, memoryBytes: 2_000_000_000,
                    diskReadBytes: 1_000_000, diskWriteBytes: 0,
                    processCount: 8, workerCount: 7, agentWorkerCount: 2,
                    workerNames: ["codex", "node"]
                ),
                AppResourceSample(
                    timestamp: end, duration: 30,
                    ownerName: "Conductor", ownerBundleID: "com.conductor.app", isForeground: false,
                    cpuPercent: 2, memoryBytes: 2_500_000_000,
                    diskReadBytes: 0, diskWriteBytes: 1_000_000,
                    processCount: 10, workerCount: 9, agentWorkerCount: 2,
                    workerNames: ["codex", "node"]
                )
            ]
            let system = [
                sample(at: start.addingTimeInterval(30), duration: 30, interval: 30, pressure: .elevated),
                sample(at: end, duration: 30, interval: 30, thermal: .serious)
            ]
            let engine = InsightEngine()
            let interval = DateInterval(start: start, end: end)
            let summaries = engine.makeBackgroundAppSummaries(samples: resources, systemSamples: system, in: interval)
            let summary = try require(summaries.first, "background family was not summarized")
            try harness.check(summary.ownerName == "Conductor", "background owner identity was lost")
            try harness.check(abs(summary.backgroundDuration - 60) < 0.001, "background residence was inaccurate")
            try harness.check(abs(summary.backgroundActivityDuration - 60) < 0.001, "measurable background activity was inaccurate")
            try harness.check(summary.maximumWorkerCount == 9 && summary.maximumAgentWorkerCount == 2, "worker and agent counts were conflated")
            try harness.check(abs(summary.elevatedMemoryOverlapDuration - 30) < 0.001, "memory-pressure overlap was inaccurate")
            try harness.check(abs(summary.seriousThermalOverlapDuration - 30) < 0.001, "thermal overlap was inaccurate")
            let points = engine.makeBackgroundActivityPoints(samples: resources, systemSamples: system, in: interval)
            try harness.check(points.count == 2 && points[0].elevatedMemoryOverlap && points[1].seriousThermalOverlap, "background swimlane points lost overlap context")
        }

        await harness.run("safe application-only categorization") {
            let categorizer = ApplicationCategorizer()
            try harness.check(categorizer.category(appName: "Safari", bundleID: "com.apple.Safari") == .research, "Safari category mismatch")
            try harness.check(categorizer.category(appName: "Terminal", bundleID: "com.apple.Terminal") == .coding, "Terminal category mismatch")
            try harness.check(categorizer.category(appName: "Unexpected App", bundleID: "example.unknown") == .other, "unknown app should remain Other")
            try harness.check(WorkCategory.research.rawValue == "Browser use", "browser identity was overclaimed as intent")
        }

        await harness.run("plain-language formatting") {
            try harness.check(TelemetrySemantics.anyInputEventTypeRawValue == UInt32.max, "idle detection is not configured for any keyboard/mouse/tablet input")
            try harness.check(TelemetrySemantics.isUnexpectedGap(elapsed: 40, expectedInterval: 15), "sampling gap beyond covered duration was not recognized")
            try harness.check(!TelemetrySemantics.isUnexpectedGap(elapsed: 60, expectedInterval: 60), "normal adaptive idle interval was treated as a gap")
            try harness.check(Formatters.duration(30) == "less than a minute", "short duration wording mismatch")
            try harness.check(Formatters.duration(5_400) == "1 hr 30 min", "hour duration wording mismatch")
            let bytes = Formatters.bytes(1_000_000_000)
            try harness.check(bytes.contains("MB") || bytes.contains("GB"), "byte units are not readable: \(bytes)")

            let legacySettings = Data("{\"baseSamplingInterval\":15,\"idleThreshold\":300,\"rawRetentionDays\":3,\"eventRetentionDays\":90,\"reportRetentionDays\":365,\"processLimit\":16,\"isPaused\":false}".utf8)
            let decoded = try JSONDecoder().decode(MonitoringSettings.self, from: legacySettings)
            try harness.check(decoded.pauseUntil == nil && decoded.launchAtLoginPreference == nil && decoded.briefingNotificationsEnabled == nil, "older settings did not migrate safely")
        }

        await harness.run("sparse reports do not invent advice") {
            let report = InsightEngine().makeReport(
                dayKey: "2026-08-23",
                timezone: TimeZone(secondsFromGMT: 0)!,
                samples: [sample()],
                processSamples: [],
                events: []
            )
            try harness.check(report.recommendations.isEmpty, "sparse data produced a recommendation")
            try harness.check((report.longestContinuousCoverage ?? 0) < CoverageEvaluator.narrativeMinimum, "sparse data passed the continuous-coverage gate")
            try harness.check(report.headline.lowercased().contains("continuous coverage"), "sparse report did not explain why conclusions were withheld")
            try harness.check(report.correlations.isEmpty && report.importantMoments.isEmpty, "sparse data produced interpreted findings")
            try harness.check(!report.overview.lowercased().contains("productivity"), "report claimed productivity")
            try harness.check(!report.overview.lowercased().contains("caused"), "report used unsupported causal language")
            try harness.check(!ReportRenderer.markdown(report).contains("CPU averaged"), "sparse export presented fragmented CPU as a daily conclusion")

            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let fragments = (0..<8).map { index in
                sample(at: start.addingTimeInterval(Double(index) * 300), duration: 15, interval: 15)
            }
            try harness.check(!CoverageEvaluator.supportsNarrative(fragments), "separate short fragments were combined into continuous coverage")
            let continuous = (0..<8).map { index in
                sample(at: start.addingTimeInterval(Double(index) * 15), duration: 15, interval: 15)
            }
            try harness.check(CoverageEvaluator.supportsNarrative(continuous), "a genuine two-minute observation did not pass the coverage gate")
        }

        await harness.run("private proactive briefing policy") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let sensitiveSamples = (0..<8).map { index in
                sample(
                    at: start.addingTimeInterval(Double(index) * 15),
                    duration: 15,
                    interval: 15,
                    app: "Secret Client Project",
                    bundle: "com.example.secret-client",
                    category: .coding,
                    cpu: 88,
                    pressure: .high,
                    thermal: .serious
                )
            }
            let report = InsightEngine().makeReport(
                dayKey: "2026-05-27",
                timezone: TimeZone(secondsFromGMT: 0)!,
                samples: sensitiveSamples,
                processSamples: [ProcessSample(timestamp: start, processID: 7, processStart: 1, name: "ConfidentialWorker", bundleID: "com.example.secret", isForeground: true, cpuPercent: 180, memoryBytes: 5_000_000_000, diskReadBytes: 1_000_000_000, diskWriteBytes: 1_000_000_000, energyNanojoules: nil)],
                events: []
            )
            let copy = try require(BriefingNotificationPolicy.privateNotificationCopy(for: report), "reliable report did not produce report-ready notification copy")
            let serialized = "\(copy.title) \(copy.body)".lowercased()
            for forbidden in ["secret", "client", "confidential", "coding", "cpu", "memory", "heat", "88", "180"] {
                try harness.check(!serialized.contains(forbidden), "notification exposed sensitive report detail: \(forbidden)")
            }
            let sparse = InsightEngine().makeReport(dayKey: "2026-05-27", timezone: TimeZone(secondsFromGMT: 0)!, samples: [sample()], processSamples: [], events: [])
            try harness.check(BriefingNotificationPolicy.privateNotificationCopy(for: sparse) == nil, "low-coverage report scheduled a notification")

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let morning = try require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 24, hour: 9, minute: 30)), "morning fixture unavailable")
            let evening = try require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 24, hour: 19, minute: 30)), "evening fixture unavailable")
            let sameDay = try require(BriefingNotificationPolicy.nextDailyDelivery(after: morning, calendar: calendar), "morning delivery date unavailable")
            let nextDay = try require(BriefingNotificationPolicy.nextDailyDelivery(after: evening, calendar: calendar), "evening delivery date unavailable")
            let sameComponents = calendar.dateComponents([.hour, .minute], from: sameDay)
            try harness.check(sameComponents.hour == 18 && sameComponents.minute == 0, "daily briefing was not scheduled for 18:00")
            try harness.check(nextDay.timeIntervalSince(sameDay) >= 23 * 3_600, "evening scheduling did not move to the next local day")
        }

        await harness.run("weighted daily interpretation and export") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            var samples: [SystemSample] = []
            for index in 0..<8 {
                let item = sample(
                    at: start.addingTimeInterval(Double(index) * 900),
                    duration: 900,
                    interval: 900,
                    app: index < 6 ? "Example IDE" : "Safari",
                    bundle: index < 6 ? "com.example.ide" : "com.apple.Safari",
                    category: index < 6 ? .coding : .research,
                    cpu: index < 6 ? 70 : 20,
                    memory: index < 6 ? 12_000_000_000 : 8_000_000_000
                )
                samples.append(item)
            }
            let report = InsightEngine().makeReport(dayKey: "2026-05-27", timezone: TimeZone(secondsFromGMT: 0)!, samples: samples, processSamples: [], events: [])
            try harness.check(abs(report.activeDuration - 7_200) < 1, "active duration was not time-weighted")
            try harness.check(report.applications.first?.name == "Example IDE", "main app summary mismatch")
            try harness.check(report.correlations.contains { $0.title.contains("processor-demanding") }, "strong workload correlation was missed")
            let markdown = ReportRenderer.markdown(report)
            try harness.check(markdown.contains("What I would change tomorrow"), "export omitted Tomorrow section")
            try harness.check(markdown.contains("No data-backed change"), "export did not explain absence of advice")
            try harness.check(markdown.contains("does not capture keystrokes"), "export omitted privacy boundary")
            try harness.check(report.totalDiskBytes == 12_000_000 && report.totalNetworkBytes == 18_000_000, "full-day I/O aggregates were not preserved")
            try harness.check(markdown.contains("disk") && markdown.contains("network"), "export omitted practical I/O context")
        }

        await harness.run("battery calculations exclude charging transitions") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let mixed = [
                sample(at: start, duration: 900, interval: 900, battery: 80, power: .battery, charging: false),
                sample(at: start.addingTimeInterval(900), duration: 900, interval: 900, battery: 78, power: .battery, charging: false),
                sample(at: start.addingTimeInterval(1_800), duration: 900, interval: 900, battery: 90, power: .adapter, charging: true),
                sample(at: start.addingTimeInterval(2_700), duration: 900, interval: 900, battery: 88, power: .battery, charging: false)
            ]
            let report = InsightEngine().makeReport(dayKey: "2026-05-27", timezone: TimeZone(secondsFromGMT: 0)!, samples: mixed, processSamples: [], events: [])
            try harness.check(report.batteryChangePercent == nil, "mixed power states produced a drain claim")
            let flat = [
                sample(at: start, duration: 900, interval: 900, battery: 80, power: .battery, charging: false),
                sample(at: start.addingTimeInterval(1_800), duration: 900, interval: 900, battery: 80, power: .battery, charging: false)
            ]
            let flatReport = InsightEngine().makeReport(dayKey: "2026-05-27", timezone: TimeZone(secondsFromGMT: 0)!, samples: flat, processSamples: [], events: [])
            try harness.check(flatReport.batteryChangePercent == nil, "unchanged battery level produced a rise/drain claim")
        }

        await harness.run("event detectors require sustained evidence") {
            var detector = EventDetector()
            let start = Date()
            var events: [ActivityEvent] = []
            for index in 0..<7 { events += detector.observe(sample(at: start.addingTimeInterval(Double(index) * 15), cpu: 80)) }
            try harness.check(!events.contains { $0.type == .sustainedCPU }, "CPU event fired too early")
            events += detector.observe(sample(at: start.addingTimeInterval(7 * 15), cpu: 80))
            try harness.check(events.filter { $0.type == .sustainedCPU }.count == 1, "CPU event did not fire at two minutes")
            events += detector.observe(sample(at: start.addingTimeInterval(8 * 15), cpu: 85))
            try harness.check(events.filter { $0.type == .sustainedCPU }.count == 1, "CPU event duplicated while open")

            detector.resetAfterGap()
            events = []
            for index in 0..<4 { events += detector.observe(sample(at: start.addingTimeInterval(Double(index) * 15), cpu: 80)) }
            events += detector.observe(sample(at: start.addingTimeInterval(60), cpu: 70))
            for index in 0..<4 { events += detector.observe(sample(at: start.addingTimeInterval(Double(index + 5) * 15), cpu: 80)) }
            try harness.check(!events.contains { $0.type == .sustainedCPU }, "separate CPU bursts were combined into a sustained event")
        }

        await harness.run("v1 stores migrate app-family ownership without losing rows") {
            let directory = temporaryDirectory(prefix: "DailyMacV1Migration")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("DailyMac.sqlite").path
            var legacy: OpaquePointer?
            guard sqlite3_open_v2(path, &legacy, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let legacy else { throw ValidationFailure.failed("could not create legacy store fixture") }
            let legacySchema = """
            CREATE TABLE process_samples(
              id TEXT PRIMARY KEY, timestamp REAL NOT NULL, pid INTEGER NOT NULL,
              process_start INTEGER NOT NULL, name TEXT NOT NULL, bundle_id TEXT,
              is_foreground INTEGER NOT NULL, cpu_percent REAL NOT NULL,
              memory_bytes INTEGER NOT NULL, disk_read INTEGER NOT NULL,
              disk_write INTEGER NOT NULL, energy_nj INTEGER
            );
            INSERT INTO process_samples VALUES('00000000-0000-0000-0000-000000000001', 1000, 7, 1, 'legacy-worker', NULL, 0, 10, 100, 0, 0, NULL);
            PRAGMA user_version=1;
            """
            let legacyResult = sqlite3_exec(legacy, legacySchema, nil, nil, nil)
            sqlite3_close(legacy)
            try harness.check(legacyResult == SQLITE_OK, "could not create legacy schema")

            let store = try SQLiteStore(directoryURL: directory)
            let legacyRows = try await store.processSamples(from: Date(timeIntervalSince1970: 999), to: Date(timeIntervalSince1970: 1_001))
            try harness.check(legacyRows.count == 1 && legacyRows[0].name == "legacy-worker", "legacy process row was lost")
            try harness.check(legacyRows[0].ownerName == nil && legacyRows[0].ownerRelation == nil, "legacy row acquired invented ownership")
            let modern = ProcessSample(timestamp: Date(timeIntervalSince1970: 1_002), processID: 8, processStart: 2, name: "codex", bundleID: nil, isForeground: false, cpuPercent: 20, memoryBytes: 200, diskReadBytes: 0, diskWriteBytes: 0, energyNanojoules: nil, parentProcessID: 7, ownerName: "Conductor", ownerBundleID: "com.conductor.app", ownerRelation: .descendant)
            try await store.save(sample: sample(at: Date(timeIntervalSince1970: 1_002)), processes: [modern])
            let modernRows = try await store.processSamples(from: Date(timeIntervalSince1970: 1_001), to: Date(timeIntervalSince1970: 1_003))
            try harness.check(modernRows.first?.ownerName == "Conductor", "migrated store could not persist modern ownership")
        }

        await harness.run("v2 stores migrate aggregate manual activity without inventing history") {
            let directory = temporaryDirectory(prefix: "DailyMacV2ActivityMigration")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("DailyMac.sqlite").path
            var legacy: OpaquePointer?
            guard sqlite3_open_v2(path, &legacy, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let legacy else { throw ValidationFailure.failed("could not create v2 system-store fixture") }
            let legacySchema = """
            CREATE TABLE system_samples(
              id TEXT PRIMARY KEY, timestamp REAL NOT NULL, duration REAL NOT NULL,
              foreground_app TEXT NOT NULL, foreground_bundle TEXT, category TEXT NOT NULL,
              is_idle INTEGER NOT NULL, cpu_percent REAL NOT NULL, load_1m REAL NOT NULL,
              load_5m REAL NOT NULL, memory_used INTEGER NOT NULL, memory_total INTEGER NOT NULL,
              memory_pressure TEXT NOT NULL, swap_used INTEGER NOT NULL, thermal TEXT NOT NULL,
              battery_percent REAL, power_source TEXT NOT NULL, is_charging INTEGER,
              disk_read INTEGER NOT NULL, disk_write INTEGER NOT NULL,
              network_received INTEGER NOT NULL, network_sent INTEGER NOT NULL,
              monitor_cpu REAL NOT NULL, monitor_memory INTEGER NOT NULL,
              monitor_disk_write INTEGER NOT NULL, sampling_interval REAL NOT NULL
            );
            INSERT INTO system_samples VALUES(
              '00000000-0000-0000-0000-000000000002', 1000, 15,
              'Legacy Editor', NULL, 'Writing', 0, 10, 1, 1,
              100, 200, 'low', 0, 'nominal', 80, 'battery', 0,
              1, 2, 3, 4, 0.1, 50, 0, 15
            );
            PRAGMA user_version=2;
            """
            let legacyResult = sqlite3_exec(legacy, legacySchema, nil, nil, nil)
            sqlite3_close(legacy)
            try harness.check(legacyResult == SQLITE_OK, "could not create v2 system schema")

            let store = try SQLiteStore(directoryURL: directory)
            let oldRows = try await store.samples(
                from: Date(timeIntervalSince1970: 999),
                to: Date(timeIntervalSince1970: 1_001)
            )
            try harness.check(oldRows.count == 1, "legacy system row was lost")
            try harness.check(oldRows[0].manualActivity == nil, "legacy history acquired invented manual activity")
            try harness.check(
                oldRows[0].performanceCorePercent == nil
                    && oldRows[0].efficiencyCorePercent == nil
                    && oldRows[0].performanceCoreContributionPercent == nil,
                "legacy history acquired an invented core split"
            )

            let activity = ManualActivityCounts(keyboardEvents: 10, pointerEvents: 100, clickEvents: 4, scrollEvents: 40)
            try await store.save(
                sample: sample(at: Date(timeIntervalSince1970: 1_002), manualActivity: activity),
                processes: []
            )
            let modernRows = try await store.samples(
                from: Date(timeIntervalSince1970: 1_001),
                to: Date(timeIntervalSince1970: 1_003)
            )
            try harness.check(modernRows.first?.manualActivity == activity, "migrated store could not persist aggregate input counts")
        }

        await harness.run("sleep and wake history carries explicit state into a monitoring window") {
            let directory = temporaryDirectory(prefix: "DailyMacSleepWakeWindow")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let olderWake = ActivityEvent(timestamp: start.addingTimeInterval(-300), type: .wake, title: "Older wake", explanation: "Explicit wake.", severity: .information)
            let leadingSleep = ActivityEvent(timestamp: start.addingTimeInterval(-60), type: .sleep, title: "Leading sleep", explanation: "Explicit sleep.", severity: .information)
            let unrelated = ActivityEvent(timestamp: start.addingTimeInterval(10), type: .note, title: "Unrelated", explanation: "Not a power-state transition.", severity: .information)
            let windowWake = ActivityEvent(timestamp: start.addingTimeInterval(30), type: .wake, title: "Window wake", explanation: "Explicit wake.", severity: .information)
            let endingSleep = ActivityEvent(timestamp: start.addingTimeInterval(120), type: .sleep, title: "Ending sleep", explanation: "Explicit sleep.", severity: .information)
            for event in [olderWake, leadingSleep, unrelated, windowWake, endingSleep] {
                try await store.save(event: event)
            }

            let interval = DateInterval(start: start, end: start.addingTimeInterval(120))
            let transitions = try await store.sleepWakeEvents(in: interval)
            try harness.check(transitions.map(\.id) == [leadingSleep.id, windowWake.id, endingSleep.id], "sleep/wake window did not preserve the leading state and exact transitions")
            try harness.check(!transitions.contains { $0.type == .note }, "sleep/wake window included an unrelated event")

            let windowOnly = try await store.sleepWakeEvents(in: interval, includingPrevious: false)
            try harness.check(windowOnly.map(\.id) == [windowWake.id, endingSleep.id], "sleep/wake window could not omit the prior state")
        }

        await harness.run("timeline pairs and clips only explicit completed sleep") {
            let start = Date(timeIntervalSince1970: 1_800_100_000)
            let interval = DateInterval(start: start, end: start.addingTimeInterval(120))
            let leadingSleep = ActivityEvent(
                timestamp: start.addingTimeInterval(-60),
                type: .sleep,
                title: "Leading sleep",
                explanation: "Explicit sleep.",
                severity: .information
            )
            let firstWake = ActivityEvent(
                timestamp: start.addingTimeInterval(30),
                type: .wake,
                title: "First wake",
                explanation: "Explicit wake.",
                severity: .information
            )
            let unrelated = ActivityEvent(
                timestamp: start.addingTimeInterval(45),
                type: .note,
                title: "Unrelated",
                explanation: "Not a power transition.",
                severity: .information
            )
            let secondSleep = ActivityEvent(
                timestamp: start.addingTimeInterval(60),
                type: .sleep,
                title: "Second sleep",
                explanation: "Explicit sleep.",
                severity: .information
            )
            let duplicateSleep = ActivityEvent(
                timestamp: start.addingTimeInterval(70),
                type: .sleep,
                title: "Duplicate sleep",
                explanation: "Repeated transition.",
                severity: .information
            )
            let secondWake = ActivityEvent(
                timestamp: start.addingTimeInterval(90),
                type: .wake,
                title: "Second wake",
                explanation: "Explicit wake.",
                severity: .information
            )
            let unpairedSleep = ActivityEvent(
                timestamp: start.addingTimeInterval(100),
                type: .sleep,
                title: "Unpaired sleep",
                explanation: "No matching wake in this query.",
                severity: .information
            )

            let spans = TimelineSemantics.sleepIntervals(
                from: [secondWake, unrelated, unpairedSleep, leadingSleep, duplicateSleep, firstWake, secondSleep],
                within: interval
            )
            try harness.check(
                spans == [
                    DateInterval(start: start, end: start.addingTimeInterval(30)),
                    DateInterval(start: start.addingTimeInterval(60), end: start.addingTimeInterval(90))
                ],
                "timeline did not clip completed sleep pairs or extended an unpaired sleep by default"
            )
        }

        await harness.run("timeline selection distinguishes sleep, observations, and gaps") {
            let start = Date(timeIntervalSince1970: 1_800_200_000)
            let interval = DateInterval(start: start, end: start.addingTimeInterval(360))
            let first = sample(
                at: start.addingTimeInterval(60),
                duration: 60,
                interval: 60,
                idle: true
            )
            let overlapsSleep = sample(
                at: start.addingTimeInterval(165),
                duration: 60,
                interval: 60
            )
            let second = sample(
                at: start.addingTimeInterval(300),
                duration: 60,
                interval: 60
            )
            let staleDuration = sample(
                at: start.addingTimeInterval(340),
                duration: 300,
                interval: 15
            )
            let sleep = DateInterval(
                start: start.addingTimeInterval(120),
                end: start.addingTimeInterval(180)
            )
            let samples = [staleDuration, second, first, overlapsSleep]

            switch TimelineSemantics.selection(
                at: start.addingTimeInterval(30),
                samples: samples,
                sleepIntervals: [sleep],
                within: interval
            ) {
            case .observed(let selected):
                try harness.check(selected.id == first.id, "timeline selected the wrong measured interval")
            default:
                throw ValidationFailure.failed("an idle but measured interval was not treated as observed")
            }

            try harness.check(
                TimelineSemantics.selection(
                    at: start.addingTimeInterval(90),
                    samples: samples,
                    sleepIntervals: [sleep],
                    within: interval
                ) == .unrecorded,
                "timeline snapped an unrecorded gap to a nearby sample"
            )

            switch TimelineSemantics.selection(
                at: start.addingTimeInterval(150),
                samples: samples,
                sleepIntervals: [sleep],
                within: interval
            ) {
            case .sleep(let selected):
                try harness.check(selected == sleep, "timeline returned the wrong explicit sleep interval")
            default:
                throw ValidationFailure.failed("an overlapping sample took priority over explicit sleep")
            }

            try harness.check(
                TimelineSemantics.selection(
                    at: sleep.end,
                    samples: samples,
                    sleepIntervals: [sleep],
                    within: interval
                ) == .unrecorded,
                "the exact wake boundary remained labelled as sleep"
            )
            try harness.check(
                TimelineSemantics.selection(
                    at: start.addingTimeInterval(305),
                    samples: samples,
                    sleepIntervals: [sleep],
                    within: interval
                ) == .unrecorded,
                "a stale raw duration bridged an unobserved interval instead of being bounded"
            )
        }

        await harness.run("battery timeline never bridges power changes, gaps, or sleep") {
            let start = Date(timeIntervalSince1970: 1_800_300_000)
            let interval = DateInterval(start: start, end: start.addingTimeInterval(400))
            let samples = [
                sample(at: start.addingTimeInterval(15), battery: 100, power: .battery),
                sample(at: start.addingTimeInterval(30), battery: 99, power: .battery),
                sample(at: start.addingTimeInterval(45), battery: 99, power: .adapter, charging: true),
                sample(at: start.addingTimeInterval(60), battery: 98, power: .battery),
                sample(at: start.addingTimeInterval(75), battery: 97, power: .battery),
                sample(at: start.addingTimeInterval(90), battery: 96, power: .battery),
                sample(at: start.addingTimeInterval(300), battery: 95, power: .battery),
                sample(at: start.addingTimeInterval(315), battery: nil, power: .unknown, charging: nil),
                sample(at: start.addingTimeInterval(330), battery: 94, power: .battery),
                sample(at: start.addingTimeInterval(345), battery: 94, power: .battery, charging: true),
                sample(at: start.addingTimeInterval(360), battery: 93, power: .battery)
            ]
            let sleep = DateInterval(
                start: start.addingTimeInterval(78),
                end: start.addingTimeInterval(82)
            )

            let runs = TimelineSemantics.batteryRuns(
                from: Array(samples.reversed()),
                within: interval,
                sleepIntervals: [sleep]
            )
            try harness.check(
                runs.map { $0.readings.count } == [2, 2, 1, 1, 1, 1],
                "battery runs bridged an adapter, explicit sleep, recording gap, unknown source, or charging interval"
            )
            try harness.check(
                runs.compactMap { $0.readings.first?.timestamp } == [15, 60, 90, 300, 330, 360].map(start.addingTimeInterval),
                "battery runs did not preserve chronological starts after invalid transitions"
            )
        }

        await harness.run("one battery reading remains visible without inventing change") {
            let start = Date(timeIntervalSince1970: 1_800_400_000)
            let interval = DateInterval(start: start, end: start.addingTimeInterval(60))
            let runs = TimelineSemantics.batteryRuns(
                from: [sample(at: start.addingTimeInterval(15), battery: 73, power: .battery)],
                within: interval,
                sleepIntervals: []
            )
            try harness.check(
                runs.count == 1 && runs[0].readings.count == 1,
                "a single relevant battery reading disappeared from the timeline"
            )
            try harness.check(runs[0].change == nil, "one battery reading invented a trend")

            let adapterOnly = TimelineSemantics.batteryRuns(
                from: [sample(at: start.addingTimeInterval(15), battery: 100, power: .adapter, charging: true)],
                within: interval,
                sleepIntervals: []
            )
            try harness.check(adapterOnly.isEmpty, "a plugged-in-only window created a battery graph")
        }

        await harness.run("battery ten-point timing distinguishes observed pace from estimates") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            func reading(_ minutes: Double, _ percent: Double) -> BatteryTimelineReading {
                BatteryTimelineReading(
                    id: UUID(),
                    timestamp: start.addingTimeInterval(minutes * 60),
                    percent: percent
                )
            }

            let observed = BatteryTimelineRun(readings: [
                reading(0, 80), reading(5, 75), reading(10, 70), reading(15, 65)
            ])
            guard case .observed(let observedDuration) = TimelineSemantics.batteryTenPointTiming(for: observed) else {
                throw ValidationFailure.failed("an actual ten-point discharge was not recognized")
            }
            try harness.check(abs(observedDuration - 600) < 0.001, "actual ten-point timing was inaccurate")

            let equivalent = BatteryTimelineRun(readings: [
                reading(0, 80), reading(10, 79), reading(20, 77)
            ])
            guard case .equivalent(let equivalentDuration) = TimelineSemantics.batteryTenPointTiming(for: equivalent) else {
                throw ValidationFailure.failed("a sufficiently long partial discharge did not produce a labeled equivalent pace")
            }
            try harness.check(abs(equivalentDuration - 4_000) < 0.001, "ten-point equivalent pace was inaccurate")

            let rebound = BatteryTimelineRun(readings: [
                reading(0, 80), reading(7, 77), reading(14, 79), reading(21, 76)
            ])
            try harness.check(
                TimelineSemantics.batteryTenPointTiming(for: rebound) == .collecting,
                "battery recalibration or rebound produced a confident discharge pace"
            )
        }

        await harness.run("SQLite round-trip, retention, and secure erase") {
            let directory = temporaryDirectory(prefix: "DailyMacStore")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            let now = Date()
            let old = sample(at: now.addingTimeInterval(-10 * 86_400))
            let activity = ManualActivityCounts(keyboardEvents: 24, pointerEvents: 320, clickEvents: 7, scrollEvents: 90)
            let current = sample(
                at: now,
                gpu: 32,
                performanceCore: 64,
                efficiencyCore: 28,
                performanceContribution: 18,
                manualActivity: activity
            )
            let process = ProcessSample(timestamp: now, processID: 42, processStart: 123, name: "Worker 'quoted' **text**", bundleID: nil, isForeground: false, cpuPercent: 60, memoryBytes: 900_000_000, diskReadBytes: 10_000, diskWriteBytes: 20_000, energyNanojoules: nil, parentProcessID: 7, ownerName: "Conductor", ownerBundleID: "com.conductor.app", ownerRelation: .descendant)
            let resource = AppResourceSample(timestamp: now, duration: 30, ownerName: "Conductor", ownerBundleID: "com.conductor.app", isForeground: false, cpuPercent: 75, memoryBytes: 2_000_000_000, diskReadBytes: 1_000_000, diskWriteBytes: 2_000_000, processCount: 8, workerCount: 7, agentWorkerCount: 2, workerNames: ["codex", "node"])
            let event = ActivityEvent(timestamp: now, type: .note, title: "Test event", explanation: "A local test event.", severity: .information)
            let oldAppEvent = ActivityEvent(timestamp: old.timestamp, type: .appLaunched, title: "App opened: Example", explanation: "Old exact app event.", severity: .information)
            let oldNotableEvent = ActivityEvent(timestamp: old.timestamp, type: .sustainedCPU, title: "Old performance event", explanation: "A retained aggregate finding.", severity: .notable)
            try await store.save(sample: old, processes: [])
            try await store.save(event: oldAppEvent)
            try await store.save(event: oldNotableEvent)
            try await store.save(sample: current, processes: [process], appResources: [resource], events: [event])
            let storedSamples = try await store.samples(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
            let storedProcesses = try await store.processSamples(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
            let storedResources = try await store.appResourceSamples(in: DateInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60)))
            let storedSample = try require(storedSamples.first, "system sample round-trip returned no row")
            let storedProcess = try require(storedProcesses.first, "process sample round-trip returned no row")
            try harness.check(storedSamples.count == 1 && storedSample.id == current.id, "system sample identity round-trip failed")
            try harness.check(abs(storedSample.timestamp.timeIntervalSince(current.timestamp)) < 0.000_001, "system sample timestamp lost meaningful precision")
            try harness.check(storedSample.foregroundApp == current.foregroundApp && storedSample.cpuPercent == current.cpuPercent && storedSample.memoryUsedBytes == current.memoryUsedBytes, "system sample values round-trip failed")
            try harness.check(storedSample.gpuPercent == 32, "optional graphics activity did not round-trip")
            try harness.check(
                storedSample.performanceCorePercent == 64
                    && storedSample.efficiencyCorePercent == 28
                    && storedSample.performanceCoreContributionPercent == 18,
                "optional core-cluster telemetry did not round-trip"
            )
            try harness.check(storedSample.manualActivity == activity, "aggregate manual activity did not round-trip")
            try harness.check(storedProcesses.count == 1 && storedProcess.id == process.id, "process sample identity round-trip failed")
            try harness.check(abs(storedProcess.timestamp.timeIntervalSince(process.timestamp)) < 0.000_001 && storedProcess.name == process.name, "process sample values round-trip failed")
            try harness.check(storedProcess.parentProcessID == 7 && storedProcess.ownerName == "Conductor" && storedProcess.ownerRelation == .descendant, "process ownership round-trip failed")
            try harness.check(storedResources.count == 1 && storedResources[0].id == resource.id, "app-family resource identity round-trip failed")
            try harness.check(storedResources[0].agentWorkerCount == 2 && storedResources[0].workerNames == ["codex", "node"], "app-family worker metadata round-trip failed")
            let latestImpacts = try await store.latestProcessImpacts()
            try harness.check(latestImpacts.count == 1 && abs(latestImpacts[0].timestamp.timeIntervalSince(now)) < 0.000_001, "process impact lost the timestamp needed to label stale data")
            try harness.check(latestImpacts[0].ownerName == "Conductor" && latestImpacts[0].ownerRelation == .descendant, "latest process impact lost app-family ownership")
            var settings = MonitoringSettings.default
            settings.rawRetentionDays = 3
            try await store.performRetention(settings: settings, now: now)
            let retainedSamples = try await store.samples(from: .distantPast, to: .distantFuture)
            try harness.check(retainedSamples.count == 1 && retainedSamples.first?.id == current.id, "retention removed the wrong sample")
            let retainedResources = try await store.appResourceSamples(in: DateInterval(start: .distantPast, end: .distantFuture))
            try harness.check(retainedResources.count == 1 && retainedResources.first?.id == resource.id, "retention removed the current app-family resource sample")
            let retainedEvents = try await store.events(from: .distantPast, to: .distantFuture)
            try harness.check(!retainedEvents.contains { $0.id == oldAppEvent.id }, "exact app event outlived raw retention")
            try harness.check(retainedEvents.contains { $0.id == oldNotableEvent.id }, "notable performance event was deleted too early")
            try await store.eraseAllData()
            let erasedSamples = try await store.samples(from: .distantPast, to: .distantFuture)
            let erasedEvents = try await store.events(from: .distantPast, to: .distantFuture)
            let erasedResources = try await store.appResourceSamples(in: DateInterval(start: .distantPast, end: .distantFuture))
            try harness.check(erasedSamples.isEmpty, "erase left system samples")
            try harness.check(erasedEvents.isEmpty, "erase left events")
            try harness.check(erasedResources.isEmpty, "erase left app-family resource samples")
        }

        await harness.run("owner-only files and privacy-minimal schema") {
            let directory = temporaryDirectory(prefix: "DailyMacPrivacy")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            _ = await store.databaseSizeBytes()
            let directoryPermissions = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
            let databasePermissions = (try FileManager.default.attributesOfItem(atPath: store.databaseURL.path)[.posixPermissions] as? NSNumber)?.intValue
            try harness.check(directoryPermissions == 0o700, "data directory is not owner-only")
            try harness.check(databasePermissions == 0o600, "database is not owner-only")
            for suffix in ["-wal", "-shm"] {
                let path = store.databaseURL.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    let permissions = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
                    try harness.check(permissions == 0o600, "SQLite sidecar \(suffix) is not owner-only")
                }
            }

            var db: OpaquePointer?
            guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw ValidationFailure.failed("could not inspect schema") }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT group_concat(sql, ' ') FROM sqlite_master WHERE sql IS NOT NULL;", -1, &statement, nil) == SQLITE_OK else { throw ValidationFailure.failed("could not prepare schema query") }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw ValidationFailure.failed("schema query returned no row") }
            let schema = String(cString: raw).lowercased()
            for prohibited in ["keystroke", "key_code", "key_text", "pointer_x", "pointer_y", "event_payload", "event_target", "clipboard", "window_title", "document_content", "command_line", "environment_variable", "network_destination", "screenshot"] {
                try harness.check(!schema.contains(prohibited), "schema contains prohibited field: \(prohibited)")
            }
        }

        await harness.run("corrupt database is preserved and recovered") {
            let directory = temporaryDirectory(prefix: "DailyMacRecovery")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = directory.appendingPathComponent("DailyMac.sqlite")
            try Data("this is deliberately not a database".utf8).write(to: database)
            let store = try SQLiteStore(directoryURL: directory)
            try await store.save(sample: sample(), processes: [])
            let recovery = try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("Recovery-") }
            try harness.check(recovery != nil, "corrupt database was not preserved")
            let recoveredSamples = try await store.samples(from: .distantPast, to: .distantFuture)
            try harness.check(recoveredSamples.count == 1, "fresh store was not usable after recovery")
        }

        await harness.run("busy database is never mistaken for corruption") {
            let directory = temporaryDirectory(prefix: "DailyMacBusy")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let initial = try SQLiteStore(directoryURL: directory)
                try await initial.save(sample: sample(), processes: [])
            }
            var lock: OpaquePointer?
            let path = directory.appendingPathComponent("DailyMac.sqlite").path
            guard sqlite3_open_v2(path, &lock, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let lock else {
                throw ValidationFailure.failed("could not open lock fixture")
            }
            defer { sqlite3_close(lock) }
            guard sqlite3_exec(lock, "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK else {
                throw ValidationFailure.failed("could not lock valid database")
            }
            do {
                _ = try SQLiteStore(directoryURL: directory)
                throw ValidationFailure.failed("second store unexpectedly opened through exclusive lock")
            } catch is ValidationFailure {
                throw ValidationFailure.failed("second store unexpectedly opened through exclusive lock")
            } catch {
                // A temporary unavailable error is the safe outcome.
            }
            let directoryContents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            try harness.check(!directoryContents.contains { $0.hasPrefix("Recovery-") }, "valid locked database was moved into Recovery")
            _ = sqlite3_exec(lock, "ROLLBACK;", nil, nil, nil)
        }

        await harness.run("failed report save blocks raw-data retention") {
            let directory = temporaryDirectory(prefix: "DailyMacRetentionGate")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            let now = Date()
            let old = sample(at: now.addingTimeInterval(-10 * 86_400))
            try await store.save(sample: old, processes: [])

            var db: OpaquePointer?
            guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
                throw ValidationFailure.failed("could not open report-failure fixture")
            }
            let triggerResult = sqlite3_exec(db, "CREATE TRIGGER reject_reports BEFORE INSERT ON daily_reports BEGIN SELECT RAISE(FAIL, 'fault injection'); END;", nil, nil, nil)
            sqlite3_close(db)
            try harness.check(triggerResult == SQLITE_OK, "could not install report-failure trigger")

            let report = InsightEngine().makeReport(dayKey: DayBoundaries.key(for: old.timestamp), timezone: .autoupdatingCurrent, samples: [old], processSamples: [], events: [])
            var failedAsExpected = false
            do {
                var settings = MonitoringSettings.default
                settings.rawRetentionDays = 3
                try await RetentionCoordinator.finalizeThenRetain(store: store, settings: settings) {
                    try await store.save(report: report)
                }
            } catch {
                failedAsExpected = true
            }
            try harness.check(failedAsExpected, "fault-injected report save unexpectedly succeeded")
            let remaining = try await store.samples(from: .distantPast, to: .distantFuture)
            try harness.check(remaining.count == 1 && remaining.first?.id == old.id, "raw sample was deleted after report finalization failed")
        }

        await harness.run("idle cadence and retained day discovery stay accurate") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let idle = (0..<60).map { index in
                sample(at: start.addingTimeInterval(Double(index) * 60), duration: 60, interval: 60, idle: true)
            }
            let report = InsightEngine().makeReport(dayKey: "2026-05-27", timezone: TimeZone(secondsFromGMT: 0)!, samples: idle, processSamples: [], events: [])
            try harness.check(abs(report.idleDuration - 3_600) < 1, "one hour at adaptive idle cadence was undercounted")

            let directory = temporaryDirectory(prefix: "DailyMacDays")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(directoryURL: directory)
            try await store.save(sample: sample(at: start), processes: [])
            try await store.save(sample: sample(at: start.addingTimeInterval(2 * 86_400)), processes: [])
            let timestamps = try await store.sampleTimestamps(before: start.addingTimeInterval(3 * 86_400))
            try harness.check(Set(timestamps.map { DayBoundaries.key(for: $0, timezone: TimeZone(secondsFromGMT: 0)!) }).count == 2, "multiple retained activity days were not discoverable for finalization")
        }

        await harness.run("24-hour report fixture remains fast and bounded") {
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            var samples: [SystemSample] = []
            samples.reserveCapacity(5_760)
            for index in 0..<5_760 {
                let isCoding = index % 3 == 0
                let item = sample(
                    at: start.addingTimeInterval(Double(index) * 15),
                    app: isCoding ? "Example IDE" : "Safari",
                    bundle: isCoding ? "com.example.ide" : "com.apple.Safari",
                    category: isCoding ? .coding : .research,
                    cpu: Double(15 + index % 70)
                )
                samples.append(item)
            }
            let began = Date()
            let report = InsightEngine().makeReport(dayKey: "2026-05-27", timezone: TimeZone(secondsFromGMT: 0)!, samples: samples, processSamples: [], events: [])
            let elapsed = Date().timeIntervalSince(began)
            try harness.check(report.sampleCount == 5_760, "synthetic day lost samples")
            try harness.check(elapsed < 3, "daily report took \(elapsed)s")

            let rollingBegan = Date()
            let rangeEnd = start.addingTimeInterval(86_400)
            let snapshot = InsightEngine().makeMonitoringSnapshot(range: .twentyFourHours, endingAt: rangeEnd, samples: samples)
            let chart = InsightEngine().makeMonitoringChartPoints(samples: samples, in: .init(start: start, end: rangeEnd), limit: 720)
            let rollingElapsed = Date().timeIntervalSince(rollingBegan)
            try harness.check(snapshot.sampleCount == 5_759, "rolling snapshot did not honor the open start boundary")
            try harness.check(chart.count <= 720, "24-hour rolling chart exceeded its point budget")
            try harness.check(rollingElapsed < 1, "rolling snapshot and chart took \(rollingElapsed)s")
        }

        await harness.run("live permission-free telemetry invariants") {
            let sampler = TelemetrySampler()
            let start = Date()
            let began = Date()
            print("INFO  taking first live sample")
            let first = await sampler.sample(settings: .default, now: start)
            print("INFO  first live sample complete")
            var accumulator = 0
            for value in 0..<100_000 { accumulator &+= value }
            let second = await sampler.sample(settings: .default, now: start.addingTimeInterval(31))
            print("INFO  second live sample complete")
            let elapsed = Date().timeIntervalSince(began)
            try harness.check(accumulator > 0, "CPU fixture did not run")
            try harness.check(first.system.memoryTotalBytes > 0, "memory total unavailable")
            try harness.check(first.system.memoryUsedBytes > 0 && first.system.memoryUsedBytes <= first.system.memoryTotalBytes, "memory reading implausible")
            try harness.check((0...100).contains(second.system.cpuPercent), "CPU reading out of bounds")
            try harness.check(!second.system.foregroundApp.isEmpty, "foreground app unavailable")
            let anyInput = CGEventType(rawValue: TelemetrySemantics.anyInputEventTypeRawValue)!
            let liveIdleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            try harness.check(second.system.isIdle == (liveIdleSeconds >= MonitoringSettings.default.idleThreshold), "idle classification did not follow any keyboard/mouse/tablet input")
            try harness.check(second.attemptedProcessCount > 0 && second.observedProcessCount > 0, "process extension observed nothing")
            try harness.check(second.observedProcessCount <= second.attemptedProcessCount, "process coverage exceeds attempted count")
            try harness.check(elapsed < 5, "two live samples took \(elapsed)s")
            print("INFO  live process coverage: \(second.observedProcessCount)/\(second.attemptedProcessCount); idle input age: \(Int(liveIdleSeconds))s; two-sample wall time: \(String(format: "%.3f", elapsed))s")
        }

        print("\nValidation summary: \(harness.passed) passed, \(harness.failed) failed")
        if harness.failed > 0 { exit(1) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ValidationFailure.failed(message) }
        return value
    }

    private static func temporaryDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func sample(
        at date: Date = Date(), duration: TimeInterval = 15, interval: TimeInterval = 15,
        app: String = "Example Editor", bundle: String? = "com.example.editor",
        category: WorkCategory = .writing, idle: Bool = false, cpu: Double = 25,
        gpu: Double? = nil,
        performanceCore: Double? = nil, efficiencyCore: Double? = nil,
        performanceContribution: Double? = nil,
        memory: UInt64 = 8_000_000_000, totalMemory: UInt64 = 16_000_000_000,
        pressure: MemoryPressureLevel = .low, swap: UInt64 = 0,
        thermal: ThermalLevel = .nominal, battery: Double? = 75,
        power: PowerSource = .battery, charging: Bool? = false,
        diskRead: UInt64 = 1_000_000, diskWrite: UInt64 = 500_000,
        networkReceived: UInt64 = 2_000_000, networkSent: UInt64 = 250_000,
        manualActivity: ManualActivityCounts? = nil
    ) -> SystemSample {
        SystemSample(
            timestamp: date, duration: duration, foregroundApp: app, foregroundBundleID: bundle,
            category: category, isIdle: idle, cpuPercent: cpu,
            performanceCorePercent: performanceCore,
            efficiencyCorePercent: efficiencyCore,
            performanceCoreContributionPercent: performanceContribution,
            gpuPercent: gpu,
            loadAverage1m: 2, loadAverage5m: 1.5,
            memoryUsedBytes: memory, memoryTotalBytes: totalMemory, memoryPressure: pressure,
            swapUsedBytes: swap, thermalLevel: thermal, batteryPercent: battery, powerSource: power,
            isCharging: charging, diskReadBytes: diskRead, diskWriteBytes: diskWrite,
            networkReceivedBytes: networkReceived, networkSentBytes: networkSent, monitorCPUPercent: 0.2,
            monitorMemoryBytes: 60_000_000, monitorDiskWriteBytes: 20_000, samplingInterval: interval,
            manualActivity: manualActivity
        )
    }

    private static func sysctlInteger(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
