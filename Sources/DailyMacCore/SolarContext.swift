import Foundation

public struct SolarLocation: Codable, Equatable, Sendable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name; self.latitude = latitude; self.longitude = longitude
    }
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

public enum SolarPhase: String, Sendable {
    case day = "Day", twilight = "Twilight", night = "Night"
}

public struct SolarBand: Sendable {
    public let interval: DateInterval
    public let phase: SolarPhase
}

/// NOAA's fractional-year solar-position approximation. These are astronomical
/// estimates, not weather observations or promises about visible light.
/// https://gml.noaa.gov/grad/solcalc/solareqns.PDF
public enum SolarContext {
    public static func elevation(at date: Date, location: SolarLocation) -> Double? {
        guard location.isValid else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let day = calendar.ordinality(of: .day, in: .year, for: date),
              let days = calendar.range(of: .day, in: .year, for: date)?.count else { return nil }
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
        let gamma = 2 * Double.pi / Double(days) * (Double(day - 1) + (hour - 12) / 24)
        let equation = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                                - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let hourAngle = (hour * 60 + equation + 4 * location.longitude) / 4 - 180
        let latitude = location.latitude * .pi / 180
        let sine = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle * .pi / 180)
        return asin(max(-1, min(1, sine))) * 180 / .pi
    }

    public static func phase(at date: Date, location: SolarLocation) -> SolarPhase? {
        guard let elevation = elevation(at: date, location: location) else { return nil }
        // Apparent sunrise/sunset includes the solar disk and standard refraction.
        return elevation >= -0.833 ? .day : elevation >= -6 ? .twilight : .night
    }

    public static func bands(in interval: DateInterval, location: SolarLocation) -> [SolarBand] {
        guard interval.duration > 0, interval.duration <= 32 * 86400,
              var current = phase(at: interval.start, location: location) else { return [] }
        var start = interval.start
        var cursor = start
        var result: [SolarBand] = []
        while cursor < interval.end {
            let next = min(interval.end, cursor.addingTimeInterval(60))
            guard let nextPhase = phase(at: next, location: location) else { return [] }
            if nextPhase != current {
                var low = cursor
                var high = next
                // Refine the transition within a one-minute sampling bracket.
                for _ in 0..<8 {
                    let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                    if phase(at: middle, location: location) == current { low = middle }
                    else { high = middle }
                }
                result.append(SolarBand(interval: DateInterval(start: start, end: high), phase: current))
                start = high
                current = nextPhase
            }
            cursor = next
        }
        if start < interval.end { result.append(SolarBand(interval: DateInterval(start: start, end: interval.end), phase: current)) }
        return result
    }
}
