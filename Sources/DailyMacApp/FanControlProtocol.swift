import Foundation
import Security

/// No arbitrary commands, file paths, SMC keys, or shell arguments cross XPC.
@objc protocol FanControlServiceProtocol {
    func status(withReply reply: @escaping (Data?, String?) -> Void)
    func setAllFans(percent: Double, withReply reply: @escaping (Data?, String?) -> Void)
    func automatic(withReply reply: @escaping (Data?, String?) -> Void)
    func prepareToUnregister(withReply reply: @escaping (Data?, String?) -> Void)
    func heartbeat(withReply reply: @escaping (Bool) -> Void)
}

enum FanControlServiceIdentity {
    static let name = "local.mymachine.fancontrol.service"
    static let plistName = name + ".plist"
    static let argument = "--fan-helper"
    static let restoreArgument = "--fan-helper-restore"

    /// App and root helper are two modes of exactly the same signed executable.
    /// Pin the loaded code-directory hash, not a forgeable bundle identifier or
    /// a PID resolved after the connection was established. XPC enforces this
    /// requirement against each peer's audit token for every incoming message.
    static func ownRequirement() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else {
            throw IdentityError.invalidSignature
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { throw IdentityError.invalidSignature }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any],
              let hash = details[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty,
              let flags = details[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x10000 != 0 else { // CS_RUNTIME
            throw IdentityError.invalidSignature
        }
        let result = "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(result as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else {
            throw IdentityError.invalidSignature
        }
        // Recheck the loaded dynamic code against the derived hash: replacing
        // the bundle on disk cannot silently change our peer identity.
        return result
    }

    enum IdentityError: LocalizedError {
        case invalidSignature
        var errorDescription: String? { "Fan control requires the packaged, signed MY MACHINE app with hardened runtime." }
    }
}
