import Foundation

public struct FanControlFanState: Codable, Equatable, Sendable {
    public let index: Int
    public let actualRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double
    public let mode: Int
}

public struct FanControlSnapshot: Codable, Equatable, Sendable {
    public let fans: [FanControlFanState]
    public let minimumPercent: Double
    public let requestedPercent: Double?
    public let ownsManualControl: Bool
    public let manualControlAvailable: Bool
}

/// Root-owned write-ahead evidence, not a general-purpose SMC command list.
public struct FanControlOwnedFan: Codable, Equatable, Sendable {
    public let index: Int
    public let modeKey: String
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let allowedTargetRPM: [Double]
}

public struct FanControlOwnershipJournal: Codable, Equatable, Sendable {
    public let version: Int
    public let hardwareIdentifier: String
    public let fans: [FanControlOwnedFan]
}

public enum FanControlError: Error, LocalizedError {
    case unavailable(String)
    case invalidRequest(String)
    case keyUnavailable(String)
    case permissionRequired
    case externalControl
    case systemControl
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail), .invalidRequest(let detail), .operationFailed(let detail): return detail
        case .keyUnavailable(let key): return "Required fan key \(key) is unavailable."
        case .permissionRequired: return "Fan control requires the approved administrator helper."
        case .externalControl: return "Another controller changed the fan setting. MY MACHINE will not take over its manual control."
        case .systemControl: return "macOS currently owns protected thermal control. Manual fan control is unavailable."
        }
    }
}

