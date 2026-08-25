import Foundation

public enum WorkCategory: String, Codable, CaseIterable, Sendable {
    case coding = "Coding & development"
    case research = "Browser use"
    case writing = "Writing"
    case communication = "Communication"
    case design = "Design"
    case meetings = "Meetings app use"
    case files = "File management"
    case media = "Media"
    case music = "Music"
    case administration = "Administration"
    case idle = "Idle"
    case other = "Other"
}

public enum MetricOrigin: String, Codable, CaseIterable, Sendable {
    case measured = "Measured"
    case derived = "Derived"
    case estimated = "Estimated"
    case unavailable = "Unavailable"
}

public struct MetricDisclosure: Identifiable, Codable, Equatable, Sendable {
    public var id: String { metric }
    public let metric: String
    public let origin: MetricOrigin
    public let plainLanguage: String
    public let technicalDetail: String

    public init(metric: String, origin: MetricOrigin, plainLanguage: String, technicalDetail: String) {
        self.metric = metric
        self.origin = origin
        self.plainLanguage = plainLanguage
        self.technicalDetail = technicalDetail
    }
}

public enum ThermalLevel: String, Codable, CaseIterable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    public var explanation: String {
        switch self {
        case .nominal: return "The Mac had comfortable thermal headroom. This was normal and needs no action."
        case .fair: return "The Mac was warm enough for macOS to begin managing heat, but performance was generally unaffected. No action is usually needed."
        case .serious: return "Heat was high enough that macOS may have reduced performance to protect the hardware. Finishing an unneeded heavy workload can restore headroom."
        case .critical: return "Thermal load was severe and likely constrained performance. Letting a heavy task finish or pausing stacked workloads is the useful response."
        case .unknown: return "macOS did not provide a thermal reading."
        }
    }
}

public enum MemoryPressureLevel: String, Codable, CaseIterable, Sendable {
    case low
    case elevated
    case high

    public var explanation: String {
        switch self {
        case .low: return "Memory demand was comfortable, so app switching should have remained responsive."
        case .elevated: return "Memory demand was noticeable. macOS may have compressed memory or used some swap, which can make heavy app switching feel slower."
        case .high: return "Memory was constrained and swap activity was substantial, so responsiveness was likely affected."
        }
    }
}

public enum PowerSource: String, Codable, Sendable {
    case battery
    case adapter
    case unknown
}

/// Content-free counts of hands-on input seen during one measured interval.
///
/// These values describe the density of physical interaction only. They do not
/// contain keys, text, pointer coordinates, targets, or any event payload, and
/// they must not be interpreted as attention or productivity.
public struct ManualActivityCounts: Codable, Equatable, Sendable {
    public let keyboardEvents: UInt64
    public let pointerEvents: UInt64
    public let clickEvents: UInt64
    public let scrollEvents: UInt64

    public init(
        keyboardEvents: UInt64,
        pointerEvents: UInt64,
        clickEvents: UInt64,
        scrollEvents: UInt64
    ) {
        self.keyboardEvents = keyboardEvents
        self.pointerEvents = pointerEvents
        self.clickEvents = clickEvents
        self.scrollEvents = scrollEvents
    }

    public var totalEvents: UInt64 {
        keyboardEvents &+ pointerEvents &+ clickEvents &+ scrollEvents
    }

    /// A duration-normalized, saturating 0...1 indication of hands-on input density.
    /// It intentionally balances high-frequency pointer/scroll packets against the
    /// lower-frequency keyboard and click counters. It is not a focus or effort score.
    public func intensity(over duration: TimeInterval) -> Double {
        let seconds = max(1, duration)
        let keyboardRate = Double(keyboardEvents) / seconds
        let pointerRate = Double(pointerEvents) / seconds
        let clickRate = Double(clickEvents) / seconds
        let scrollRate = Double(scrollEvents) / seconds
        let blendedRate = keyboardRate / 4
            + pointerRate / 100
            + clickRate / 2
            + scrollRate / 40
        return min(1, max(0, 1 - exp(-blendedRate)))
    }
}

