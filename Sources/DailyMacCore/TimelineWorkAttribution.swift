import Foundation

/// A named app family's recorded contribution across the same observed window
/// as the overall attribution. 100% uses one logical core; UI/helpers are part
/// of the measured family. Missing app rows are not inferred as additional work.
public struct TimelineAppCPUContributor: Equatable, Sendable, Identifiable {
    public var id: String { "\(bundleIdentifier ?? "unbundled")|\(name)" }
    public let name: String
    public let bundleIdentifier: String?
    public let averageCPUPercent: Double
}

/// Resource attribution within the application families the collector can see.
/// These shares are not percentages of whole-machine CPU, GPU activity, human
/// effort, or productivity. Foreground describes a window's ownership, not who
/// caused its work. An agent-app family includes its UI and ordinary helpers.
public struct TimelineWorkAttribution: Equatable, Sendable {
    public let latestTimestamp: Date
    public let observedDuration: TimeInterval
    public let collectionCount: Int
    public let totalObservedAppCPUCoreSeconds: Double
    public let foregroundCPUSharePercent: Double
    public let backgroundCPUSharePercent: Double
    public let agentAppCPUSharePercent: Double?
    /// The measured CPU of all recognized agent roots, only when every root
    /// counted in each family is also present in the retained process evidence.
    /// Missing roots produce nil, never a count-derived estimate or zero.
    public let agentWorkerCPUSharePercent: Double?
    public let latestAgentWorkerCount: Int
    public let topAppContributors: [TimelineAppCPUContributor]

    /// CPU in the operating system's per-process convention: 100% is one busy
    /// logical core. It can exceed 100 and must not be compared directly with
    /// the core graph's normalized whole-machine percentage.
    public var averageObservedAppCPUPercent: Double {
        totalObservedAppCPUCoreSeconds / observedDuration * 100
    }

    public var averageForegroundCPUPercent: Double {
        averageObservedAppCPUPercent * foregroundCPUSharePercent / 100
    }

    public var averageBackgroundCPUPercent: Double {
        averageObservedAppCPUPercent * backgroundCPUSharePercent / 100
    }

    public var averageAgentAppCPUPercent: Double? {
        agentAppCPUSharePercent.map { averageObservedAppCPUPercent * $0 / 100 }
    }

