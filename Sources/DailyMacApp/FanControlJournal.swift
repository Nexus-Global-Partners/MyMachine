import DailyMacCore
import Darwin
import Foundation

/// Only the approved root service creates this directory. openat + O_NOFOLLOW
/// prevents symlink replacement; atomic rename and fsync protect write-ahead
/// ownership evidence across a helper crash or interrupted app update.
final class FanControlJournalStore {
    private let directory: Int32
    private let lockFile: Int32
    private let filename = "ownership.json"

    init() throws {
        guard geteuid() == 0 else { throw FanControlError.permissionRequired }
        let path = "/Library/Application Support/local.mymachine.fancontrol"
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw failure("create recovery directory") }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("open recovery directory") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            close(fd)
            throw FanControlError.unavailable("Fan recovery directory is not private and root-owned.")
        }
        directory = fd
        let lockFD = openat(fd, "service.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { close(fd); throw failure("open recovery lock") }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == 0,
              lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_mode & 0o077 == 0,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); close(fd)
            throw FanControlError.unavailable("A fan helper is already running, or its lock is not trusted.")
        }
        lockFile = lockFD
    }

    deinit { close(lockFile); close(directory) }

    func load() throws -> FanControlOwnershipJournal? {
        let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("read recovery record") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 65_536 else {
            throw FanControlError.unavailable("Fan recovery record is not trusted.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var count = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while count < buffer.count {
                let n = read(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw failure("read complete recovery record") }
                count += n
            }
        }
        return try JSONDecoder().decode(FanControlOwnershipJournal.self, from: Data(bytes))
    }

    func save(_ journal: FanControlOwnershipJournal?) throws {
        guard let journal else {
            if unlinkat(directory, filename, 0) != 0 && errno != ENOENT { throw failure("clear recovery record") }
            guard fsync(directory) == 0 else { throw failure("sync cleared recovery record") }
            return
        }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 65_536 else { throw FanControlError.invalidRequest("Fan recovery record is too large.") }
        let temporary = ".ownership-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("write recovery record") }
        defer { close(fd); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw failure("write complete recovery record") }
                offset += n
            }
        }
        guard fsync(fd) == 0,
              renameat(directory, temporary, directory, filename) == 0,
              fsync(directory) == 0 else { throw failure("commit recovery record") }
    }
}

private func failure(_ operation: String) -> FanControlError {
    .operationFailed("Could not \(operation): \(String(cString: strerror(errno))).")
}