public struct SystemSample: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let duration: TimeInterval
    public let foregroundApp: String
    public let foregroundBundleID: String?
    public let category: WorkCategory
    public let isIdle: Bool
    public let cpuPercent: Double
    /// Utilization within the higher-performance core cluster. Nil when the Mac
    /// does not expose a trustworthy heterogeneous-core topology.
    public let performanceCorePercent: Double?
    /// Utilization within the efficiency-core cluster.
    public let efficiencyCorePercent: Double?
    /// Whole-machine CPU percentage points contributed by the higher-performance
    /// cluster. This lets the chart partition its existing aggregate fill exactly.
    public let performanceCoreContributionPercent: Double?
    /// Whole-machine graphics-engine activity reported by the current Mac's
    /// graphics driver. Nil means the driver does not expose a usable reading.
    public let gpuPercent: Double?
    public let loadAverage1m: Double
    public let loadAverage5m: Double
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let memoryPressure: MemoryPressureLevel
    public let swapUsedBytes: UInt64
    public let thermalLevel: ThermalLevel
    public let batteryPercent: Double?
    public let powerSource: PowerSource
    public let isCharging: Bool?
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let networkReceivedBytes: UInt64
    public let networkSentBytes: UInt64
    public let monitorCPUPercent: Double
    public let monitorMemoryBytes: UInt64
    public let monitorDiskWriteBytes: UInt64
    public let samplingInterval: TimeInterval
    public let manualActivity: ManualActivityCounts?

    public init(
        id: UUID = UUID(), timestamp: Date, duration: TimeInterval,
        foregroundApp: String, foregroundBundleID: String?, category: WorkCategory, isIdle: Bool,
        cpuPercent: Double,
        performanceCorePercent: Double? = nil,
        efficiencyCorePercent: Double? = nil,
        performanceCoreContributionPercent: Double? = nil,
        gpuPercent: Double? = nil,
        loadAverage1m: Double, loadAverage5m: Double,
        memoryUsedBytes: UInt64, memoryTotalBytes: UInt64, memoryPressure: MemoryPressureLevel,
        swapUsedBytes: UInt64, thermalLevel: ThermalLevel, batteryPercent: Double?,
        powerSource: PowerSource, isCharging: Bool?, diskReadBytes: UInt64, diskWriteBytes: UInt64,
        networkReceivedBytes: UInt64, networkSentBytes: UInt64, monitorCPUPercent: Double,
        monitorMemoryBytes: UInt64, monitorDiskWriteBytes: UInt64, samplingInterval: TimeInterval,
        manualActivity: ManualActivityCounts? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.foregroundApp = foregroundApp
        self.foregroundBundleID = foregroundBundleID
        self.category = category
        self.isIdle = isIdle
        self.cpuPercent = cpuPercent
        self.performanceCorePercent = performanceCorePercent
        self.efficiencyCorePercent = efficiencyCorePercent
        self.performanceCoreContributionPercent = performanceCoreContributionPercent
        self.gpuPercent = gpuPercent
        self.loadAverage1m = loadAverage1m
        self.loadAverage5m = loadAverage5m
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.thermalLevel = thermalLevel
        self.batteryPercent = batteryPercent
        self.powerSource = powerSource
        self.isCharging = isCharging
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.networkReceivedBytes = networkReceivedBytes
        self.networkSentBytes = networkSentBytes
        self.monitorCPUPercent = monitorCPUPercent
        self.monitorMemoryBytes = monitorMemoryBytes
        self.monitorDiskWriteBytes = monitorDiskWriteBytes
        self.samplingInterval = samplingInterval
        self.manualActivity = manualActivity
    }
}

/// Keeps aggregate charts honest when a time bucket spans legacy, unsupported,
/// or transiently unavailable per-core readings. A split is only meaningful when
/// every sample contributing to that bucket carries the complete measured triple.
public enum CoreDistributionSemantics {
    public static func hasCompleteCoverage(in samples: [SystemSample]) -> Bool {
        !samples.isEmpty && samples.allSatisfy { sample in
            guard let performance = sample.performanceCorePercent,
                  let efficiency = sample.efficiencyCorePercent,
                  let contribution = sample.performanceCoreContributionPercent else { return false }
            return performance.isFinite && efficiency.isFinite && contribution.isFinite
        }
    }
}

/// Describes why a worker can be shown as part of an application. The relationship is
/// deliberately separate from the worker's own name and bundle identifier so MY MACHINE
/// never has to pretend that a helper process is the application executable itself.
public enum ProcessOwnerRelation: String, Codable, CaseIterable, Sendable {
    case application
    case descendant
    case relatedHelper
}

