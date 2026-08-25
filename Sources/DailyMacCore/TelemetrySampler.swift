import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.ps

public enum TelemetrySemantics {
    /// CoreGraphics defines kCGAnyInputEventType as the all-bits-set event value.
    public static let anyInputEventTypeRawValue = UInt32.max

    public static func isUnexpectedGap(elapsed: TimeInterval, expectedInterval: TimeInterval) -> Bool {
        elapsed > max(2, expectedInterval * 2.2)
    }

    /// Quartz event counters are unsigned 32-bit totals since WindowServer started.
    /// Accept a rollover only when both values are close enough to the boundary for
    /// it to have happened during one sampling interval; a larger backwards jump is
    /// treated as a WindowServer counter reset and withheld.
    public static func eventCounterDelta(current: UInt32, previous: UInt32) -> UInt64? {
        if current >= previous { return UInt64(current - previous) }
        let plausibleRolloverWindow: UInt32 = 1_000_000
        guard previous >= UInt32.max - plausibleRolloverWindow,
              current <= plausibleRolloverWindow else { return nil }
        return UInt64(UInt32.max - previous) + UInt64(current) + 1
    }
}

public struct TelemetryResult: Sendable {
    public let system: SystemSample
    public let processes: [ProcessSample]
    public let appResources: [AppResourceSample]
    public let observedProcessCount: Int
    public let attemptedProcessCount: Int
    public let nextInterval: TimeInterval
    public let baselineResetAfterGap: Bool
}

/// The small, content-free part of a process record used to connect workers to apps.
/// No command line, working directory, environment, window title, or document name is read.
public struct ProcessLineageIdentity: Equatable, Sendable {
    public let processID: Int32
    public let parentProcessID: Int32?
    public let processStart: UInt64

    public init(processID: Int32, parentProcessID: Int32?, processStart: UInt64) {
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.processStart = processStart
    }
}

public enum RunningApplicationRole: Equatable, Sendable {
    case regular
    case accessory
    case background
}

public struct RunningApplicationIdentity: Equatable, Sendable {
    public let processID: Int32
    public let name: String
    public let bundleID: String?
    public let role: RunningApplicationRole

    public var isUserApplication: Bool { role != .background }

    public init(processID: Int32, name: String, bundleID: String?, role: RunningApplicationRole) {
        self.processID = processID
        self.name = name
        self.bundleID = bundleID
        self.role = role
    }

    /// Backward-compatible convenience for fixtures and callers that do not distinguish
    /// regular windows from standalone menu-bar applications.
    public init(processID: Int32, name: String, bundleID: String?, isUserApplication: Bool) {
        self.init(
            processID: processID,
            name: name,
            bundleID: bundleID,
            role: isUserApplication ? .regular : .background
        )
    }
}

public struct ResolvedProcessOwner: Equatable, Sendable {
    public let processID: Int32
    public let name: String
    public let bundleID: String?
    public let relation: ProcessOwnerRelation

    public init(processID: Int32, name: String, bundleID: String?, relation: ProcessOwnerRelation) {
        self.processID = processID
        self.name = name
        self.bundleID = bundleID
        self.relation = relation
    }
}

/// Resolves ownership only when macOS exposes a concrete relationship: the app process
/// itself, a current parent chain, or a running helper whose OS-provided identity clearly
/// matches a current user application. Unknown workers stay unknown.
public enum ProcessOwnershipResolver {
    public static func resolve(
        processes: [ProcessLineageIdentity],
        applications: [RunningApplicationIdentity]
    ) -> [Int32: ResolvedProcessOwner] {
        let processByID = Dictionary(uniqueKeysWithValues: processes.map { ($0.processID, $0) })
        let regularRoots = applications.filter { $0.role == .regular }
        var roots = regularRoots
        var resolved: [Int32: ResolvedProcessOwner] = [:]

        for root in regularRoots {
            resolved[root.processID] = ResolvedProcessOwner(
                processID: root.processID,
                name: root.name,
                bundleID: root.bundleID,
                relation: .application
            )
        }

        // Accessory processes can be either helpers or genuine standalone menu-bar apps.
        // Clear bundle/name evidence against a regular app wins; otherwise the accessory
        // remains an independent application root.
        for accessory in applications where accessory.role == .accessory {
            if let root = relatedRoot(for: accessory, roots: regularRoots) {
                resolved[accessory.processID] = ResolvedProcessOwner(
                    processID: root.processID,
                    name: root.name,
                    bundleID: root.bundleID,
                    relation: .relatedHelper
                )
            } else {
                roots.append(accessory)
                resolved[accessory.processID] = ResolvedProcessOwner(
                    processID: accessory.processID,
                    name: accessory.name,
                    bundleID: accessory.bundleID,
                    relation: .application
                )
            }
        }

        for helper in applications where helper.role == .background {
            guard let root = relatedRoot(for: helper, roots: roots) else { continue }
            resolved[helper.processID] = ResolvedProcessOwner(
                processID: root.processID,
                name: root.name,
                bundleID: root.bundleID,
                relation: .relatedHelper
            )
        }

        for process in processes where resolved[process.processID] == nil {
            var cursor = process
            var visited = Set<Int32>([process.processID])
            for _ in 0..<64 {
                guard let parentID = cursor.parentProcessID,
                      parentID > 1,
                      !visited.contains(parentID),
                      let parent = processByID[parentID] else { break }
                visited.insert(parentID)
                // A parent that started after its alleged child indicates PID reuse or a
                // racing snapshot, so it is safer to leave the worker unattributed.
                if cursor.processStart > 0, parent.processStart > cursor.processStart { break }
                if let owner = resolved[parentID] {
                    resolved[process.processID] = ResolvedProcessOwner(
                        processID: owner.processID,
                        name: owner.name,
                        bundleID: owner.bundleID,
                        relation: .descendant
                    )
                    break
                }
                cursor = parent
            }
        }
        return resolved
    }

