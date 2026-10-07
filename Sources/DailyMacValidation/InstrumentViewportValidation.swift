import DailyMacCore
import Foundation

enum InstrumentViewportValidation {
    static func run(harness: ValidationHarness) async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        await harness.run("graph dragging preserves scale and follows the hand across every duration") {
            for span in [3600.0, 21600.0, 86400.0, 172800.0] {
                let window = DateInterval(start: start, duration: span)
                let earlier = InstrumentViewport.panned(window, translation: 100, width: 400,
                    earliest: start.addingTimeInterval(-span), latest: window.end)
                try harness.check(earlier.start == start.addingTimeInterval(-span / 4), "right drag did not reveal earlier time proportionally")
                try harness.check(earlier.duration == span, "drag changed scale")
                let restored = InstrumentViewport.panned(earlier, translation: -100, width: 400,
                    earliest: start.addingTimeInterval(-span), latest: window.end)
                try harness.check(restored == window, "drag not reversible")
            }
        }
        await harness.run("graph drag clamps history and future and rejects invalid geometry") {
            let window = DateInterval(start: start, duration: 3600)
            for translation in [Double.nan, Double.infinity, -Double.infinity] {
                try harness.check(InstrumentViewport.panned(window, translation: translation, width: 400,
                    earliest: start, latest: window.end) == window, "invalid drag moved time")
            }
            for width in [0.0, -1, Double.nan] {
                try harness.check(InstrumentViewport.panned(window, translation: 100, width: width,
                    earliest: start, latest: window.end) == window, "invalid width moved time")
            }
            let bounds = start.addingTimeInterval(-3600)
            try harness.check(InstrumentViewport.panned(window, translation: 99999, width: 400,
                earliest: bounds, latest: window.end).start == bounds, "crossed oldest buffered time")
            try harness.check(InstrumentViewport.panned(window, translation: -99999, width: 400,
                earliest: bounds, latest: window.end).end == window.end, "entered future")
        }
        await harness.run("timeline dates appear only at midnight and calendar boundaries survive DST") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
            let parser = ISO8601DateFormatter()
            let begin = parser.date(from: "2026-03-28T23:00:00Z")!
            let end = parser.date(from: "2026-03-29T22:00:00Z")!
            let ticks = InstrumentViewport.ticks(in: DateInterval(start: begin, end: end), width: 700, calendar: calendar)
            try harness.check(ticks.first == begin && ticks.last == end, "lost exact endpoints")
            try harness.check(Set(ticks).count == ticks.count, "duplicate ticks")
            let boundaries = ticks.filter { InstrumentViewport.isDayBoundary($0, calendar: calendar) }
            try harness.check(boundaries == [begin, end], "dates repeated on ordinary hour ticks")
            try harness.check(end.timeIntervalSince(begin) == 23 * 3600, "DST elapsed time changed")
        }
        await harness.run("graph entrance is staggered monotonic bounded and finishes without modifying readings") {
            for metric in MachineInstrument.allCases {
                let values = (0...110).map { InstrumentEntrance.progress(metric, elapsed: Double($0) / 100) }
                try harness.check(values.first == 0 && values.last == 1, "reveal did not finish")
                try harness.check(values.allSatisfy { (0...1).contains($0) }, "reveal overshot")
                try harness.check(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "reveal reversed")
            }
            try harness.check(InstrumentEntrance.progress(.cpu, elapsed: 0.4) > InstrumentEntrance.progress(.gpu, elapsed: 0.4), "demand lines use identical timing")
            try harness.check(InstrumentEntrance.progress(.gpu, elapsed: 0.4) > InstrumentEntrance.progress(.fan, elapsed: 0.4), "supporting line did not follow demand")
        }
    }
}