public struct ProcessSample: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let processID: Int32
    public let processStart: UInt64
    public let name: String
    public let bundleID: String?
    public let parentProcessID: Int32?
    public let ownerName: String?
    public let ownerBundleID: String?
    public let ownerRelation: ProcessOwnerRelation?
    public let isForeground: Bool
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let energyNanojoules: UInt64?

    public init(
        id: UUID = UUID(), timestamp: Date, processID: Int32, processStart: UInt64,
        name: String, bundleID: String?, isForeground: Bool, cpuPercent: Double,
        memoryBytes: UInt64, diskReadBytes: UInt64, diskWriteBytes: UInt64,
        energyNanojoules: UInt64?, parentProcessID: Int32? = nil,
        ownerName: String? = nil, ownerBundleID: String? = nil,
        ownerRelation: ProcessOwnerRelation? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.processID = processID
        self.processStart = processStart
        self.name = name
        self.bundleID = bundleID
        self.parentProcessID = parentProcessID
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.ownerRelation = ownerRelation
        self.isForeground = isForeground
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.energyNanojoules = energyNanojoules
    }
}

/// One interval of resource accounting for an application and the processes that can be
/// confidently connected to it. CPU and I/O are measured deltas. Memory is the combined
/// physical footprint of the observed family and can include shared pages.
public struct AppResourceSample: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let duration: TimeInterval
    public let ownerName: String
    public let ownerBundleID: String?
    public let isForeground: Bool
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let processCount: Int
    public let workerCount: Int
    public let agentWorkerCount: Int
    public let workerNames: [String]

    public init(
        id: UUID = UUID(), timestamp: Date, duration: TimeInterval,
        ownerName: String, ownerBundleID: String?, isForeground: Bool,
        cpuPercent: Double, memoryBytes: UInt64, diskReadBytes: UInt64,
        diskWriteBytes: UInt64, processCount: Int, workerCount: Int,
        agentWorkerCount: Int = 0, workerNames: [String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.isForeground = isForeground
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.processCount = processCount
        self.workerCount = workerCount
        self.agentWorkerCount = agentWorkerCount
        self.workerNames = workerNames
    }
}

public struct BackgroundAppSummary: Identifiable, Equatable, Sendable {
    public var id: String { ownerBundleID ?? ownerName }
    public let ownerName: String
    public let ownerBundleID: String?
    public let observedDuration: TimeInterval
    public let backgroundDuration: TimeInterval
    public let backgroundActivityDuration: TimeInterval
    public let averageCPUPercent: Double
    public let peakCPUPercent: Double
    public let cpuCoreSeconds: Double
    public let averageMemoryBytes: UInt64
    public let peakMemoryBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let elevatedMemoryOverlapDuration: TimeInterval
    public let seriousThermalOverlapDuration: TimeInterval
    public let maximumProcessCount: Int
    public let maximumWorkerCount: Int
    public let maximumAgentWorkerCount: Int
    public let workerNames: [String]
    public let latestTimestamp: Date

    public init(
        ownerName: String, ownerBundleID: String?, observedDuration: TimeInterval,
        backgroundDuration: TimeInterval, backgroundActivityDuration: TimeInterval,
        averageCPUPercent: Double, peakCPUPercent: Double, cpuCoreSeconds: Double,
        averageMemoryBytes: UInt64, peakMemoryBytes: UInt64,
        diskReadBytes: UInt64, diskWriteBytes: UInt64,
        elevatedMemoryOverlapDuration: TimeInterval = 0,
        seriousThermalOverlapDuration: TimeInterval = 0,
        maximumProcessCount: Int, maximumWorkerCount: Int,
        maximumAgentWorkerCount: Int = 0,
        workerNames: [String], latestTimestamp: Date
    ) {
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.observedDuration = observedDuration
        self.backgroundDuration = backgroundDuration
        self.backgroundActivityDuration = backgroundActivityDuration
        self.averageCPUPercent = averageCPUPercent
        self.peakCPUPercent = peakCPUPercent
        self.cpuCoreSeconds = cpuCoreSeconds
        self.averageMemoryBytes = averageMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.elevatedMemoryOverlapDuration = elevatedMemoryOverlapDuration
        self.seriousThermalOverlapDuration = seriousThermalOverlapDuration
        self.maximumProcessCount = maximumProcessCount
        self.maximumWorkerCount = maximumWorkerCount
        self.maximumAgentWorkerCount = maximumAgentWorkerCount
        self.workerNames = workerNames
        self.latestTimestamp = latestTimestamp
    }
}