    /// A live/selected-window explanation with measured, time-weighted shares.
    /// App-family totals are complete for the retained observation set, while
    /// raw process records may be only the highest-ranked subset of that set.
    public static func summarize(
        appSamples: [AppResourceSample],
        processSamples: [ProcessSample] = [],
        within window: DateInterval
    ) -> TimelineWorkAttribution? {
        guard window.duration.isFinite, window.duration > 0 else { return nil }

        struct Owner: Hashable {
            let name: String
            let bundle: String?
        }
        struct Collection {
            let timestamp: Date
            let interval: DateInterval
            let apps: [AppResourceSample]
        }
        // Earlier collectors interpreted Mach CPU ticks as nanoseconds. Never
        // mix those uncalibrated records with corrected per-core percentages,
        // including partially versioned frames that would distort the shares.
        let uncalibratedTimes = Set(appSamples.filter { $0.cpuMeasurementVersion != 1 }.map(\.timestamp))
        let usable = appSamples.filter {
            $0.timestamp.timeIntervalSinceReferenceDate.isFinite
                && $0.cpuMeasurementVersion == 1 && !uncalibratedTimes.contains($0.timestamp)
                && $0.duration.isFinite && $0.duration > 0
                && $0.cpuPercent.isFinite && $0.cpuPercent >= 0
                && $0.agentWorkerCount >= 0
                && !$0.ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.timestamp > window.start
                && $0.timestamp.addingTimeInterval(-$0.duration) < window.end
        }
        let rawByTime = Dictionary(grouping: processSamples, by: \.timestamp)
        let frames = Dictionary(grouping: usable, by: \.timestamp).compactMap { timestamp, values -> Collection? in
            // Deduplicate app-family rows from repeated delivery of one frame.
            // Disagreeing duplicates are not dependable attribution evidence.
            let owners = Dictionary(grouping: values) { Owner(name: $0.ownerName, bundle: $0.ownerBundleID) }
            var unique: [AppResourceSample] = []
            for records in owners.values {
                guard let first = records.first,
                      records.allSatisfy({
                          $0.duration == first.duration && $0.cpuPercent == first.cpuPercent
                              && $0.isForeground == first.isForeground
                              && $0.agentWorkerCount == first.agentWorkerCount
                      }) else { return nil }
                unique.append(first)
            }
            guard let commonStart = unique.map({ $0.timestamp.addingTimeInterval(-$0.duration) }).max() else {
                return nil
            }
            let start = max(window.start, commonStart)
            let end = min(window.end, timestamp)
            guard end > start else { return nil }
            return Collection(timestamp: timestamp, interval: DateInterval(start: start, end: end), apps: unique)
        }.sorted { $0.timestamp < $1.timestamp }
        guard frames.count >= 2, let latest = frames.last,
              window.end.timeIntervalSince(latest.timestamp) <= max(120, latest.interval.duration * 2.2) else {
            return nil
        }

        var observedDuration = 0.0
        var total = 0.0
        var foreground = 0.0
        var agentFamilies = 0.0
        var agentRoots = 0.0
        var completeAgentEvidence = true
        var hadAgents = false
        var previousEnd: Date?
        var cpuByOwner: [Owner: Double] = [:]
        for frame in frames {
            let start = max(frame.interval.start, previousEnd ?? frame.interval.start)
            let duration = frame.interval.end.timeIntervalSince(start)
            guard duration > 0 else { continue }
            observedDuration += duration
            previousEnd = frame.interval.end
            let raw = rawByTime[frame.timestamp] ?? []
            for app in frame.apps {
                let coreSeconds = app.cpuPercent / 100 * duration
                total += coreSeconds
                cpuByOwner[Owner(name: app.ownerName, bundle: app.ownerBundleID), default: 0] += coreSeconds
                if app.isForeground { foreground += coreSeconds }
                if app.agentWorkerCount > 0 {
                    hadAgents = true
                    agentFamilies += coreSeconds
                }

                let recognizedRoots = raw.filter {
                    $0.ownerName == app.ownerName && $0.ownerBundleID == app.ownerBundleID
                        && AgentWorkerClassifier.isAgentRoot(name: $0.name, relation: $0.ownerRelation)
                }
                struct ProcessIdentity: Hashable {
                    let pid: Int32
                    let start: UInt64
                }
                let rootsByID = Dictionary(grouping: recognizedRoots) {
                    ProcessIdentity(pid: $0.processID, start: $0.processStart)
                }
                let roots = rootsByID.values.compactMap { records -> ProcessSample? in
                    guard let first = records.first,
                          records.allSatisfy({ $0.cpuMeasurementVersion == 1 && $0.cpuPercent == first.cpuPercent }) else { return nil }
                    return first
                }
                let rootCPU = roots.reduce(0) { $0 + $1.cpuPercent }
                guard roots.count == app.agentWorkerCount,
                      roots.allSatisfy({ $0.cpuPercent.isFinite && $0.cpuPercent >= 0 }),
                      rootCPU <= app.cpuPercent + 0.000_001 else {
                    completeAgentEvidence = false
                    continue
                }
                agentRoots += rootCPU / 100 * duration
            }
        }
        guard observedDuration >= 30, total.isFinite, total >= 1 else { return nil }
        func share(_ value: Double) -> Double { min(100, max(0, value / total * 100)) }
        let foregroundShare = share(foreground)
        let topContributors = cpuByOwner.compactMap { owner, coreSeconds -> TimelineAppCPUContributor? in
            guard coreSeconds > 0 else { return nil }
            return TimelineAppCPUContributor(
                name: owner.name,
                bundleIdentifier: owner.bundle,
                averageCPUPercent: coreSeconds / observedDuration * 100
            )
        }.sorted { lhs, rhs in
            if lhs.averageCPUPercent != rhs.averageCPUPercent {
                return lhs.averageCPUPercent > rhs.averageCPUPercent
            }
            if lhs.name.lowercased() != rhs.name.lowercased() {
                return lhs.name.lowercased() < rhs.name.lowercased()
            }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return (lhs.bundleIdentifier ?? "") < (rhs.bundleIdentifier ?? "")
        }
        return TimelineWorkAttribution(
            latestTimestamp: latest.timestamp,
            observedDuration: observedDuration,
            collectionCount: frames.count,
            totalObservedAppCPUCoreSeconds: total,
            foregroundCPUSharePercent: foregroundShare,
            backgroundCPUSharePercent: 100 - foregroundShare,
            agentAppCPUSharePercent: hadAgents ? share(agentFamilies) : nil,
            agentWorkerCPUSharePercent: hadAgents && completeAgentEvidence ? share(agentRoots) : nil,
            latestAgentWorkerCount: latest.apps.reduce(0) { $0 + $1.agentWorkerCount },
            topAppContributors: Array(topContributors.prefix(3))
        )
    }
}