    private static func relatedRoot(
        for helper: RunningApplicationIdentity,
        roots: [RunningApplicationIdentity]
    ) -> RunningApplicationIdentity? {
        if let helperBundle = helper.bundleID?.lowercased() {
            let bundleMatches = roots.filter { root in
                guard let rootBundle = root.bundleID?.lowercased(), !rootBundle.isEmpty else { return false }
                return helperBundle == rootBundle || helperBundle.hasPrefix(rootBundle + ".")
            }
            if let match = bundleMatches.max(by: { ($0.bundleID?.count ?? 0) < ($1.bundleID?.count ?? 0) }) {
                return match
            }
        }

        let helperName = helper.name.lowercased()
        let nameMatches = roots.filter { root in
            let rootName = root.name.lowercased()
            guard !rootName.isEmpty else { return false }
            if helperName.hasSuffix(" (\(rootName))") { return true }
            guard helperName.hasPrefix(rootName + " ") else { return false }
            let suffix = helperName.dropFirst(rootName.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let knownHelperTerms = ["helper", "web content", "networking", "graphics and media", "gpu", "renderer", "service", "computer use"]
            return knownHelperTerms.contains { term in
                suffix == term || suffix.hasPrefix(term + " ") || suffix.hasPrefix(term + " (")
            }
        }
        return nameMatches.max(by: { $0.name.count < $1.name.count })
    }
}

public enum AgentWorkerClassifier {
    /// Counts only a canonical agent executable, not renderers, helpers, shells, or its
    /// descendant tools. This keeps "agent workers" narrower than total worker processes.
    public static func isAgentRoot(name: String, relation: ProcessOwnerRelation?) -> Bool {
        relation == .descendant && name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex"
    }
}

private struct CPUCounter {
    let user: UInt64
    let system: UInt64
    let nice: UInt64
    let idle: UInt64

    var total: UInt64 { user &+ system &+ nice &+ idle }
    var busy: UInt64 { user &+ system &+ nice }
}

private enum CPUCoreKind {
    case performance
    case efficiency
}

/// A validated map from Mach's processor-array order to the hardware cluster.
/// Apple Silicon exposes the slot and cluster labels without a permission prompt.
/// Unsupported or incomplete topologies deliberately remain aggregate-only.
private struct CPUCoreTopology {
    let kindsByProcessorIndex: [CPUCoreKind]

    static func read() -> CPUCoreTopology? {
        guard let slots = processorSlots(), !slots.isEmpty,
              let kindsBySlot = deviceTreeKinds(), kindsBySlot.count == slots.count else {
            return nil
        }
        let kinds = slots.compactMap { kindsBySlot[$0] }
        guard kinds.count == slots.count,
              kinds.contains(.performance), kinds.contains(.efficiency) else { return nil }
        return CPUCoreTopology(kindsByProcessorIndex: kinds)
    }

    private static func processorSlots() -> [Int]? {
        var processorCount: natural_t = 0
        var rawInfo: processor_info_array_t?
        var rawInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_BASIC_INFO,
            &processorCount,
            &rawInfo,
            &rawInfoCount
        )
        guard result == KERN_SUCCESS, let rawInfo, processorCount > 0 else { return nil }
        defer { deallocate(rawInfo, count: rawInfoCount) }
        let count = Int(processorCount)
        let valuesPerProcessor = MemoryLayout<processor_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        guard Int(rawInfoCount) >= count * valuesPerProcessor else { return nil }
        return rawInfo.withMemoryRebound(to: processor_basic_info_data_t.self, capacity: count) { info in
            (0..<count).map { Int(info[$0].slot_num) }
        }
    }