public struct BackgroundActivityPoint: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let duration: TimeInterval
    public let ownerName: String
    public let ownerBundleID: String?
    public let isForeground: Bool
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let diskBytes: UInt64
    public let processCount: Int
    public let workerCount: Int
    public let agentWorkerCount: Int
    public let elevatedMemoryOverlap: Bool
    public let seriousThermalOverlap: Bool

    public init(
        id: UUID, timestamp: Date, duration: TimeInterval,
        ownerName: String, ownerBundleID: String?, isForeground: Bool,
        cpuPercent: Double, memoryBytes: UInt64, diskBytes: UInt64,
        processCount: Int, workerCount: Int, agentWorkerCount: Int,
        elevatedMemoryOverlap: Bool, seriousThermalOverlap: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.isForeground = isForeground
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.processCount = processCount
        self.workerCount = workerCount
        self.agentWorkerCount = agentWorkerCount
        self.elevatedMemoryOverlap = elevatedMemoryOverlap
        self.seriousThermalOverlap = seriousThermalOverlap
    }
}

public enum ActivityEventType: String, Codable, Hashable, Sendable {
    case appLaunched
    case appQuit
    case foregroundChanged
    case sleep
    case wake
    case cpuSpike
    case sustainedCPU
    case memoryPressure
    case swapGrowth
    case thermal
    case batteryDrain
    case monitorOverhead
    case note
}

public enum EventSeverity: Int, Codable, Comparable, Sendable {
    case information = 0
    case notable = 1
    case important = 2

    public static func < (lhs: EventSeverity, rhs: EventSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ActivityEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let type: ActivityEventType
    public let title: String
    public let explanation: String
    public let severity: EventSeverity

    public init(id: UUID = UUID(), timestamp: Date, type: ActivityEventType, title: String, explanation: String, severity: EventSeverity) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.title = title
        self.explanation = explanation
        self.severity = severity
    }
}

public struct AppUsageSummary: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bundleID ?? name }
    public let name: String
    public let bundleID: String?
    public let activeDuration: TimeInterval
    public let averageSystemCPU: Double
    public let averageMemoryBytes: UInt64
    public let interpretation: String
}

public struct CategorySummary: Identifiable, Codable, Equatable, Sendable {
    public var id: String { category.rawValue }
    public let category: WorkCategory
    public let activeDuration: TimeInterval
    public let averageCPU: Double
    public let interpretation: String
}

public enum InsightKind: String, Codable, Sendable {
    case observation
    case efficient
    case caution
    case recommendation
}

public struct ReportInsight: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: InsightKind
    public let title: String
    public let explanation: String
    public let evidence: String?

    public init(id: UUID = UUID(), kind: InsightKind, title: String, explanation: String, evidence: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.explanation = explanation
        self.evidence = evidence
    }
}

public enum MonitoringRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneHour
    case sixHours
    case twentyFourHours

    public var id: String { rawValue }

    public var duration: TimeInterval {
        switch self {
        case .oneHour: return 3_600
        case .sixHours: return 6 * 3_600
        case .twentyFourHours: return 24 * 3_600
        }
    }

    public var label: String {
        switch self {
        case .oneHour: return "1 hour"
        case .sixHours: return "6 hours"
        case .twentyFourHours: return "24 hours"
        }
    }

    public func interval(endingAt end: Date) -> DateInterval {
        DateInterval(start: end.addingTimeInterval(-duration), end: end)
    }
}

public struct MonitoringChartPoint: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let cpuPercent: Double
    public let gpuPercent: Double?
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let memoryPressure: MemoryPressureLevel
    public let swapUsedBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let networkReceivedBytes: UInt64
    public let networkSentBytes: UInt64
    public let batteryPercent: Double?
    public let powerSource: PowerSource
    public let thermalLevel: ThermalLevel
    public let foregroundApp: String
    public let category: WorkCategory
    public let isIdle: Bool
    public let duration: TimeInterval
    public let segment: Int
    public let manualActivity: ManualActivityCounts?

    /// A permission-free estimate of physical interaction density, normalized to
    /// 0...1 for display. `nil` means the interval predates collection or was only
    /// a counter baseline; zero means a measured interval with no input events.
    public var manualActivityIntensity: Double? {
        manualActivity?.intensity(over: duration)
    }

    public init(
        id: UUID, timestamp: Date, cpuPercent: Double, gpuPercent: Double? = nil,
        memoryUsedBytes: UInt64, memoryTotalBytes: UInt64,
        memoryPressure: MemoryPressureLevel, swapUsedBytes: UInt64,
        diskReadBytes: UInt64, diskWriteBytes: UInt64,
        networkReceivedBytes: UInt64, networkSentBytes: UInt64,
        batteryPercent: Double?, powerSource: PowerSource, thermalLevel: ThermalLevel,
        foregroundApp: String, category: WorkCategory, isIdle: Bool,
        duration: TimeInterval, segment: Int, manualActivity: ManualActivityCounts? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.networkReceivedBytes = networkReceivedBytes
        self.networkSentBytes = networkSentBytes
        self.batteryPercent = batteryPercent
        self.powerSource = powerSource
        self.thermalLevel = thermalLevel
        self.foregroundApp = foregroundApp
        self.category = category
        self.isIdle = isIdle
        self.duration = duration
        self.segment = segment
        self.manualActivity = manualActivity
    }
}

