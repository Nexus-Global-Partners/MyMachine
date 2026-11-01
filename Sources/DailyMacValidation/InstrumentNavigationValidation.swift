import DailyMacCore
import Foundation

enum InstrumentNavigationValidation {
    static func run(harness: ValidationHarness) async {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        await harness.run("timeline panning crosses loaded days while respecting retained history") {
            let hour = DateInterval(start: origin, duration: 3600)
            let retention = origin.addingTimeInterval(-30 * 86400)
            let far = InstrumentViewport.panned(hour, translation: 24 * 500, width: 500,
                earliest: retention, latest: hour.end)
            try harness.check(far.start == origin.addingTimeInterval(-86400), "drag still stops at a local buffer")
            try harness.check(far.duration == hour.duration, "pan changed elapsed scale")
            let oldest = InstrumentViewport.panned(hour, translation: 1_000_000, width: 500,
                earliest: retention, latest: hour.end)
            try harness.check(oldest.start == retention, "drag crossed retention boundary")
        }
        await harness.run("sleep jumps use recorded neighbors and keep honest elapsed scale") {
            let gap = DateInterval(start: origin, duration: 8 * 3600)
            let before = DateInterval(start: origin.addingTimeInterval(-7200), duration: 3600)
            let after = DateInterval(start: gap.end.addingTimeInterval(120), duration: 1800)
            let activity = [after, before]
            try harness.check(InstrumentViewport.activityNeighbor(to: gap, direction: -1, recorded: activity) == before.end,
                              "previous activity was inferred inside sleep")
            try harness.check(InstrumentViewport.activityNeighbor(to: gap, direction: 1, recorded: activity) == after.start,
                              "next activity was inferred inside sleep")
            try harness.check(InstrumentViewport.activityNeighbor(to: gap, direction: 1, recorded: [before]) == nil,
                              "jump invented unloaded activity")
            try harness.check(InstrumentViewport.activityNeighbor(to: gap, direction: 0, recorded: activity) == nil,
                              "invalid direction accepted")
            let window = DateInterval(start: origin, duration: 3600)
            let focused = InstrumentViewport.focused(window, on: after.start,
                earliest: before.start, latest: after.end)
            try harness.check(focused.duration == window.duration && focused.contains(after.start), "jump compressed time or missed activity")
            let nearLimit = InstrumentViewport.focused(window, on: before.start,
                earliest: before.start, latest: after.end)
            try harness.check(nearLimit.start == before.start && nearLimit.duration == 3600, "jump escaped retention or changed scale")
        }
        await harness.run("unrecorded coverage and overlapping sleep are never activity jump destinations") {
            let gap = DateInterval(start: origin, duration: 8 * 3600)
            let overlapping = DateInterval(start: origin.addingTimeInterval(-60), duration: 120)
            let empty = DateInterval(start: gap.end, duration: 0)
            for direction in [-1, 1] {
                try harness.check(InstrumentViewport.activityNeighbor(to: gap, direction: direction, recorded: []) == nil,
                                  "empty history produced a jump")
                try harness.check(InstrumentViewport.activityNeighbor(to: gap, direction: direction, recorded: [overlapping, empty]) == nil,
                                  "overlap or empty coverage was treated as separate activity")
            }
        }
    }
}