/// The helper owns authentication, lease expiry, sleep handling, and its durable
/// journal store. This engine serializes complete all-fan actions and never
/// writes during initialization or status reads. The callback must atomically
/// persist and sync the root-owned journal, or throw, before returning.
public final class FanControlEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let transport: any FanControlTransport
    private let journal: ((FanControlOwnershipJournal?) throws -> Void)?
    private var owned: [Int: FanControlOwnedFan] = [:]
    private var requestedPercent: Double?

    public init(transport: any FanControlTransport,
                journal: ((FanControlOwnershipJournal?) throws -> Void)? = nil) {
        self.transport = transport
        self.journal = journal
    }

    public convenience init(journal: ((FanControlOwnershipJournal?) throws -> Void)? = nil) throws {
        try self.init(transport: AppleSMCFanControlTransport(), journal: journal)
    }

    public static func shouldRestore(thermal: ThermalLevel) -> Bool {
        thermal == .serious || thermal == .critical || thermal == .unknown
    }

    public func readState() throws -> FanControlSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot(try probe())
    }

    public func setAllFans(percent: Double) throws -> FanControlSnapshot {
        lock.lock(); defer { lock.unlock() }
        let fans = try probe()
        let minimum = minimumPercent(fans)
        guard percent.isFinite, percent >= minimum, percent <= 100 else {
            throw FanControlError.invalidRequest("Choose a fan speed from \(Int(minimum))% to 100%, or Auto.")
        }
        guard !transport.requiresPersistentJournal || journal != nil else {
            throw FanControlError.unavailable("Fan control needs a durable administrator-helper recovery journal.")
        }
        if !owned.isEmpty, Set(owned.keys) != Set(fans.map { $0.state.index }) {
            throw FanControlError.unavailable("Fan ownership is incomplete or the hardware changed. Restore automatic control before continuing.")
        }
        for fan in fans {
            guard fan.state.mode != 3 else { throw FanControlError.systemControl }
            if fan.state.mode == 1, !matchesOwnership(fan.state) { throw FanControlError.externalControl }
            if fan.state.mode == 0 { try requireSafeAutomaticTarget(fan.state.targetRPM, fan: fan.state) }
        }
        do {
            for fan in fans {
                let index = fan.state.index
                let currentMode = try readMode(fan.modeKey)
                let currentTarget = try number("F\(index)Tg")
                guard currentMode != 3 else { throw FanControlError.systemControl }
                guard currentMode == 0 || (currentMode == 1 && matchesTarget(currentTarget, owner: owned[index])) else {
                    throw FanControlError.externalControl
                }
                if currentMode == 0 { try requireSafeAutomaticTarget(currentTarget, fan: fan.state) }
                let target = min(fan.state.maximumRPM, max(fan.state.minimumRPM, fan.state.maximumRPM * percent / 100))
                let encodedTarget = try FanControlSMCValue.rpm(target, type: fan.targetType)
                let representedTarget = try encodedTarget.number()
                var next = owned
                // The previous and intended targets are both possible if the
                // helper dies between the mode and target writes.
                next[index] = FanControlOwnedFan(index: index, modeKey: fan.modeKey,
                    minimumRPM: fan.state.minimumRPM, maximumRPM: fan.state.maximumRPM,
                    allowedTargetRPM: [currentTarget, representedTarget])
                try persist(next)
                if currentMode == 0 {
                    // Mode entry inherits the existing target until the target
                    // write completes. Recheck after durable journaling so a
                    // stopped/underspeed Auto fan is never knowingly latched
                    // into manual mode, including on interruption here.
                    let entryTarget = try number("F\(index)Tg")
                    try requireSafeAutomaticTarget(entryTarget, fan: fan.state)
                    guard close(entryTarget, currentTarget) else {
                        throw FanControlError.operationFailed("The automatic fan target changed. Try again after it settles.")
                    }
                    try transport.write(fan.modeKey, value: .mode(1))
                    guard try readMode(fan.modeKey) == 1 else {
                        throw FanControlError.operationFailed("Fan \(index + 1) did not enter manual mode.")
                    }
                }
                guard matchesTarget(try number("F\(index)Tg"), owner: owned[index]) else {
                    throw FanControlError.externalControl
                }
                try transport.write("F\(index)Tg", value: encodedTarget)
                guard try readMode(fan.modeKey) == 1,
                      close(try number("F\(index)Tg"), representedTarget) else {
                    throw FanControlError.operationFailed("Fan \(index + 1) did not confirm the requested target.")
                }
                next[index] = FanControlOwnedFan(index: index, modeKey: fan.modeKey,
                    minimumRPM: fan.state.minimumRPM, maximumRPM: fan.state.maximumRPM,
                    allowedTargetRPM: [representedTarget])
                try persist(next)
            }
            requestedPercent = percent
            let result = try probe()
            guard result.allSatisfy({ matchesOwnership($0.state) }) else { throw FanControlError.externalControl }
            return snapshot(result)
        } catch {
            requestedPercent = nil
            do { try restoreOwned() }
            catch let restorationError {
                throw FanControlError.operationFailed("Fan change failed, and automatic restoration is not confirmed: \(restorationError.localizedDescription)")
            }
            throw error
        }
    }

    public func restoreAutomatic() throws -> FanControlSnapshot {
        lock.lock(); defer { lock.unlock() }
        requestedPercent = nil
        try restoreOwned()
        let fans = try probe()
        guard !fans.contains(where: { $0.state.mode == 1 }) else { throw FanControlError.externalControl }
        return snapshot(fans)
    }

    /// Only a trusted root-owned journal may be supplied. Runtime validation
    /// additionally prevents the journal from naming arbitrary writable keys.
    public func recoverOwnedControl(from saved: FanControlOwnershipJournal) throws -> FanControlSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard owned.isEmpty, saved.version == 1,
              saved.hardwareIdentifier == transport.hardwareIdentifier,
              (1...8).contains(saved.fans.count),
              Set(saved.fans.map(\.index)).count == saved.fans.count else {
            throw FanControlError.unavailable("Fan recovery journal does not match this machine.")
        }
        let current = try probe()
        for record in saved.fans {
            guard (0..<8).contains(record.index),
                  record.modeKey == "F\(record.index)md" || record.modeKey == "F\(record.index)Md",
                  let fan = current.first(where: { $0.state.index == record.index }),
                  fan.modeKey == record.modeKey,
                  close(fan.state.minimumRPM, record.minimumRPM), close(fan.state.maximumRPM, record.maximumRPM),
                  (1...2).contains(record.allowedTargetRPM.count),
                  record.allowedTargetRPM.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= record.maximumRPM * 1.2 }) else {
                throw FanControlError.unavailable("Fan recovery journal contains unsupported hardware state.")
            }
        }
        owned = Dictionary(uniqueKeysWithValues: saved.fans.map { ($0.index, $0) })
        requestedPercent = nil
        try restoreOwned()
        let fans = try probe()
        guard !fans.contains(where: { $0.state.mode == 1 }) else { throw FanControlError.externalControl }
        return snapshot(fans)
    }

    private struct ProbedFan {
        let state: FanControlFanState
        let modeKey: String
        let targetType: String
    }

    private func probe() throws -> [ProbedFan] {
        let count = try number("FNum")
        guard count.rounded(.towardZero) == count, (1...8).contains(count) else {
            throw FanControlError.unavailable("No complete controllable physical fan set is available.")
        }
        return try (0..<Int(count)).map { index in
            let modeKey: String
            do { _ = try transport.read("F\(index)md"); modeKey = "F\(index)md" }
            catch FanControlError.keyUnavailable { modeKey = "F\(index)Md" }
            let mode = try readMode(modeKey)
            guard [0, 1, 3].contains(mode) else { throw FanControlError.unavailable("Fan \(index + 1) has an unsupported mode.") }
            let minimum = try number("F\(index)Mn")
            let maximum = try number("F\(index)Mx")
            let actual = try number("F\(index)Ac")
            let targetValue = try transport.read("F\(index)Tg")
            guard ["flt ", "fpe2"].contains(targetValue.type) else {
                throw FanControlError.unavailable("Fan \(index + 1) exposes an unsupported target format.")
            }
            let target = try targetValue.number()
            guard minimum > 0, maximum >= minimum, actual >= 0, actual <= maximum * 1.2,
                  target >= 0, target <= maximum * 1.2 else {
                throw FanControlError.unavailable("Fan \(index + 1) has invalid RPM limits or readings.")
            }
            return ProbedFan(state: FanControlFanState(index: index, actualRPM: actual,
                minimumRPM: minimum, maximumRPM: maximum, targetRPM: target, mode: mode),
                modeKey: modeKey, targetType: targetValue.type)
        }
    }

    private func minimumPercent(_ fans: [ProbedFan]) -> Double {
        ceil(fans.map { $0.state.minimumRPM / $0.state.maximumRPM * 100 }.max() ?? 100)
    }

    private func snapshot(_ fans: [ProbedFan]) -> FanControlSnapshot {
        let ownedCount = fans.filter { matchesOwnership($0.state) }.count
        return FanControlSnapshot(fans: fans.map(\.state), minimumPercent: minimumPercent(fans),
            requestedPercent: ownedCount == fans.count ? requestedPercent : nil,
            ownsManualControl: ownedCount > 0,
            manualControlAvailable: fans.allSatisfy {
                ($0.state.mode == 0 && automaticTargetIsSafe($0.state.targetRPM, fan: $0.state)) || matchesOwnership($0.state)
            })
    }

    private func automaticTargetIsSafe(_ target: Double, fan: FanControlFanState) -> Bool {
        target.isFinite && target >= fan.minimumRPM && target <= fan.maximumRPM
    }

    private func requireSafeAutomaticTarget(_ target: Double, fan: FanControlFanState) throws {
        guard automaticTargetIsSafe(target, fan: fan) else {
            throw FanControlError.unavailable("Fan \(fan.index + 1) is automatically targeting a speed outside its manual limits. Keep Auto until macOS returns it to range.")
        }
    }

    private func number(_ key: String) throws -> Double { try transport.read(key).number() }

    private func readMode(_ key: String) throws -> Int {
        let value = try transport.read(key)
        guard value.type == "ui8 ", value.bytes.count == 1 else {
            throw FanControlError.unavailable("The fan mode format is unsupported.")
        }
        return Int(value.bytes[0])
    }

    private func matchesOwnership(_ state: FanControlFanState) -> Bool {
        state.mode == 1 && matchesTarget(state.targetRPM, owner: owned[state.index])
    }

    private func matchesTarget(_ target: Double, owner: FanControlOwnedFan?) -> Bool {
        owner?.allowedTargetRPM.contains(where: { close($0, target) }) == true
    }

    private func close(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= 0.5
    }

    private func persist(_ next: [Int: FanControlOwnedFan]) throws {
        let value = next.isEmpty ? nil : FanControlOwnershipJournal(version: 1,
            hardwareIdentifier: transport.hardwareIdentifier, fans: next.values.sorted { $0.index < $1.index })
        try journal?(value)
        owned = next
    }

    private func restoreOwned() throws {
        var failures: [Int] = []
        for owner in owned.values.sorted(by: { $0.index < $1.index }) {
            do {
                let mode = try readMode(owner.modeKey)
                if mode == 1 {
                    let target = try number("F\(owner.index)Tg")
                    if matchesTarget(target, owner: owner) {
                        try transport.write(owner.modeKey, value: .mode(0))
                        let restored = try readMode(owner.modeKey)
                        guard restored == 0 || restored == 3 else {
                            throw FanControlError.operationFailed("Automatic mode was not acknowledged.")
                        }
                    }
                    // A different target belongs to an external controller.
                    // Relinquish our journal ownership without touching it.
                } else if mode != 0 && mode != 3 {
                    throw FanControlError.operationFailed("Unknown fan mode prevents safe restoration.")
                }
                var next = owned
                next.removeValue(forKey: owner.index)
                try persist(next)
            } catch { failures.append(owner.index + 1) }
        }
        if !failures.isEmpty {
            throw FanControlError.operationFailed("Automatic mode could not be confirmed for fan(s) \(failures.map(String.init).joined(separator: ", ")).")
        }
    }
}