public struct MonitoringSnapshot: Equatable, Sendable {
    public let range: MonitoringRange
    public let interval: DateInterval
    public let generatedAt: Date
    public let sampleCount: Int
    public let observedDuration: TimeInterval
    public let longestContinuousCoverage: TimeInterval
    public let activeDuration: TimeInterval
    public let idleDuration: TimeInterval
    public let averageCPU: Double
    public let peakCPU: Double
    public let averageMemoryBytes: UInt64
    public let peakMemoryBytes: UInt64
    public let memoryTotalBytes: UInt64?
    public let peakMemoryPressure: MemoryPressureLevel
    public let elevatedMemoryDuration: TimeInterval
    public let endingSwapBytes: UInt64
    public let swapChangeBytes: Int64?
    public let totalDiskBytes: UInt64
    public let totalNetworkBytes: UInt64
    public let thermalPeak: ThermalLevel
    public let batteryChangePercent: Double?
    public let contextSwitches: Int
    public let applications: [AppUsageSummary]
    public let categories: [CategorySummary]
    public let backgroundApplications: [BackgroundAppSummary]
    public let insights: [ReportInsight]

    public var supportsNarrative: Bool {
        longestContinuousCoverage >= CoverageEvaluator.narrativeMinimum
    }

    public init(
        range: MonitoringRange, interval: DateInterval, generatedAt: Date,
        sampleCount: Int, observedDuration: TimeInterval,
        longestContinuousCoverage: TimeInterval, activeDuration: TimeInterval,
        idleDuration: TimeInterval, averageCPU: Double, peakCPU: Double,
        averageMemoryBytes: UInt64, peakMemoryBytes: UInt64,
        memoryTotalBytes: UInt64?, peakMemoryPressure: MemoryPressureLevel,
        elevatedMemoryDuration: TimeInterval, endingSwapBytes: UInt64,
        swapChangeBytes: Int64?, totalDiskBytes: UInt64 = 0,
        totalNetworkBytes: UInt64 = 0, thermalPeak: ThermalLevel,
        batteryChangePercent: Double?, contextSwitches: Int,
        applications: [AppUsageSummary], categories: [CategorySummary],
        insights: [ReportInsight], backgroundApplications: [BackgroundAppSummary] = []
    ) {
        self.range = range
        self.interval = interval
        self.generatedAt = generatedAt
        self.sampleCount = sampleCount
        self.observedDuration = observedDuration
        self.longestContinuousCoverage = longestContinuousCoverage
        self.activeDuration = activeDuration
        self.idleDuration = idleDuration
        self.averageCPU = averageCPU
        self.peakCPU = peakCPU
        self.averageMemoryBytes = averageMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.peakMemoryPressure = peakMemoryPressure
        self.elevatedMemoryDuration = elevatedMemoryDuration
        self.endingSwapBytes = endingSwapBytes
        self.swapChangeBytes = swapChangeBytes
        self.totalDiskBytes = totalDiskBytes
        self.totalNetworkBytes = totalNetworkBytes
        self.thermalPeak = thermalPeak
        self.batteryChangePercent = batteryChangePercent
        self.contextSwitches = contextSwitches
        self.applications = applications
        self.categories = categories
        self.backgroundApplications = backgroundApplications
        self.insights = insights
    }
}

