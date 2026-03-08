import Foundation

/// Production ProcessLockProvider using flock() for advisory file locking.
/// Ensures only one vcompress process operates on a given destination at a time.
final class RealProcessLock: ProcessLockProvider {
    /// File descriptor for the lock file, or -1 if not held.
    private var fd: Int32 = -1

    func acquireLock(at url: URL) throws -> Bool {
        // Create parent directory if needed
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        // Open or create the lock file
        let path = url.path
        let fileFD = open(path, O_CREAT | O_RDWR, 0o644)
        guard fileFD >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }

        // Try non-blocking exclusive lock
        let result = flock(fileFD, LOCK_EX | LOCK_NB)
        if result != 0 {
            close(fileFD)
            if errno == EWOULDBLOCK {
                return false
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }

        self.fd = fileFD
        return true
    }

    func releaseLock() throws {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}
