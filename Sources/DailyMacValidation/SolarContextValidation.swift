import DailyMacCore
import Foundation

enum SolarContextValidation {
    static func run(harness: ValidationHarness) async {
        let parser = ISO8601DateFormatter()
        func date(_ value: String) -> Date { parser.date(from: value)! }
        let equator = SolarLocation(name: "Equator", latitude: 0, longitude: 0)
        await harness.run("solar position follows the date and coordinates, not fixed clock hours") {
            let noon = date("2026-03-20T12:00:00Z")
            try harness.check((SolarContext.elevation(at: noon, location: equator) ?? 0) > 85, "equinox noon should be near zenith")
            try harness.check(SolarContext.phase(at: noon, location: equator) == .day, "noon should be day")
            try harness.check(SolarContext.phase(at: noon.addingTimeInterval(-12 * 3600), location: equator) == .night, "midnight should be night")
            let opposite = SolarLocation(name: "Opposite longitude", latitude: 0, longitude: 180)
            try harness.check(SolarContext.phase(at: noon, location: opposite) == .night, "longitude did not shift daylight")
            let invalid = SolarLocation(name: "Invalid", latitude: .nan, longitude: 0)
            try harness.check(SolarContext.phase(at: noon, location: invalid) == nil, "invalid location invented a solar phase")
        }
        await harness.run("solar bands preserve twilight, exact coverage and condensed time mapping") {
            let start = date("2026-03-20T00:00:00Z")
            let window = DateInterval(start: start, duration: 48 * 3600)
            let bands = SolarContext.bands(in: window, location: equator)
            try harness.check(bands.first?.interval.start == window.start && bands.last?.interval.end == window.end, "solar coverage lost endpoints")
            try harness.check(bands.filter { $0.phase == .twilight }.count == 4, "twilight missing from two days")
            for (a, b) in zip(bands, bands.dropFirst()) {
                try harness.check(a.interval.end == b.interval.start, "solar bands overlap or leave gaps")
            }
            let firstSunrise = bands.first { $0.phase == .day }!.interval.start.timeIntervalSince(start) / 3600
            try harness.check(firstSunrise > 5.8 && firstSunrise < 6.4, "equinox sunrise outside expected astronomical range")
            for hours in [1, 4, 6, 12, 24, 48] {
                let span = DateInterval(start: start, duration: Double(hours) * 3600)
                let result = SolarContext.bands(in: span, location: equator)
                try harness.check(abs(result.reduce(0) { $0 + $1.interval.duration } - span.duration) < 0.01, "solar coverage failed at \(hours)h")
                for mode in [TimelineDisplayMode.calm, .precise] {
                    let sleep = DateInterval(start: start, duration: span.duration * 0.7)
                    let awake = DateInterval(start: sleep.end, end: span.end)
                    let regions = InstrumentTimeContext.regions(
                        presence: .init(awakeIntervals: [awake], handsOnIntervals: []), sleeps: [sleep], in: span)
                    let scale = InstrumentTimeScale(window: span, regions: regions, mode: mode)
                    for band in result {
                        try harness.check(scale.fraction(at: band.interval.start) <= scale.fraction(at: band.interval.end), "solar band mapping reversed")
                        let roundTrip = scale.date(at: scale.fraction(at: band.interval.start))
                        try harness.check(abs(roundTrip.timeIntervalSince(band.interval.start)) < 0.01, "condensing moved a solar boundary to another time")
                    }
                }
            }
        }
        await harness.run("solar context handles polar seasons leap day and DST windows") {
            let polar = SolarLocation(name: "Tromsø", latitude: 69.65, longitude: 18.96)
            let summer = DateInterval(start: date("2026-06-21T00:00:00Z"), duration: 86400)
            try harness.check(SolarContext.bands(in: summer, location: polar).allSatisfy { $0.phase == .day }, "polar day invented sunset")
            let winter = DateInterval(start: date("2026-12-21T00:00:00Z"), duration: 86400)
            try harness.check(!SolarContext.bands(in: winter, location: polar).contains { $0.phase == .day }, "polar night invented sunrise")
            try harness.check(SolarContext.elevation(at: date("2028-02-29T12:00:00Z"), location: equator)?.isFinite == true, "leap day invalid")
            let paris = SolarLocation(name: "Paris test fixture", latitude: 48.86, longitude: 2.35)
            for hours in [23, 25] {
                let span = DateInterval(start: date("2026-03-28T23:00:00Z"), duration: Double(hours) * 3600)
                let bands = SolarContext.bands(in: span, location: paris)
                try harness.check(abs(bands.reduce(0) { $0 + $1.interval.duration } - span.duration) < 0.01, "DST-duration window lost coverage")
            }
        }
    }
}
