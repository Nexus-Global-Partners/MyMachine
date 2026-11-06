import Darwin
import Foundation
import IOKit.ps

public struct HostCPUCounters: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let nice: UInt64
    public let idle: UInt64

    public init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.user = user
        self.system = system
        self.nice = nice
        self.idle = idle
    }

    public func delta(since previous: HostCPUCounters) -> (busy: UInt64, total: UInt64)? {
        guard let user = SystemMetrics.hostCPUTickDelta(current: user, previous: previous.user),
              let system = SystemMetrics.hostCPUTickDelta(current: system, previous: previous.system),
              let nice = SystemMetrics.hostCPUTickDelta(current: nice, previous: previous.nice),
              let idle = SystemMetrics.hostCPUTickDelta(current: idle, previous: previous.idle) else { return nil }
        return (user + system + nice, user + system + nice + idle)
    }
}

/// A failed read clears the baseline. Recovery therefore needs two successful
/// snapshots; absent or unchanged ticks never establish measured zero CPU.
public struct HostCPUTracker: Sendable {
    private var previous: HostCPUCounters?

    public init() {}

    public mutating func observe(_ current: HostCPUCounters?) -> Double? {
        defer { previous = current }
        guard let current, let previous, let delta = current.delta(since: previous), delta.total > 0 else { return nil }
        return Double(delta.busy) / Double(delta.total) * 100
    }
}

/// Public, whole-machine sensors shared by both distribution channels.
enum SystemMetrics {
    static func hostCPUTickDelta(current: UInt64, previous: UInt64) -> UInt64? {
        guard current <= UInt32.max, previous <= UInt32.max else { return nil }
        return counterDelta(current: UInt32(current), previous: UInt32(previous))
    }

    static func counterDelta(current: UInt32, previous: UInt32) -> UInt64? {
        if current >= previous { return UInt64(current - previous) }
        let plausibleRolloverWindow: UInt32 = 1_000_000
        guard previous >= UInt32.max - plausibleRolloverWindow,
              current <= plausibleRolloverWindow else { return nil }
        return UInt64(UInt32.max - previous) + UInt64(current) + 1
    }

    static func readCPUCounter() -> HostCPUCounters? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return HostCPUCounters(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3),
            idle: UInt64(info.cpu_ticks.2)
        )
    }

    static func readMemory() -> (used: UInt64, total: UInt64, reclaimable: UInt64, compressed: UInt64)? {
        let total = ProcessInfo.processInfo.physicalMemory
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard total > 0, host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)
        let free = UInt64(info.free_count) &* page
        let inactive = UInt64(info.inactive_count) &* page
        let purgeable = UInt64(info.purgeable_count) &* page
        let compressed = UInt64(info.compressor_page_count) &* page
        let active = UInt64(info.active_count) &* page
        let wired = UInt64(info.wire_count) &* page
        // vm_statistics64 documents speculative_count as already included in
        // free_count. Adding it again understates this app's pressure heuristic.
        let reclaimable = min(total, free &+ inactive &+ purgeable)
        let meaningfulUse = min(total, active &+ wired &+ compressed)
        return (meaningfulUse, total, reclaimable, compressed)
    }

    static func readThermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    static func readBattery() -> BatteryReading {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return BatteryReading(percent: nil, source: .unknown, charging: nil)
        }
        let sourceType = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String?
        let source: PowerSource
        if sourceType == kIOPSACPowerValue as String { source = .adapter }
        else if sourceType == kIOPSBatteryPowerValue as String { source = .battery }
        else { source = .unknown }

        guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryReading(percent: nil, source: source, charging: nil)
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return BatteryTelemetry.reading(descriptions: descriptions, providingSource: source)
    }
}
