import Darwin
import Foundation
import Security

/// Only the signed installer provisions this location. Source builds never
/// register a daemon, even if they have been placed in Applications.
enum FanControlInstallation {
    static let directory = "/Library/local.mymachine.app"
    static let appPath = directory + "/MY MACHINE.app"
    static let readyPath = directory + "/fan-migration-complete"
    static let daemonPath = appPath + "/Contents/Library/LaunchDaemons/" + FanControlServiceIdentity.plistName

    static var isOfficialLocation: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path == appPath
    }

    static var isProvisioned: Bool {
        isOfficialLocation && protectedItem(readyPath, directory: false)
    }

    static func verify(requireReady: Bool = true) throws {
        guard isOfficialLocation,
              ["/", "/Library", directory, appPath].allSatisfy({ protectedItem($0, directory: true) }),
              !requireReady || (isProvisioned && legacyHelperIsAbsent),
              let team = Bundle.main.object(forInfoDictionaryKey: "MyMachineDeveloperTeam") as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw FanControlServiceIdentity.IdentityError.invalidSignature
        }
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        var enumerationFailed = false
        guard let entries = FileManager.default.enumerator(
            at: app, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { throw FanControlServiceIdentity.IdentityError.invalidSignature }
        for case let entry as URL in entries {
            guard protectedItem(entry.path) else { throw FanControlServiceIdentity.IdentityError.invalidSignature }
        }
        guard !enumerationFailed else { throw FanControlServiceIdentity.IdentityError.invalidSignature }

        let requirementText = "anchor apple generic and identifier \"local.mymachine.app\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        var running: SecCode?
        var installed: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &installed) == errSecSuccess, let installed,
              SecStaticCodeCheckValidity(installed, flags, requirement) == errSecSuccess else {
            throw FanControlServiceIdentity.IdentityError.invalidSignature
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: daemonPath))
        let expected: NSDictionary = [
            "Label": FanControlServiceIdentity.name,
            "BundleProgram": "Contents/MacOS/DailyMac",
            "ProgramArguments": ["DailyMac", FanControlServiceIdentity.argument],
            "MachServices": [FanControlServiceIdentity.name: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "UserName": "root"
        ]
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary,
              plist == expected else { throw FanControlServiceIdentity.IdentityError.invalidSignature }
    }

    private static var legacyHelperIsAbsent: Bool {
        ["/Library/LaunchDaemons/local.mymachine.fancontrol.plist",
         "/Library/PrivilegedHelperTools/local.mymachine.fancontrol.app"].allSatisfy { path in
            var info = stat()
            return lstat(path, &info) != 0 && errno == ENOENT
        }
    }

    static func protectedItem(_ path: String, directory: Bool? = nil) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o6022 == 0 else { return false }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFDIR || (kind == S_IFREG && info.st_nlink == 1),
              directory.map({ $0 == (kind == S_IFDIR) }) ?? true else { return false }
        return !hasWriteACL(path)
    }

    private static func hasWriteACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writes = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                      ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        var entryID = ACL_FIRST_ENTRY
        var entry: acl_entry_t?
        while acl_get_entry(acl, entryID.rawValue, &entry) == 0 {
            entryID = ACL_NEXT_ENTRY
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { return true }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0 else { return true }
            if writes.contains(where: { acl_get_perm_np(permissions, $0) != 0 }) { return true }
        }
        return errno != EINVAL
    }
}