public struct DailyReport: Identifiable, Codable, Equatable, Sendable {
    public var id: String { dayKey }
    public let dayKey: String
    public let generatedAt: Date
    public let timezoneIdentifier: String
    public let headline: String
    public let overview: String
    public let activeDuration: TimeInterval
    public let idleDuration: TimeInterval
    public let contextSwitches: Int
    public let averageCPU: Double
    public let peakCPU: Double
    public let averageMemoryBytes: UInt64
    public let peakMemoryBytes: UInt64
    public let endingSwapBytes: UInt64
    public let memoryTotalBytes: UInt64?
    public let peakMemoryPressure: MemoryPressureLevel?
    public let totalDiskBytes: UInt64?
    public let totalNetworkBytes: UInt64?
    public let batteryChangePercent: Double?
    public let thermalPeak: ThermalLevel
    public let applications: [AppUsageSummary]
    public let categories: [CategorySummary]
    public let importantMoments: [ReportInsight]
    public let correlations: [ReportInsight]
    public let recommendations: [ReportInsight]
    public let limitations: [String]
    public let sampleCount: Int
    public let longestContinuousCoverage: TimeInterval?
}

public struct ProcessImpact: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(name)-\(processID)" }
    public let timestamp: Date
    public let name: String
    public let ownerName: String?
    public let ownerBundleID: String?
    public let ownerRelation: ProcessOwnerRelation?
    public let processID: Int32
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let diskBytes: UInt64
    public let isForeground: Bool
    public let interpretation: String

    public init(
        timestamp: Date, name: String, processID: Int32,
        cpuPercent: Double, memoryBytes: UInt64, diskBytes: UInt64,
        isForeground: Bool, interpretation: String,
        ownerName: String? = nil, ownerBundleID: String? = nil,
        ownerRelation: ProcessOwnerRelation? = nil
    ) {
        self.timestamp = timestamp
        self.name = name
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.ownerRelation = ownerRelation
        self.processID = processID
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.isForeground = isForeground
        self.interpretation = interpretation
    }
}

public struct TrendSummary: Codable, Equatable, Sendable {
    public let days: Int
    public let activeDuration: TimeInterval
    public let averageDailyCPU: Double
    public let mostUsedCategory: WorkCategory?
    public let notableChange: String?
    public let narrative: String

    public init(days: Int, activeDuration: TimeInterval, averageDailyCPU: Double, mostUsedCategory: WorkCategory?, notableChange: String?, narrative: String) {
        self.days = days
        self.activeDuration = activeDuration
        self.averageDailyCPU = averageDailyCPU
        self.mostUsedCategory = mostUsedCategory
        self.notableChange = notableChange
        self.narrative = narrative
    }
}

public enum DiagnosisDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case copyOnly
    case chatGPT
    case claude

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .copyOnly: return "Copy only"
        case .chatGPT: return "Open ChatGPT"
        case .claude: return "Open Claude"
        }
    }

    public var name: String {
        switch self {
        case .copyOnly: return "the destination"
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        }
    }
}

public struct MonitoringSettings: Codable, Equatable, Sendable {
    public var baseSamplingInterval: TimeInterval
    public var idleThreshold: TimeInterval
    public var rawRetentionDays: Int
    public var eventRetentionDays: Int
    public var reportRetentionDays: Int
    public var processLimit: Int
    public var isPaused: Bool
    public var pauseUntil: Date?
    public var launchAtLoginPreference: Bool?
    public var briefingNotificationsEnabled: Bool?
    /// Optional so settings saved by releases before diagnosis handoff continue
    /// to decode without a migration.
    public var diagnosisDestination: DiagnosisDestination?
    public var diagnosisIncludeApplicationNames: Bool?

    public static let `default` = MonitoringSettings(
        baseSamplingInterval: 15,
        idleThreshold: 300,
        rawRetentionDays: 3,
        eventRetentionDays: 90,
        reportRetentionDays: 365,
        processLimit: 16,
        isPaused: false,
        pauseUntil: nil,
        launchAtLoginPreference: nil,
        briefingNotificationsEnabled: nil,
        diagnosisDestination: .copyOnly,
        diagnosisIncludeApplicationNames: true
    )
}

public enum Formatters {
    public static func duration(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "less than a minute" }
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        if remainder == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }

    public static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    public static func rate(_ bytes: UInt64, over duration: TimeInterval) -> String {
        guard duration > 0 else { return "0 B/s" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(Double(bytes) / duration), countStyle: .file))/s"
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    public static func activeUseToday(_ duration: TimeInterval) -> String {
        guard duration >= 60 else { return "No active use observed today" }
        return "Active today · \(self.duration(duration))"
    }
}
