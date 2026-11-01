import DailyMacCore
import Foundation

/// All writes below target an in-memory fake, never AppleSMC or physical fans.
enum FanControlValidation {
    static func run(harness: ValidationHarness) async {
        await harness.run("fan controls probe every fan and preserve percentage of each maximum") {
            let transport = try FakeFanControlTransport(ranges: [(1_000, 4_000), (3_000, 6_000)])
            let engine = FanControlEngine(transport: transport)
            let initial = try engine.readState()
            try harness.check(initial.fans.count == 2 && initial.minimumPercent == 50, "shared minimum did not protect every fan")
            try harness.check(transport.writes.isEmpty, "read-only status changed a fan")
            let controlled = try engine.setAllFans(percent: 50)
            try harness.check(controlled.fans.map(\.targetRPM) == [2_000, 3_000], "same percentage did not map to each physical maximum")
            try harness.check(controlled.fans.map(\.actualRPM) == initial.fans.map(\.actualRPM), "requested RPM was fabricated as actual physical speed")
            try harness.check(controlled.ownsManualControl && controlled.requestedPercent == 50, "confirmed ownership was not reported")
            let automatic = try engine.restoreAutomatic()
            try harness.check(automatic.fans.allSatisfy { $0.mode == 0 } && !automatic.ownsManualControl,
                              "Auto failed to relinquish all owned fans")
            try harness.check(transport.writes.allSatisfy { $0.0.hasSuffix("md") || $0.0.hasSuffix("Md") || $0.0.hasSuffix("Tg") },
                              "control wrote an unlock/global/unsupported key")
        }

        await harness.run("fan controls reject invalid bounds incomplete hardware and missing recovery journal") {
            let transport = try FakeFanControlTransport(ranges: [(2_317, 6_550)])
            let engine = FanControlEngine(transport: transport)
            let initial = try engine.readState()
            try harness.check(initial.minimumPercent == 36, "Mac17,2 manual minimum was rounded downward")
            for invalid in [-1.0, 0, 35, 101, .nan, .infinity] {
                try mustFail { _ = try engine.setAllFans(percent: invalid) }
            }
            try harness.check(transport.writes.isEmpty, "invalid slider values actuated a fan")
            for unsafeTarget in [0.0, 999, 6_001] {
                let automatic = try FakeFanControlTransport(ranges: [(1_000, 4_000), (1_000, 6_000)])
                automatic.values["F1Tg"] = try .rpm(unsafeTarget)
                let controller = FanControlEngine(transport: automatic)
                let status = try controller.readState()
                try harness.check(!status.manualControlAvailable, "unsafe automatic target was advertised as manually controllable")
                try mustFail { _ = try controller.setAllFans(percent: 80) }
                try harness.check(automatic.writes.isEmpty, "manual entry froze a stopped or out-of-range automatic fan")
            }
            let changedDuringJournal = try FakeFanControlTransport(ranges: [(1_000, 4_000)])
            let rechecking = FanControlEngine(transport: changedDuringJournal, journal: { record in
                if record != nil { changedDuringJournal.values["F0Tg"] = try .rpm(0) }
            })
            try mustFail { _ = try rechecking.setAllFans(percent: 80) }
            try harness.check(changedDuringJournal.writes.isEmpty,
                              "manual mode was entered after the automatic target stopped during journaling")
            let incomplete = try FakeFanControlTransport(ranges: [(1_000, 4_000), (1_000, 6_000)])
            incomplete.values.removeValue(forKey: "F1Mx")
            try mustFail { _ = try FanControlEngine(transport: incomplete).setAllFans(percent: 80) }
            try harness.check(incomplete.writes.isEmpty, "partial fan discovery changed the first fan")
            transport.requiresPersistentJournal = true
            try mustFail { _ = try engine.setAllFans(percent: 50) }
            try harness.check(transport.writes.isEmpty, "manual control began without durable recovery evidence")
            let upperCase = try FakeFanControlTransport(ranges: [(1_000, 4_000)], uppercaseMode: true, targetType: "fpe2")
            let upperEngine = FanControlEngine(transport: upperCase)
            let upperState = try upperEngine.setAllFans(percent: 60)
            try harness.check(upperState.fans[0].targetRPM == 2_400,
                              "supported uppercase direct mode/fpe2 hardware was not probed correctly")
            _ = try upperEngine.restoreAutomatic()
        }

        await harness.run("fan controls refuse external manual and protected thermal modes") {
            for mode: UInt8 in [1, 3] {
                let transport = try FakeFanControlTransport(ranges: [(1_000, 4_000)])
                transport.values["F0md"] = .mode(mode)
                let engine = FanControlEngine(transport: transport)
                let initial = try engine.readState()
                try harness.check(!initial.manualControlAvailable, "external/system control was advertised as available")
                try mustFail { _ = try engine.setAllFans(percent: 70) }
                if mode == 1 { try mustFail { _ = try engine.restoreAutomatic() } }
                else { _ = try engine.restoreAutomatic() }
                try harness.check(transport.writes.isEmpty, "another controller's mode was overridden")
            }
            let changed = try FakeFanControlTransport(ranges: [(1_000, 4_000)])
            let engine = FanControlEngine(transport: changed)
            _ = try engine.setAllFans(percent: 50)
            changed.values["F0Tg"] = try .rpm(2_500)
            let writesBefore = changed.writes.count
            try mustFail { _ = try engine.restoreAutomatic() }
            let changedMode = try changed.read("F0md").number()
            try harness.check(changed.writes.count == writesBefore && changedMode == 1,
                              "Auto stole a changed external manual target")
            try harness.check(FanControlEngine.shouldRestore(thermal: .serious)
                              && FanControlEngine.shouldRestore(thermal: .critical)
                              && FanControlEngine.shouldRestore(thermal: .unknown)
                              && !FanControlEngine.shouldRestore(thermal: .nominal),
                              "thermal fallback policy failed closed incorrectly")
        }

        await harness.run("all-fan failure and ignored hardware writes restore owned modes") {
            for ignoreInsteadOfFail in [false, true] {
                let transport = try FakeFanControlTransport(ranges: [(1_000, 4_000), (1_000, 6_000)])
                if ignoreInsteadOfFail { transport.ignoredKeys = ["F1Tg"] }
                else { transport.failWriteNumber = 4 }
                let engine = FanControlEngine(transport: transport)
                try mustFail { _ = try engine.setAllFans(percent: 70) }
                let state = try engine.readState()
                try harness.check(state.fans.allSatisfy { $0.mode == 0 } && !state.ownsManualControl,
                                  "partial all-fan failure left an owned fan in manual mode")
            }
            let ignoredMode = try FakeFanControlTransport(ranges: [(1_000, 4_000)])
            ignoredMode.ignoredKeys = ["F0md"]
            let engine = FanControlEngine(transport: ignoredMode)
            try mustFail { _ = try engine.setAllFans(percent: 70) }
            try harness.check(!ignoredMode.writes.contains { $0.0 == "F0Tg" }, "target was written without mode acknowledgement")
            let failedRollback = try FakeFanControlTransport(ranges: [(1_000, 4_000), (1_000, 6_000)])
            failedRollback.failedWriteNumbers = [4, 5]
            var remainingJournal: FanControlOwnershipJournal?
            let recoverable = FanControlEngine(transport: failedRollback, journal: { remainingJournal = $0 })
            try mustFail { _ = try recoverable.setAllFans(percent: 70) }
            let partial = try recoverable.readState()
            try harness.check(partial.ownsManualControl && partial.requestedPercent == nil && remainingJournal != nil,
                              "failed rollback was reported as Auto or discarded its recovery journal")
            let recovered = try recoverable.restoreAutomatic()
            try harness.check(!recovered.ownsManualControl && remainingJournal == nil,
                              "retained recovery ownership could not be retried")
        }

        await harness.run("fan ownership is journaled before writes and survives each interrupted transition") {
            let transport = try FakeFanControlTransport(ranges: [(1_000, 4_000), (1_000, 6_000)])
            transport.requiresPersistentJournal = true
            var saved: FanControlOwnershipJournal?
            var checkpoints: [(FanControlOwnershipJournal, [String: FanControlSMCValue])] = []
            transport.afterWrite = {
                guard let saved else { throw FanControlError.operationFailed("SMC write preceded its recovery journal") }
                checkpoints.append((saved, transport.values))
            }
            let engine = FanControlEngine(transport: transport, journal: { saved = $0 })
            _ = try engine.setAllFans(percent: 70)
            transport.afterWrite = nil
            try harness.check(checkpoints.count == 4, "not every mode/target transition was checked")
            for (journal, values) in checkpoints {
                let recovered = try FakeFanControlTransport(ranges: [(1_000, 4_000), (1_000, 6_000)])
                recovered.values = values
                var remainingJournal: FanControlOwnershipJournal? = journal
                let restart = FanControlEngine(transport: recovered, journal: { remainingJournal = $0 })
                let state = try restart.recoverOwnedControl(from: journal)
                try harness.check(state.fans.allSatisfy { $0.mode == 0 } && remainingJournal == nil,
                                  "interrupted mode/target operation could not restore its owned state")
            }
            let cannotJournal = try FakeFanControlTransport(ranges: [(1_000, 4_000)])
            let blocked = FanControlEngine(transport: cannotJournal, journal: { _ in
                throw FanControlError.operationFailed("fixture journal unavailable")
            })
            try mustFail { _ = try blocked.setAllFans(percent: 70) }
            try harness.check(cannotJournal.writes.isEmpty, "failed write-ahead persistence still actuated hardware")
        }

        await harness.run("fan crash recovery rejects forged keys and preserves changed external ownership") {
            let transport = try FakeFanControlTransport(ranges: [(1_000, 4_000)])
            var saved: FanControlOwnershipJournal?
            let engine = FanControlEngine(transport: transport, journal: { saved = $0 })
            _ = try engine.setAllFans(percent: 70)
            guard let saved else { throw ValidationFailure.failed("ownership was not persisted") }
            let encoded = try JSONEncoder().encode(saved)
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            var records = object["fans"] as! [[String: Any]]
            records[0]["modeKey"] = "Ftst"
            object["fans"] = records
            let forged = try JSONDecoder().decode(FanControlOwnershipJournal.self, from: JSONSerialization.data(withJSONObject: object))
            let recovery = FanControlEngine(transport: transport)
            let beforeForgery = transport.writes.count
            try mustFail { _ = try recovery.recoverOwnedControl(from: forged) }
            try harness.check(transport.writes.count == beforeForgery, "forged journal caused an arbitrary key write")
            transport.values["F0Tg"] = try .rpm(3_000)
            try mustFail { _ = try recovery.recoverOwnedControl(from: saved) }
            try harness.check(transport.writes.count == beforeForgery, "recovery stole another controller's changed target")
        }
    }

