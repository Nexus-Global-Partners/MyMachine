import Foundation
import IOKit

/// A physical fan reading. The percentage is RPM / the fan's reported maximum,
/// not an estimate of fan power, heat, noise, or CPU/GPU demand.
public struct FanReading: Equatable, Sendable {
    public let index: Int
    public let rpm: Double
    public let maximumRPM: Double

    public init?(index: Int, rpm: Double, maximumRPM: Double) {
        guard index >= 0, rpm.isFinite, maximumRPM.isFinite,
              rpm >= 0, maximumRPM > 0, rpm <= maximumRPM * 1.2 else { return nil }
        self.index = index
        self.rpm = rpm
        self.maximumRPM = maximumRPM
    }

    public var percentOfMaximum: Double {
        min(100, rpm / maximumRPM * 100)
    }

    public var speedDescription: String {
        if rpm == 0 { return "Off" }
        if percentOfMaximum >= 70 { return "Fast" }
        if percentOfMaximum >= 40 { return "Active" }
        return "Low"
    }
}

/// Read-only access to AppleSMC fan keys. A missing key is never interpreted as
/// zero RPM; zero is shown only when the physical actual-speed key returns zero.
public enum FanTelemetry {
    public static func read() -> [FanReading]? {
        guard let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")) as io_service_t?,
              service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }

        guard let countValue = readKey("FNum", connection: connection),
              let count = decodeNumber(countValue),
              count >= 0, count <= 8 else { return nil }

        var readings: [FanReading] = []
        for index in 0..<Int(count) {
            guard let actual = readKey("F\(index)Ac", connection: connection).flatMap(decodeNumber),
                  let maximum = readKey("F\(index)Mx", connection: connection).flatMap(decodeNumber),
                  let reading = FanReading(index: index, rpm: actual, maximumRPM: maximum)
            else { continue }
            readings.append(reading)
        }
        return readings.isEmpty && count > 0 ? nil : readings
    }

    private struct Value {
        let type: String
        let bytes: [UInt8]
    }

    private static func readKey(_ name: String, connection: io_connect_t) -> Value? {
        guard name.utf8.count == 4 else { return nil }
        let key = name.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        var infoInput = [UInt8](repeating: 0, count: 80)
        putUInt32(key, at: 0, in: &infoInput)
        infoInput[42] = 9 // kSMCGetKeyInfo
        guard let info = call(infoInput, connection: connection), info[40] == 0 else { return nil }
        let size = Int(getUInt32(info, at: 28))
        guard (1...32).contains(size) else { return nil }
        let typeCode = getUInt32(info, at: 32)
        let typeBytes = (0..<4).map { UInt8(truncatingIfNeeded: typeCode >> (24 - 8 * $0)) }
        guard let type = String(bytes: typeBytes, encoding: .ascii) else { return nil }

        var valueInput = [UInt8](repeating: 0, count: 80)
        putUInt32(key, at: 0, in: &valueInput)
        putUInt32(UInt32(size), at: 28, in: &valueInput)
        valueInput[42] = 5 // kSMCReadKey; this reader never sends write commands.
        guard let value = call(valueInput, connection: connection), value[40] == 0 else { return nil }
        return Value(type: type, bytes: Array(value[48..<(48 + size)]))
    }

    private static func call(_ input: [UInt8], connection: io_connect_t) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count
        let result = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                IOConnectCallStructMethod(
                    connection, 2, inputBytes.baseAddress, input.count,
                    outputBytes.baseAddress, &outputSize
                )
            }
        }
        return result == KERN_SUCCESS && outputSize == 80 ? output : nil
    }

    private static func decodeNumber(_ value: Value) -> Double? {
        let bytes = value.bytes
        switch value.type {
        case "ui8 ":
            guard bytes.count == 1 else { return nil }
            return Double(bytes[0])
        case "ui16":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let number = Double(Float(bitPattern: bits))
            return number.isFinite ? number : nil
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }

    private static func putUInt32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    private static func getUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) {
            $0 | UInt32(bytes[offset + $1]) << (8 * $1)
        }
    }
}
