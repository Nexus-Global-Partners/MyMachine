import Foundation

public struct EventDetector: Sendable {
    private var highCPUSeconds: TimeInterval = 0
    private var cpuEventOpen = false
    private var elevatedMemorySeconds: TimeInterval = 0
    private var memoryEventOpen = false
    private var overheadSeconds: TimeInterval = 0
    private var overheadEventOpen = false
    private var lastThermal: ThermalLevel = .unknown
    private var lastSwap: UInt64?
    private var lastSwapEventAt: Date?

    public init() {}

    public mutating func resetAfterGap() {
        highCPUSeconds = 0
        cpuEventOpen = false
        elevatedMemorySeconds = 0
        memoryEventOpen = false
        overheadSeconds = 0
        overheadEventOpen = false
        lastSwap = nil
        lastSwapEventAt = nil
    }

    public mutating func observe(_ sample: SystemSample) -> [ActivityEvent] {
        let duration = min(max(1, sample.duration), max(2, sample.samplingInterval * 2.2))
        var events: [ActivityEvent] = []

        if sample.cpuPercent >= 75 {
            highCPUSeconds += duration
        } else if !cpuEventOpen {
            highCPUSeconds = 0
        } else if sample.cpuPercent < 60 {
            highCPUSeconds = 0
            cpuEventOpen = false
        }
        if highCPUSeconds >= 120 && !cpuEventOpen {
            cpuEventOpen = true
            events.append(ActivityEvent(
                timestamp: sample.timestamp,
                type: .sustainedCPU,
                title: "The Mac was working hard for several minutes",
                explanation: "Whole-machine CPU use remained above 75% for about two minutes while \(sample.foregroundApp) was in front. This coincided with the load; it does not prove the foreground app alone was responsible. Sustained demand can increase heat and battery use.",
                severity: .notable
            ))
        }

        if sample.memoryPressure != .low {
            elevatedMemorySeconds += duration
        } else {
            elevatedMemorySeconds = 0
            memoryEventOpen = false
        }
        if elevatedMemorySeconds >= 300 && !memoryEventOpen {
            memoryEventOpen = true
            events.append(ActivityEvent(
                timestamp: sample.timestamp,
                type: .memoryPressure,
                title: "Memory demand stayed elevated",
                explanation: "Memory pressure was above its comfortable range for roughly five minutes, with \(Formatters.bytes(sample.swapUsedBytes)) of swap allocated. macOS was managing the demand safely, but switching among heavy apps may have felt slower.",
                severity: sample.memoryPressure == .high ? .important : .notable
            ))
        }

        if let lastSwap, sample.swapUsedBytes > lastSwap, sample.swapUsedBytes - lastSwap >= 1_000_000_000,
           lastSwapEventAt == nil || sample.timestamp.timeIntervalSince(lastSwapEventAt!) >= 15 * 60 {
            events.append(ActivityEvent(
                timestamp: sample.timestamp,
                type: .swapGrowth,
                title: "Swap allocation grew quickly",
                explanation: "macOS allocated another \(Formatters.bytes(sample.swapUsedBytes - lastSwap)) of disk-backed memory during this interval. That is not dangerous, but combined with elevated memory pressure it can reduce responsiveness.",
                severity: .notable
            ))
            lastSwapEventAt = sample.timestamp
        }
        self.lastSwap = sample.swapUsedBytes

        if sample.thermalLevel != lastThermal,
           sample.thermalLevel == .serious || sample.thermalLevel == .critical {
            events.append(ActivityEvent(
                timestamp: sample.timestamp,
                type: .thermal,
                title: sample.thermalLevel == .critical ? "macOS reported critical thermal pressure" : "macOS reported serious thermal pressure",
                explanation: sample.thermalLevel == .critical
                    ? "Heat was severe enough that performance was likely constrained to protect the hardware. The state is safe, but the active workload was operating with little thermal headroom."
                    : "Heat was high enough that performance may have been managed by macOS. This reading does not expose temperature or prove that a particular app caused it.",
                severity: .important
            ))
        }
        lastThermal = sample.thermalLevel

        if sample.monitorCPUPercent >= 1.5 {
            overheadSeconds += duration
        } else if sample.monitorCPUPercent < 0.8 {
            overheadSeconds = 0
            overheadEventOpen = false
        }
        if overheadSeconds >= 120 && !overheadEventOpen {
            overheadEventOpen = true
            events.append(ActivityEvent(
                timestamp: sample.timestamp,
                type: .monitorOverhead,
                title: "MY MACHINE reduced its own sampling rate",
                explanation: "The monitor's observed CPU use stayed above its low-overhead target, so it slowed collection automatically. Reports remain useful, with slightly less timeline detail during this period.",
                severity: .notable
            ))
        }

        return events
    }
}
