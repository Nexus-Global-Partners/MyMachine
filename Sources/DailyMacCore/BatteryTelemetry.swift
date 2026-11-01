import Foundation
import IOKit.ps

public struct BatteryReading: Sendable {
    public let percent: Double?
    public let source: PowerSource
    public let charging: Bool?
}

public enum BatteryTelemetry {
    /// IOPS permits UPS power sources as well as internal batteries. A UPS's
    /// capacity is never the laptop's battery level. Unknown/invalid capacity
    /// does not erase independently reported power or charging state.
    public static func reading(descriptions: [[String: Any]], providingSource: PowerSource) -> BatteryReading {
        let batteries = descriptions.filter {
            ($0[kIOPSTypeKey as String] as? String) == kIOPSInternalBatteryType as String
                && ($0[kIOPSIsPresentKey as String] as? NSNumber)?.boolValue == true
        }
        // More than one internal battery needs a capacity-weighted aggregation,
        // whose units are not guaranteed by this API. Withhold that ambiguity.
        guard batteries.count == 1, let battery = batteries.first else {
            return BatteryReading(percent: nil, source: providingSource, charging: nil)
        }
        let current = (battery[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue
        let maximum = (battery[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue
        let percent = capacityPercent(current: current, maximum: maximum)
        let charging = (battery[kIOPSIsChargingKey as String] as? NSNumber)?.boolValue
        let state = battery[kIOPSPowerSourceStateKey as String] as? String
        let source: PowerSource
        if state == kIOPSACPowerValue as String {
            source = .adapter
        } else if state == kIOPSBatteryPowerValue as String {
            source = .battery
        } else {
            source = providingSource
        }
        return BatteryReading(percent: percent, source: source, charging: charging)
    }

    public static func capacityPercent(current: Double?, maximum: Double?) -> Double? {
        guard let current, let maximum, current.isFinite, maximum.isFinite,
              current >= 0, maximum > 0, current <= maximum else { return nil }
        return current / maximum * 100
    }
}
