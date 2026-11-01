import Darwin
import Foundation
import IOKit

public struct FanControlSMCValue: Equatable, Sendable {
    public let type: String
    public let bytes: [UInt8]

    public init(type: String, bytes: [UInt8]) { self.type = type; self.bytes = bytes }
    public static func mode(_ value: UInt8) -> Self { Self(type: "ui8 ", bytes: [value]) }

    public static func rpm(_ value: Double, type: String = "flt ") throws -> Self {
        guard value.isFinite, value >= 0 else { throw FanControlError.invalidRequest("Invalid fan target.") }
        if type == "flt " {
            let number = Float(value)
            guard number.isFinite else { throw FanControlError.invalidRequest("Fan target exceeds its numeric format.") }
            let bits = number.bitPattern
            return Self(type: type, bytes: (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8 * $0)) })
        }
        if type == "fpe2", value <= 16_383.75 {
            let scaled = UInt16((value * 4).rounded())
            return Self(type: type, bytes: [UInt8(scaled >> 8), UInt8(truncatingIfNeeded: scaled)])
        }
        throw FanControlError.unavailable("Unsupported fan RPM format.")
    }

    public func number() throws -> Double {
        let result: Double
        switch type {
        case "ui8 " where bytes.count == 1: result = Double(bytes[0])
        case "ui16" where bytes.count == 2: result = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "fpe2" where bytes.count == 2: result = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "flt " where bytes.count == 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            result = Double(Float(bitPattern: bits))
        default: throw FanControlError.unavailable("Unsupported or malformed fan value.")
        }
        guard result.isFinite else { throw FanControlError.unavailable("Non-finite fan value.") }
        return result
    }
}

public protocol FanControlTransport: AnyObject {
    var hardwareIdentifier: String { get }
    var requiresPersistentJournal: Bool { get }
    func read(_ key: String) throws -> FanControlSMCValue
    func write(_ key: String, value: FanControlSMCValue) throws
}

/// Dedicated helper transport. Read-only telemetry does not depend on this
/// writer. No unlock/force-test/Intel-global keys are writable through this API.
public final class AppleSMCFanControlTransport: FanControlTransport {
    public let hardwareIdentifier: String
    public let requiresPersistentJournal = true
    private var connection: io_connect_t = 0

    public init() throws {
        var length = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 1, length < 256 else {
            throw FanControlError.unavailable("Mac model is unavailable.")
        }
        var model = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &model, &length, nil, 0) == 0 else {
            throw FanControlError.unavailable("Mac model is unavailable.")
        }
        hardwareIdentifier = String(cString: model)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanControlError.unavailable("AppleSMC is unavailable.") }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            throw FanControlError.unavailable("The fan controller could not be opened.")
        }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    public func read(_ key: String) throws -> FanControlSMCValue {
        let info = try metadata(key)
        var request = [UInt8](repeating: 0, count: 80)
        put(fourCC(key), at: 0, into: &request)
        put(UInt32(info.size), at: 28, into: &request)
        request[42] = 5
        let response = try call(request, key: key)
        return FanControlSMCValue(type: info.type, bytes: Array(response[48..<(48 + info.size)]))
    }

    public func write(_ key: String, value: FanControlSMCValue) throws {
        guard geteuid() == 0 else { throw FanControlError.permissionRequired }
        let allowedModes = (0..<8).flatMap { ["F\($0)md", "F\($0)Md"] }
        let allowedTargets = (0..<8).map { "F\($0)Tg" }
        if allowedModes.contains(key) {
            guard value.type == "ui8 ", value.bytes.count == 1, [0, 1].contains(value.bytes[0]) else {
                throw FanControlError.invalidRequest("Unsupported fan mode write.")
            }
            let current = try read(key).number()
            guard current != 3 else { throw FanControlError.systemControl }
            guard current == 0 || current == 1 else { throw FanControlError.unavailable("Unknown fan control mode.") }
            if current == 0, value.bytes[0] == 1 {
                let prefix = String(key.prefix(2))
                let minimum = try read(prefix + "Mn").number()
                let maximum = try read(prefix + "Mx").number()
                let inheritedTarget = try read(prefix + "Tg").number()
                guard minimum > 0, maximum >= minimum,
                      inheritedTarget >= minimum, inheritedTarget <= maximum else {
                    throw FanControlError.unavailable("Automatic fan target is outside its manual limits; mode entry was withheld.")
                }
            }
        } else if allowedTargets.contains(key) {
            guard ["flt ", "fpe2"].contains(value.type), try value.number() > 0 else {
                throw FanControlError.invalidRequest("Unsupported fan target write.")
            }
            let prefix = String(key.prefix(2))
            let minimum = try read(prefix + "Mn").number()
            let maximum = try read(prefix + "Mx").number()
            let target = try value.number()
            guard minimum > 0, maximum >= minimum, target >= minimum, target <= maximum else {
                throw FanControlError.invalidRequest("Fan target is outside the reported hardware limits.")
            }
            let mode: Double
            do { mode = try read(prefix + "md").number() }
            catch FanControlError.keyUnavailable { mode = try read(prefix + "Md").number() }
            guard mode != 3 else { throw FanControlError.systemControl }
            guard mode == 1 else { throw FanControlError.operationFailed("Fan target requires confirmed manual mode.") }
        } else { throw FanControlError.invalidRequest("This hardware key is not writable by fan control.") }
        let info = try metadata(key)
        guard value.type == info.type, value.bytes.count == info.size else {
            throw FanControlError.invalidRequest("Fan write does not match its hardware type.")
        }
        var request = [UInt8](repeating: 0, count: 80)
        put(fourCC(key), at: 0, into: &request)
        put(UInt32(info.size), at: 28, into: &request)
        request[42] = 6
        request.replaceSubrange(48..<(48 + info.size), with: value.bytes)
        _ = try call(request, key: key)
    }

    private func metadata(_ key: String) throws -> (size: Int, type: String) {
        guard key.utf8.count == 4, key.unicodeScalars.allSatisfy(\.isASCII) else {
            throw FanControlError.invalidRequest("Invalid fan key.")
        }
        var request = [UInt8](repeating: 0, count: 80)
        put(fourCC(key), at: 0, into: &request)
        request[42] = 9
        let response = try call(request, key: key)
        let size = Int(get(response, at: 28))
        let type = get(response, at: 32)
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: type >> (24 - 8 * $0)) }
        guard (1...32).contains(size), let name = String(bytes: bytes, encoding: .ascii) else {
            throw FanControlError.unavailable("Malformed fan key metadata.")
        }
        return (size, name)
    }

    private func call(_ request: [UInt8], key: String) throws -> [UInt8] {
        var response = [UInt8](repeating: 0, count: 80)
        var size = response.count
        let result = request.withUnsafeBytes { input in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, request.count, output.baseAddress, &size)
            }
        }
        guard result == KERN_SUCCESS, size == 80 else {
            throw FanControlError.operationFailed("Fan hardware call failed (\(result)).")
        }
        if response[40] == 0x84 { throw FanControlError.keyUnavailable(key) }
        guard response[40] == 0 else {
            throw FanControlError.operationFailed("Fan hardware rejected \(key) (\(response[40])).")
        }
        return response
    }

    private func fourCC(_ key: String) -> UInt32 { key.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private func put(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
    private func get(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}
