import DailyMacCore
import Foundation

enum WorkAttributionValidation {
    static func run(harness: ValidationHarness) async {
        let start = Date(timeIntervalSince1970: 1_800_800_000)
        let window = DateInterval(start: start, duration: 60)
        let appSamples = [30.0, 60.0].flatMap { offset in
            [
                app(at: start.addingTimeInterval(offset), name: "Editor", cpu: 100, foreground: true),
                app(at: start.addingTimeInterval(offset), name: "Agent host", cpu: 300, agents: 2)
            ]
        }
        let processes = [30.0, 60.0].flatMap { offset in
            [
                process(at: start.addingTimeInterval(offset), pid: 1, cpu: 50),
                process(at: start.addingTimeInterval(offset), pid: 2, cpu: 100)
            ]
        }

        await harness.run("work attribution distinguishes app-family CPU from agent-root CPU") {
            guard let value = TimelineWorkAttribution.summarize(
                appSamples: appSamples, processSamples: processes, within: window
            ) else { throw ValidationFailure.failed("complete attribution evidence was withheld") }
            try harness.check(abs(value.observedDuration - 60) < 0.001, "app rows counted elapsed time more than once")
            try harness.check(abs(value.totalObservedAppCPUCoreSeconds - 240) < 0.001, "observed CPU was not measured in core-seconds")
            try harness.check(value.foregroundCPUSharePercent == 25 && value.backgroundCPUSharePercent == 75, "foreground/background CPU shares were inaccurate")
            try harness.check(value.agentAppCPUSharePercent == 75, "family CPU was inferred from process counts")
            try harness.check(value.agentWorkerCPUSharePercent == 37.5, "measured agent CPU was confused with the whole hosting app")
            try harness.check(value.latestAgentWorkerCount == 2, "observed canonical agent count was inaccurate")
            try harness.check(value.averageObservedAppCPUPercent == 400 && value.averageBackgroundCPUPercent == 300 && value.averageAgentAppCPUPercent == 300, "per-core CPU units were implicitly normalized to whole-machine units")
            try harness.check(value.topAppContributors.map(\.name) == ["Agent host", "Editor"], "top apps did not preserve exact observed metadata in CPU order")
            try harness.check(value.topAppContributors.map(\.bundleIdentifier) == ["example.Agent host", "example.Editor"], "top app identity was inferred instead of copied from observed metadata")
            try harness.check(value.topAppContributors.map(\.averageCPUPercent) == [300, 100], "top apps used a different CPU unit or attribution denominator")
        }

        await harness.run("incomplete agent evidence never turns worker counts into CPU estimates") {
            let partial = TimelineWorkAttribution.summarize(
                appSamples: appSamples, processSamples: Array(processes.dropLast()), within: window
            )
            try harness.check(partial?.agentWorkerCPUSharePercent == nil, "a missing raw agent root produced a confident CPU estimate")
            try harness.check(partial?.agentAppCPUSharePercent == 75, "missing raw processes removed measured app-family attribution")
            let noRaw = TimelineWorkAttribution.summarize(appSamples: appSamples, within: window)
            try harness.check(noRaw?.agentWorkerCPUSharePercent == nil, "agent process counts were converted into invented CPU")
            let idleRoots = processes.map { source in
                process(at: source.timestamp, pid: source.processID, cpu: 0)
            }
            let idle = TimelineWorkAttribution.summarize(
                appSamples: appSamples, processSamples: idleRoots, within: window
            )
            try harness.check(idle?.agentWorkerCPUSharePercent == 0, "measured idle agent roots were mistaken for unavailable CPU")
            try harness.check(idle?.agentAppCPUSharePercent == 75, "idle agent roots incorrectly erased work elsewhere in the app family")
        }

        await harness.run("work attribution withholds legacy uncalibrated process CPU") {
            for version in [nil, 0] as [Int?] {
                let legacyApps = [30.0, 60.0].flatMap { offset in
                    [
                        app(at: start.addingTimeInterval(offset), name: "Editor", cpu: 100, foreground: true, version: version),
                        app(at: start.addingTimeInterval(offset), name: "Agent host", cpu: 300, agents: 2, version: version)
                    ]
                }
                try harness.check(TimelineWorkAttribution.summarize(appSamples: legacyApps, within: window) == nil, "legacy app CPU was treated as calibrated capacity")
                try harness.check(TimelineWorkAttribution.summarize(appSamples: appSamples + legacyApps, within: window) == nil, "mixed measurement versions were accepted within a collection")
                let legacyRoots = processes.map {
                    process(at: $0.timestamp, pid: $0.processID, cpu: $0.cpuPercent, version: version)
                }
                let value = TimelineWorkAttribution.summarize(appSamples: appSamples, processSamples: legacyRoots, within: window)
                try harness.check(value?.agentWorkerCPUSharePercent == nil, "uncalibrated raw process CPU produced an agent-root estimate")
                try harness.check(value?.agentAppCPUSharePercent == 75, "legacy raw roots erased independently calibrated app CPU")
            }
        }

        await harness.run("work attribution clips intervals and deduplicates delivery") {
            let inputs = [
                app(at: start.addingTimeInterval(30), name: "Editor", cpu: 100, foreground: true),
                app(at: start.addingTimeInterval(30), name: "Agent host", cpu: 100, agents: 2),
                app(at: start.addingTimeInterval(60), name: "Editor", cpu: 100, foreground: true),
                app(at: start.addingTimeInterval(60), name: "Agent host", cpu: 300, agents: 2)
            ]
            let clipped = DateInterval(start: start.addingTimeInterval(15), end: window.end)
            guard let value = TimelineWorkAttribution.summarize(
                appSamples: inputs + inputs, within: clipped
            ) else { throw ValidationFailure.failed("clipped attribution evidence was withheld") }
            try harness.check(value.collectionCount == 2 && value.observedDuration == 45, "repeated delivery inflated observation duration")
            try harness.check(abs(value.foregroundCPUSharePercent - 30) < 0.001, "attribution did not weight partially visible samples")
            try harness.check(abs((value.agentAppCPUSharePercent ?? 0) - 70) < 0.001, "agent-family boundary weighting was inaccurate")
            try harness.check(abs(value.totalObservedAppCPUCoreSeconds - 150) < 0.001, "duplicate app-family delivery inflated measured CPU")
            try harness.check(value.topAppContributors.map(\.name) == ["Agent host", "Editor"], "clipped app contributions lost their ordering")
            try harness.check(abs(value.topAppContributors[0].averageCPUPercent - 700.0 / 3.0) < 0.001, "top app contribution ignored clipping or counted duplicate delivery")
            try harness.check(value.topAppContributors[1].averageCPUPercent == 100, "top app contribution did not reuse observed duration")
        }

        await harness.run("top app contributors remain bounded deterministic and evidence-based") {
            let inputs = [30.0, 60.0].flatMap { offset in
                [
                    app(at: start.addingTimeInterval(offset), name: "Zulu", cpu: 80),
                    app(at: start.addingTimeInterval(offset), name: "Beta", cpu: 100),
                    app(at: start.addingTimeInterval(offset), name: "Alpha", cpu: 100),
                    app(at: start.addingTimeInterval(offset), name: "Small", cpu: 10),
                    app(at: start.addingTimeInterval(offset), name: "Quiet", cpu: 0)
                ]
            }
            guard let original = TimelineWorkAttribution.summarize(appSamples: inputs, within: window),
                  let reversed = TimelineWorkAttribution.summarize(appSamples: inputs.reversed(), within: window) else {
                throw ValidationFailure.failed("top app fixtures did not produce attribution")
            }
            try harness.check(original.topAppContributors.count == 3, "the small top-app result expanded beyond three contributors")
            try harness.check(original.topAppContributors.map(\.name) == ["Alpha", "Beta", "Zulu"], "equal CPU contributions had nondeterministic ordering")
            try harness.check(original.topAppContributors == reversed.topAppContributors, "input delivery order changed top app results")
            try harness.check(original.topAppContributors.reduce(0) { $0 + $1.averageCPUPercent } <= original.averageObservedAppCPUPercent, "top app contributions exceeded the total observed CPU")

            let intermittent = [
                app(at: start.addingTimeInterval(30), name: "Always", cpu: 100),
                app(at: start.addingTimeInterval(30), name: "Once", cpu: 200),
                app(at: start.addingTimeInterval(60), name: "Always", cpu: 100)
            ]
            let value = TimelineWorkAttribution.summarize(appSamples: intermittent, within: window)
            try harness.check(value?.topAppContributors.first(where: { $0.name == "Once" })?.averageCPUPercent == 100, "an intermittently observed app was extrapolated across missing app rows")
        }

        await harness.run("work attribution withholds stale sparse and inconsistent claims") {
            try harness.check(TimelineWorkAttribution.summarize(appSamples: Array(appSamples.prefix(2)), within: window) == nil, "one process collection produced a confident explanation")
            try harness.check(TimelineWorkAttribution.summarize(
                appSamples: appSamples, within: DateInterval(start: start, duration: 600)
            ) == nil, "stale work attribution was presented as current")
            let contradictory = app(at: start.addingTimeInterval(60), name: "Editor", cpu: 999, foreground: true)
            try harness.check(TimelineWorkAttribution.summarize(appSamples: appSamples + [contradictory], within: window) == nil, "conflicting duplicate families produced an arbitrary share")
            let inflatedRoots = processes.map { process(at: $0.timestamp, pid: $0.processID, cpu: 500) }
            try harness.check(TimelineWorkAttribution.summarize(
                appSamples: appSamples, processSamples: inflatedRoots, within: window
            )?.agentWorkerCPUSharePercent == nil, "root CPU exceeding the measured family was accepted")
            let zero = [30.0, 60.0].map { app(at: start.addingTimeInterval($0), name: "Quiet", cpu: 0) }
            try harness.check(TimelineWorkAttribution.summarize(appSamples: zero, within: window) == nil, "zero activity invented a 100-percent CPU contributor")
        }
    }

    private static func app(
        at timestamp: Date, name: String, cpu: Double,
        foreground: Bool = false, agents: Int = 0, version: Int? = 1
    ) -> AppResourceSample {
        AppResourceSample(
            timestamp: timestamp, duration: 30,
            ownerName: name, ownerBundleID: "example.\(name)", isForeground: foreground,
            cpuPercent: cpu, memoryBytes: 0, diskReadBytes: 0, diskWriteBytes: 0,
            processCount: 10, workerCount: 9, agentWorkerCount: agents,
            workerNames: agents > 0 ? ["codex"] : [], cpuMeasurementVersion: version
        )
    }

    private static func process(at timestamp: Date, pid: Int32, cpu: Double, version: Int? = 1) -> ProcessSample {
        ProcessSample(
            timestamp: timestamp, processID: pid, processStart: UInt64(pid),
            name: "codex", bundleID: nil, isForeground: false, cpuPercent: cpu,
            memoryBytes: 0, diskReadBytes: 0, diskWriteBytes: 0, energyNanojoules: nil,
            parentProcessID: 999, ownerName: "Agent host", ownerBundleID: "example.Agent host",
            ownerRelation: .descendant, cpuMeasurementVersion: version
        )
    }
}