    private static func deviceTreeKinds() -> [Int: CPUCoreKind]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var result: [Int: CPUCoreKind] = [:]
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }
            guard let slot = integerProperty("logical-cpu-id", entry: child),
                  let cluster = stringProperty("cluster-type", entry: child) else { continue }
            switch cluster.uppercased() {
            case "P": result[slot] = .performance
            case "E": result[slot] = .efficiency
            default: continue
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func integerProperty(_ key: String, entry: io_registry_entry_t) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        guard let data = value as? Data, data.count >= MemoryLayout<UInt32>.size else { return nil }
        return data.withUnsafeBytes { raw in
            Int(UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self)))
        }
    }

    private static func stringProperty(_ key: String, entry: io_registry_entry_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }
        if let string = value as? String { return string }
        guard let data = value as? Data else { return nil }
        let bytes = data.prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func deallocate(_ info: processor_info_array_t, count: mach_msg_type_number_t) {
        _ = vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: info)),
            vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)
        )
    }
}

private struct CPUClusterReading {
    let performancePercent: Double
    let efficiencyPercent: Double
    let performanceContributionPercent: Double
}

private struct NetworkCounter {
    let received: UInt64
    let sent: UInt64
}

private struct DiskCounter {
    let read: UInt64
    let written: UInt64
}

private struct BatteryReading {
    let percent: Double?
    let source: PowerSource
    let charging: Bool?
}

/// Cumulative, content-free counters exposed by Quartz. Only deltas are retained.
private struct ManualActivityCounterSnapshot {
    let keyDown: UInt32
    let flagsChanged: UInt32
    let mouseMoved: UInt32
    let leftDragged: UInt32
    let rightDragged: UInt32
    let otherDragged: UInt32
    let leftMouseDown: UInt32
    let rightMouseDown: UInt32
    let otherMouseDown: UInt32
    let scrollWheel: UInt32
}

private struct RawProcessCounter {
    let processID: Int32
    let parentProcessID: Int32?
    let start: UInt64
    let name: String
    let bundleID: String?
    let userNanos: UInt64
    let systemNanos: UInt64
    let memory: UInt64
    let diskRead: UInt64
    let diskWrite: UInt64
}

private struct ProcessKey: Hashable {
    let pid: Int32
    let start: UInt64
}

private struct ProcessCollection {
    let retained: [ProcessSample]
    let allDeltas: [ProcessSample]
    let appResources: [AppResourceSample]
    let observedCount: Int
    let attemptedCount: Int
}