    private static func mustFail(_ body: () throws -> Void) throws {
        do { try body() }
        catch is FanControlError { return }
        throw ValidationFailure.failed("Unsafe or unsupported fan operation unexpectedly succeeded")
    }
}

private final class FakeFanControlTransport: FanControlTransport {
    let hardwareIdentifier = "FixtureMac"
    var requiresPersistentJournal = false
    var values: [String: FanControlSMCValue] = [:]
    var writes: [(String, FanControlSMCValue)] = []
    var failWriteNumber: Int?
    var failedWriteNumbers = Set<Int>()
    var ignoredKeys = Set<String>()
    var afterWrite: (() throws -> Void)?

    init(ranges: [(Double, Double)], uppercaseMode: Bool = false, targetType: String = "flt ") throws {
        values["FNum"] = .mode(UInt8(ranges.count))
        for (index, range) in ranges.enumerated() {
            values["F\(index)Mn"] = try .rpm(range.0)
            values["F\(index)Mx"] = try .rpm(range.1)
            values["F\(index)Ac"] = try .rpm(range.0)
            values["F\(index)Tg"] = try .rpm(range.0, type: targetType)
            values["F\(index)\(uppercaseMode ? "Md" : "md")"] = .mode(0)
        }
    }

    func read(_ key: String) throws -> FanControlSMCValue {
        guard let value = values[key] else { throw FanControlError.keyUnavailable(key) }
        return value
    }

    func write(_ key: String, value: FanControlSMCValue) throws {
        writes.append((key, value))
        if failWriteNumber == writes.count || failedWriteNumbers.contains(writes.count) {
            throw FanControlError.operationFailed("fixture write failure")
        }
        if !ignoredKeys.contains(key) { values[key] = value }
        try afterWrite?()
    }
}
