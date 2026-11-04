import Darwin
import Foundation

/// Private intent journal independent of SQLite and its recovery copies.
enum LocalEraseReceipt: String {
    case requested = "v1:requested"
    case legacyCleanup = "v1:legacy-cleanup"
    case recoveryReview = "v1:recovery-review"

    private static let name = ".erase-receipt"

    static func read(in directory: URL) throws -> Self? {
        let path = directory.appendingPathComponent(name).path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw failure
        }
        try requirePrivateFile(path, info: info)
        guard info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 32,
              let result = Self(rawValue: try String(contentsOfFile: path, encoding: .utf8)) else {
            throw failure
        }
        return result
    }

    func persist(in directory: URL) throws {
        _ = try Self.read(in: directory)
        let destination = directory.appendingPathComponent(Self.name).path
        var template = directory.appendingPathComponent(".erase-stage.XXXXXXXX").path.utf8CString
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw Self.failure }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        defer { Darwin.close(fd); unlink(temporary) }
        let data = Data(rawValue.utf8)
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard wrote == data.count else { throw Self.ioError("write erase receipt") }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw Self.ioError("sync erase receipt") }
        guard rename(temporary, destination) == 0 else { throw Self.ioError("publish erase receipt") }
        try Self.sync(directory)
    }

    static func clear(in directory: URL) throws {
        guard try read(in: directory) != nil else { return }
        guard unlink(directory.appendingPathComponent(name).path) == 0 else { throw failure }
        try sync(directory)
    }

    static func secureDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR else { throw failure }
        try requireNoACL(url.path)
        guard chmod(url.path, 0o700) == 0 else { throw failure }
    }

    static func secureFileIfPresent(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw failure
        }
        try requirePrivateFile(path, info: info)
        guard chmod(path, 0o600) == 0 else { throw failure }
    }

    private static func requirePrivateFile(_ path: String, info: stat) throws {
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else { throw failure }
        try requireNoACL(path)
    }

    private static func requireNoACL(_ path: String) throws {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw failure
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        guard result == -1, errno == EINVAL else { throw failure }
    }

    static func acquireWriterLock(in directory: URL) throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw StoreError.cannotOpen("Another MY MACHINE process has this local history open.")
        }
        return fd
    }

    static func sync(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw ioError("sync history directory") }
    }

    private static func ioError(_ action: String) -> StoreError { .write("Could not \(action) (errno \(errno)).") }

    private static var failure: StoreError { .write("Could not verify private local storage or its erase receipt.") }
}