public actor TelemetrySampler {
    private var previousCPU: CPUCounter?
    private var previousCoreCPU: [CPUCounter]?
    private var previousNetwork: NetworkCounter?
    private var previousDisk: DiskCounter?
    private var previousProcesses: [ProcessKey: RawProcessCounter] = [:]
    private let monotonicClock = ContinuousClock()
    private var previousInstant: ContinuousClock.Instant?
    private var previousExpectedInterval: TimeInterval?
    private var previousSwap: UInt64?
    private var previousManualActivity: ManualActivityCounterSnapshot?
    private var latestProcessCollection: ProcessCollection?
    private var lastProcessCollectionInstant: ContinuousClock.Instant?
    private let categorizer = ApplicationCategorizer()
    private let coreTopology = CPUCoreTopology.read()

    public init() {}

    public func resetDeltas() {
        previousCPU = nil
        previousCoreCPU = nil
        previousNetwork = nil
        previousDisk = nil
        previousProcesses = [:]
        previousInstant = nil
        previousExpectedInterval = nil
        previousSwap = nil
        previousManualActivity = nil
        latestProcessCollection = nil
        lastProcessCollectionInstant = nil
    }

    public func sample(settings: MonitoringSettings, now: Date = Date()) async -> TelemetryResult {
        let currentInstant = monotonicClock.now
        let context = await MainActor.run { () -> (String, String?, Int32, [RunningApplicationIdentity]) in
            let foreground = NSWorkspace.shared.frontmostApplication
            let running = NSWorkspace.shared.runningApplications
            let applications = running.map { app in
                let role: RunningApplicationRole
                switch app.activationPolicy {
                case .regular: role = .regular
                case .accessory: role = .accessory
                case .prohibited: role = .background
                @unknown default: role = .background
                }
                return RunningApplicationIdentity(
                    processID: app.processIdentifier,
                    name: Self.sanitize(app.localizedName ?? "Application"),
                    bundleID: app.bundleIdentifier,
                    role: role
                )
            }
            return (
                Self.sanitize(foreground?.localizedName ?? "No foreground app"),
                foreground?.bundleIdentifier,
                foreground?.processIdentifier ?? 0,
                applications
            )
        }

        let elapsed = previousInstant.map { max(0.2, seconds(from: $0, to: currentInstant)) } ?? settings.baseSamplingInterval
        let observedInterval = previousExpectedInterval ?? settings.baseSamplingInterval
        let unexpectedGap = previousInstant != nil && TelemetrySemantics.isUnexpectedGap(elapsed: elapsed, expectedInterval: observedInterval)
        if unexpectedGap { resetDeltas() }
        let observedDuration = previousInstant == nil ? 0 : min(elapsed, max(2, observedInterval * 2.2))
        let anyInputEvent = CGEventType(rawValue: TelemetrySemantics.anyInputEventTypeRawValue)!
        let idleSeconds = max(0, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent))
        let isIdle = idleSeconds >= settings.idleThreshold
        let currentManualActivity = readManualActivityCounters()
        let manualActivity = manualActivityCounts(
            previous: previousManualActivity,
            current: currentManualActivity
        )
        previousManualActivity = currentManualActivity
        let currentCPU = readCPUCounter()
        let cpu = cpuPercent(previous: previousCPU, current: currentCPU)
        previousCPU = currentCPU
        let currentCoreCPU = readCoreCPUCounters()
        let coreReading = coreTopology.flatMap { topology in
            cpuClusterReading(
                previous: previousCoreCPU,
                current: currentCoreCPU,
                topology: topology,
                aggregateCPUPercent: cpu
            )
        }
        previousCoreCPU = currentCoreCPU
        let gpu = readGPUPercent()
        let load = readLoadAverage()
        let memory = readMemory()
        let swap = readSwap()
        let swapGrowth = positiveDelta(swap.used, previousSwap)
        previousSwap = swap.used
        let pressure = pressureLevel(memory: memory, swapUsed: swap.used, swapGrowth: swapGrowth)
        let thermal = readThermal()
        let battery = readBattery()
        let network = readNetwork()
        let networkReceived = network.map { positiveDelta($0.received, previousNetwork?.received) } ?? 0
        let networkSent = network.map { positiveDelta($0.sent, previousNetwork?.sent) } ?? 0
        if let network { previousNetwork = network }
        let disk = readDisk()
        let diskRead = disk.map { positiveDelta($0.read, previousDisk?.read) } ?? 0
        let diskWrite = disk.map { positiveDelta($0.written, previousDisk?.written) } ?? 0
        if let disk { previousDisk = disk }

        let processElapsed = lastProcessCollectionInstant.map { seconds(from: $0, to: currentInstant) } ?? elapsed
        let shouldCollectProcesses = lastProcessCollectionInstant == nil || processElapsed >= max(30, settings.baseSamplingInterval)
        let collection: ProcessCollection
        if shouldCollectProcesses {
            collection = collectProcesses(now: now, elapsed: max(0.2, processElapsed), foregroundPID: context.2, runningApps: context.3, limit: settings.processLimit)
            latestProcessCollection = collection
            lastProcessCollectionInstant = currentInstant
        } else {
            collection = ProcessCollection(retained: [], allDeltas: [], appResources: [], observedCount: latestProcessCollection?.observedCount ?? 0, attemptedCount: latestProcessCollection?.attemptedCount ?? 0)
        }

        let own = collection.allDeltas.first { $0.processID == getpid() }
        let ownCPU = own?.cpuPercent ?? 0
        let ownMemory = own?.memoryBytes ?? currentProcessMemoryFallback()
        let ownDiskWrite = own?.diskWriteBytes ?? 0
        let nextInterval = adaptiveInterval(base: settings.baseSamplingInterval, isIdle: isIdle, battery: battery, monitorCPU: ownCPU)
        let category: WorkCategory = isIdle ? .idle : categorizer.category(appName: context.0, bundleID: context.1)

        let sample = SystemSample(
            timestamp: now,
            duration: observedDuration,
            foregroundApp: context.0,
            foregroundBundleID: context.1,
            category: category,
            isIdle: isIdle,
            cpuPercent: cpu,
            performanceCorePercent: coreReading?.performancePercent,
            efficiencyCorePercent: coreReading?.efficiencyPercent,
            performanceCoreContributionPercent: coreReading?.performanceContributionPercent,
            gpuPercent: gpu,
            loadAverage1m: load.0,
            loadAverage5m: load.1,
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            memoryPressure: pressure,
            swapUsedBytes: swap.used,
            thermalLevel: thermal,
            batteryPercent: battery.percent,
            powerSource: battery.source,
            isCharging: battery.charging,
            diskReadBytes: diskRead,
            diskWriteBytes: diskWrite,
            networkReceivedBytes: networkReceived,
            networkSentBytes: networkSent,
            monitorCPUPercent: ownCPU,
            monitorMemoryBytes: ownMemory,
            monitorDiskWriteBytes: ownDiskWrite,
            samplingInterval: observedInterval,
            manualActivity: manualActivity
        )
        previousInstant = currentInstant
        previousExpectedInterval = nextInterval
        return TelemetryResult(system: sample, processes: collection.retained, appResources: collection.appResources, observedProcessCount: collection.observedCount, attemptedProcessCount: collection.attemptedCount, nextInterval: nextInterval, baselineResetAfterGap: unexpectedGap)
    }

    private func collectProcesses(now: Date, elapsed: TimeInterval, foregroundPID: Int32, runningApps: [RunningApplicationIdentity], limit: Int) -> ProcessCollection {
        let estimated = max(1024, Int(proc_listallpids(nil, 0)))
        var pids = [pid_t](repeating: 0, count: estimated + 512)
        let count = pids.withUnsafeMutableBytes { bytes in
            proc_listallpids(bytes.baseAddress, Int32(bytes.count))
        }
        guard count > 0 else { return ProcessCollection(retained: [], allDeltas: [], appResources: [], observedCount: 0, attemptedCount: 0) }

        let runningByPID = Dictionary(uniqueKeysWithValues: runningApps.map { ($0.processID, ($0.name, $0.bundleID)) })
        var current: [ProcessKey: RawProcessCounter] = [:]
        var rawProcesses: [RawProcessCounter] = []
        var observed = 0
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let raw = readProcess(pid: pid, app: runningByPID[pid]) else { continue }
            observed += 1
            let key = ProcessKey(pid: raw.processID, start: raw.start)
            current[key] = raw
            rawProcesses.append(raw)
        }

        let ownership = ProcessOwnershipResolver.resolve(
            processes: rawProcesses.map {
                ProcessLineageIdentity(processID: $0.processID, parentProcessID: $0.parentProcessID, processStart: $0.start)
            },
            applications: runningApps
        )
        var deltas: [ProcessSample] = []
        for raw in rawProcesses {
            let key = ProcessKey(pid: raw.processID, start: raw.start)
            guard let previous = previousProcesses[key] else { continue }
            let cpuNanos = positiveDelta(raw.userNanos, previous.userNanos) &+ positiveDelta(raw.systemNanos, previous.systemNanos)
            let cpuPercent = min(10_000, Double(cpuNanos) / max(elapsed * 1_000_000_000, 1) * 100)
            let read = positiveDelta(raw.diskRead, previous.diskRead)
            let write = positiveDelta(raw.diskWrite, previous.diskWrite)
            let owner = ownership[raw.processID]
            deltas.append(ProcessSample(
                timestamp: now,
                processID: raw.processID,
                processStart: raw.start,
                name: raw.name,
                bundleID: raw.bundleID,
                isForeground: raw.processID == foregroundPID,
                cpuPercent: cpuPercent,
                memoryBytes: raw.memory,
                diskReadBytes: read,
                diskWriteBytes: write,
                energyNanojoules: nil,
                parentProcessID: raw.parentProcessID,
                ownerName: owner?.name,
                ownerBundleID: owner?.bundleID,
                ownerRelation: owner?.relation
            ))
        }
        previousProcesses = current
        let appResources = makeAppResourceSamples(
            from: deltas,
            now: now,
            duration: elapsed,
            limit: max(8, limit)
        )

        var selected: [String: ProcessSample] = [:]
        func include(_ samples: some Sequence<ProcessSample>) {
            for sample in samples {
                let key = "\(sample.processID)-\(sample.processStart)"
                selected[key] = sample
            }
        }
        include(deltas.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(max(6, limit / 2)))
        include(deltas.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(4))
        include(deltas.sorted { ($0.diskReadBytes &+ $0.diskWriteBytes) > ($1.diskReadBytes &+ $1.diskWriteBytes) }.prefix(4))
        include(deltas.filter { $0.isForeground || $0.processID == getpid() })
        let retained = selected.values.sorted { lhs, rhs in
            let lhsScore = lhs.cpuPercent + Double(lhs.memoryBytes) / 500_000_000 + Double(lhs.diskReadBytes &+ lhs.diskWriteBytes) / 250_000_000
            let rhsScore = rhs.cpuPercent + Double(rhs.memoryBytes) / 500_000_000 + Double(rhs.diskReadBytes &+ rhs.diskWriteBytes) / 250_000_000
            return lhsScore > rhsScore
        }.prefix(max(8, limit))
        return ProcessCollection(retained: Array(retained), allDeltas: deltas, appResources: appResources, observedCount: observed, attemptedCount: Int(count))
    }

    private struct AppOwnerKey: Hashable {
        let name: String
        let bundleID: String?
    }

    private func makeAppResourceSamples(
        from processes: [ProcessSample],
        now: Date,
        duration: TimeInterval,
        limit: Int
    ) -> [AppResourceSample] {
        let owned = processes.filter { $0.ownerName != nil }
        let groups = Dictionary(grouping: owned) {
            AppOwnerKey(name: $0.ownerName ?? $0.name, bundleID: $0.ownerBundleID)
        }
        let samples = groups.map { key, values -> AppResourceSample in
            let cpu = values.reduce(0) { $0 + $1.cpuPercent }
            let memory = values.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }
            let diskRead = values.reduce(UInt64(0)) { $0 &+ $1.diskReadBytes }
            let diskWrite = values.reduce(UInt64(0)) { $0 &+ $1.diskWriteBytes }
            let workers = values.filter { $0.ownerRelation != .application }
            let agentWorkers = values.filter {
                AgentWorkerClassifier.isAgentRoot(name: $0.name, relation: $0.ownerRelation)
            }
            let workerNames = workers
                .sorted { processScore($0) > processScore($1) }
                .reduce(into: [String]()) { names, process in
                    guard !names.contains(process.name), names.count < 4 else { return }
                    names.append(process.name)
                }
            return AppResourceSample(
                timestamp: now,
                duration: duration,
                ownerName: key.name,
                ownerBundleID: key.bundleID,
                isForeground: values.contains(where: \.isForeground),
                cpuPercent: cpu,
                memoryBytes: memory,
                diskReadBytes: diskRead,
                diskWriteBytes: diskWrite,
                processCount: values.count,
                workerCount: workers.count,
                agentWorkerCount: agentWorkers.count,
                workerNames: workerNames
            )
        }
        return Array(samples.sorted { appResourceScore($0) > appResourceScore($1) }.prefix(limit))
    }

    private func processScore(_ process: ProcessSample) -> Double {
        process.cpuPercent
            + Double(process.memoryBytes) / 500_000_000
            + Double(process.diskReadBytes &+ process.diskWriteBytes) / 250_000_000
    }

    private func appResourceScore(_ sample: AppResourceSample) -> Double {
        sample.cpuPercent
            + Double(sample.memoryBytes) / 500_000_000
            + Double(sample.diskReadBytes &+ sample.diskWriteBytes) / 250_000_000
    }

    private func readProcess(pid: pid_t, app: (String, String?)?) -> RawProcessCounter? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            let buffer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(pid, RUSAGE_INFO_V6, buffer)
        }
        let counters: (start: UInt64, user: UInt64, system: UInt64, memory: UInt64, read: UInt64, write: UInt64)
        if result == 0 {
            counters = (usage.ri_proc_start_abstime, usage.ri_user_time, usage.ri_system_time, usage.ri_phys_footprint, usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten)
        } else if errno == EINVAL {
            var fallback = rusage_info_v4()
            let fallbackResult = withUnsafeMutablePointer(to: &fallback) { pointer -> Int32 in
                let buffer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
                return proc_pid_rusage(pid, RUSAGE_INFO_V4, buffer)
            }
            guard fallbackResult == 0 else { return nil }
            counters = (fallback.ri_proc_start_abstime, fallback.ri_user_time, fallback.ri_system_time, fallback.ri_phys_footprint, fallback.ri_diskio_bytesread, fallback.ri_diskio_byteswritten)
        } else {
            return nil
        }

        var bsd = proc_bsdinfo()
        let bsdSize = MemoryLayout<proc_bsdinfo>.stride
        let bsdRead = withUnsafeMutablePointer(to: &bsd) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(bsdSize))
        }
        let parentProcessID: Int32? = bsdRead == bsdSize ? Int32(bitPattern: bsd.pbi_ppid) : nil

        let processName: String
        if let app {
            processName = app.0
        } else {
            var buffer = [CChar](repeating: 0, count: 256)
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            processName = Self.sanitize(String(cString: buffer))
        }
        return RawProcessCounter(
            processID: pid,
            parentProcessID: parentProcessID,
            start: counters.start,
            name: processName,
            bundleID: app?.1,
            userNanos: counters.user,
            systemNanos: counters.system,
            memory: counters.memory,
            diskRead: counters.read,
            diskWrite: counters.write
        )
    }

    private func readCPUCounter() -> CPUCounter {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return CPUCounter(user: 0, system: 0, nice: 0, idle: 0) }
        return CPUCounter(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3),
            idle: UInt64(info.cpu_ticks.2)
        )
    }

    private func readCoreCPUCounters() -> [CPUCounter]? {
        var processorCount: natural_t = 0
        var rawInfo: processor_info_array_t?
        var rawInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &rawInfo,
            &rawInfoCount
        )
        guard result == KERN_SUCCESS, let rawInfo, processorCount > 0 else { return nil }
        defer {
            _ = vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: rawInfo)),
                vm_size_t(rawInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }
        let count = Int(processorCount)
        let valuesPerProcessor = MemoryLayout<processor_cpu_load_info_data_t>.size / MemoryLayout<natural_t>.size
        guard Int(rawInfoCount) >= count * valuesPerProcessor else { return nil }
        return rawInfo.withMemoryRebound(to: processor_cpu_load_info_data_t.self, capacity: count) { info in
            (0..<count).map { index in
                let ticks = info[index].cpu_ticks
                return CPUCounter(
                    user: UInt64(ticks.0),
                    system: UInt64(ticks.1),
                    nice: UInt64(ticks.3),
                    idle: UInt64(ticks.2)
                )
            }
        }
    }

    /// Some Apple graphics drivers expose a permission-free whole-device
    /// utilization snapshot. It is optional by design: an absent, stale, or
    /// malformed driver value is withheld rather than estimated.
    private func readGPUPercent() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var readings: [Double] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let value = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue(),
            let statistics = value as? [String: Any],
            let number = statistics["Device Utilization %"] as? NSNumber else { continue }
            let percent = number.doubleValue
            if percent.isFinite, (0...100).contains(percent) { readings.append(percent) }
        }
        return readings.max()
    }

    /// Reads only WindowServer event totals. This API neither installs an event tap
    /// nor requests Input Monitoring or Accessibility access, and exposes no payload.
    private func readManualActivityCounters() -> ManualActivityCounterSnapshot {
        func count(_ type: CGEventType) -> UInt32 {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
        }
        return ManualActivityCounterSnapshot(
            keyDown: count(.keyDown),
            flagsChanged: count(.flagsChanged),
            mouseMoved: count(.mouseMoved),
            leftDragged: count(.leftMouseDragged),
            rightDragged: count(.rightMouseDragged),
            otherDragged: count(.otherMouseDragged),
            leftMouseDown: count(.leftMouseDown),
            rightMouseDown: count(.rightMouseDown),
            otherMouseDown: count(.otherMouseDown),
            scrollWheel: count(.scrollWheel)
        )
    }

    private func manualActivityCounts(
        previous: ManualActivityCounterSnapshot?,
        current: ManualActivityCounterSnapshot
    ) -> ManualActivityCounts? {
        guard let previous else { return nil }
        let pairs: [(UInt32, UInt32)] = [
            (current.keyDown, previous.keyDown),
            (current.flagsChanged, previous.flagsChanged),
            (current.mouseMoved, previous.mouseMoved),
            (current.leftDragged, previous.leftDragged),
            (current.rightDragged, previous.rightDragged),
            (current.otherDragged, previous.otherDragged),
            (current.leftMouseDown, previous.leftMouseDown),
            (current.rightMouseDown, previous.rightMouseDown),
            (current.otherMouseDown, previous.otherMouseDown),
            (current.scrollWheel, previous.scrollWheel)
        ]
        let deltas = pairs.map {
            TelemetrySemantics.eventCounterDelta(current: $0.0, previous: $0.1)
        }
        guard deltas.allSatisfy({ $0 != nil }) else { return nil }
        let values = deltas.map { $0 ?? 0 }
        return ManualActivityCounts(
            keyboardEvents: values[0] &+ values[1],
            pointerEvents: values[2] &+ values[3] &+ values[4] &+ values[5],
            clickEvents: values[6] &+ values[7] &+ values[8],
            scrollEvents: values[9]
        )
    }

    private func cpuPercent(previous: CPUCounter?, current: CPUCounter) -> Double {
        guard let previous else { return 0 }
        let delta = cpuTickDelta(previous: previous, current: current)
        let total = delta.total
        let busy = delta.busy
        guard total > 0 else { return 0 }
        return min(100, max(0, Double(busy) / Double(total) * 100))
    }

    private func cpuClusterReading(
        previous: [CPUCounter]?,
        current: [CPUCounter]?,
        topology: CPUCoreTopology,
        aggregateCPUPercent: Double
    ) -> CPUClusterReading? {
        guard let previous, let current,
              previous.count == current.count,
              current.count == topology.kindsByProcessorIndex.count else { return nil }

        var performanceBusy: UInt64 = 0
        var performanceTotal: UInt64 = 0
        var efficiencyBusy: UInt64 = 0
        var efficiencyTotal: UInt64 = 0
        for index in current.indices {
            let delta = cpuTickDelta(previous: previous[index], current: current[index])
            switch topology.kindsByProcessorIndex[index] {
            case .performance:
                performanceBusy &+= delta.busy
                performanceTotal &+= delta.total
            case .efficiency:
                efficiencyBusy &+= delta.busy
                efficiencyTotal &+= delta.total
            }
        }
        guard performanceTotal > 0, efficiencyTotal > 0 else { return nil }
        let allBusy = performanceBusy &+ efficiencyBusy
        let contribution = allBusy == 0
            ? 0
            : aggregateCPUPercent * Double(performanceBusy) / Double(allBusy)
        return CPUClusterReading(
            performancePercent: min(100, Double(performanceBusy) / Double(performanceTotal) * 100),
            efficiencyPercent: min(100, Double(efficiencyBusy) / Double(efficiencyTotal) * 100),
            performanceContributionPercent: min(aggregateCPUPercent, max(0, contribution))
        )
    }

    private func cpuTickDelta(previous: CPUCounter, current: CPUCounter) -> (busy: UInt64, total: UInt64) {
        let user = cpuTickDelta(previous.user, current.user)
        let system = cpuTickDelta(previous.system, current.system)
        let nice = cpuTickDelta(previous.nice, current.nice)
        let idle = cpuTickDelta(previous.idle, current.idle)
        return (user &+ system &+ nice, user &+ system &+ nice &+ idle)
    }

    private func cpuTickDelta(_ previous: UInt64, _ current: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        let modulus = UInt64(UInt32.max) + 1
        guard previous < modulus, current < modulus else { return 0 }
        return modulus - previous + current
    }

    private func readLoadAverage() -> (Double, Double) {
        var values = [Double](repeating: 0, count: 3)
        let read = getloadavg(&values, 3)
        return read >= 2 ? (values[0], values[1]) : (0, 0)
    }

    private func readMemory() -> (used: UInt64, total: UInt64, reclaimable: UInt64, compressed: UInt64) {
        var total: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        _ = sysctlbyname("hw.memsize", &total, &totalSize, nil, 0)
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total, 0, 0) }
        let page = UInt64(pageSize)
        let free = UInt64(info.free_count) &* page
        let speculative = UInt64(info.speculative_count) &* page
        let inactive = UInt64(info.inactive_count) &* page
        let purgeable = UInt64(info.purgeable_count) &* page
        let compressed = UInt64(info.compressor_page_count) &* page
        let active = UInt64(info.active_count) &* page
        let wired = UInt64(info.wire_count) &* page
        let reclaimable = min(total, free &+ speculative &+ inactive &+ purgeable)
        let meaningfulUse = min(total, active &+ wired &+ compressed)
        return (meaningfulUse, total, reclaimable, compressed)
    }

    private func pressureLevel(memory: (used: UInt64, total: UInt64, reclaimable: UInt64, compressed: UInt64), swapUsed: UInt64, swapGrowth: UInt64) -> MemoryPressureLevel {
        guard memory.total > 0 else { return .low }
        let reclaimable = Double(memory.reclaimable) / Double(memory.total)
        let compressed = Double(memory.compressed) / Double(memory.total)
        if (reclaimable < 0.03 && compressed > 0.18 && swapUsed > 2_000_000_000) || swapGrowth > 1_000_000_000 { return .high }
        if (reclaimable < 0.06 && compressed > 0.12 && swapUsed > 512_000_000) || swapGrowth > 256_000_000 { return .elevated }
        return .low
    }

    private func readSwap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private func readThermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    private func readBattery() -> BatteryReading {
        let sourceType = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?
        let source: PowerSource
        if sourceType == kIOPSACPowerValue as String { source = .adapter }
        else if sourceType == kIOPSBatteryPowerValue as String { source = .battery }
        else { source = .unknown }

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryReading(percent: nil, source: source, charging: nil)
        }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, item)?.takeUnretainedValue() as? [String: Any] else { continue }
            let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue
            let percent = current.flatMap { current in maximum.flatMap { $0 > 0 ? current / $0 * 100 : nil } }
            let charging = (description[kIOPSIsChargingKey as String] as? NSNumber)?.boolValue
            if percent != nil { return BatteryReading(percent: percent, source: source, charging: charging) }
        }
        return BatteryReading(percent: nil, source: source, charging: nil)
    }

    private func readNetwork() -> NetworkCounter? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var byteCount = 0
        guard sysctl(&mib, u_int(mib.count), nil, &byteCount, nil, 0) == 0, byteCount > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: byteCount)
        guard sysctl(&mib, u_int(mib.count), &buffer, &byteCount, nil, 0) == 0 else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var offset = 0
        buffer.withUnsafeBytes { bytes in
            while offset + 4 <= byteCount {
                let messageLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength >= 4, offset + messageLength <= byteCount else { break }
                let messageType = bytes[offset + 3]
                if Int32(messageType) == RTM_IFINFO2,
                   messageLength >= MemoryLayout<if_msghdr2>.size {
                    let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_flags & IFF_UP != 0, message.ifm_flags & IFF_LOOPBACK == 0 {
                        received &+= message.ifm_data.ifi_ibytes
                        sent &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
        return NetworkCounter(received: received, sent: sent)
    }

    private func readDisk() -> DiskCounter? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let value = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let statistics = value as? [String: Any] else { continue }
            read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return DiskCounter(read: read, written: written)
    }

    private func currentProcessMemoryFallback() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private func adaptiveInterval(base: TimeInterval, isIdle: Bool, battery: BatteryReading, monitorCPU: Double) -> TimeInterval {
        var interval = min(60, max(10, base))
        if isIdle { interval = max(interval, 60) }
        if battery.source == .battery && ProcessInfo.processInfo.isLowPowerModeEnabled { interval = max(interval, 30) }
        if monitorCPU > 1.5 { interval = min(60, max(interval, base * 2)) }
        return interval
    }

    private func positiveDelta(_ current: UInt64, _ previous: UInt64?) -> UInt64 {
        guard let previous, current >= previous else { return 0 }
        return current - previous
    }

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> TimeInterval {
        let parts = start.duration(to: end).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func sanitize(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.value != 0x2028 && $0.value != 0x2029 }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? "Unknown process" : clean).prefix(120))
    }

}
