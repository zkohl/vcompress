import Foundation
@testable import vcompress

/// Mock ProcessLockProvider for testing StateManager lock acquisition.
final class MockProcessLock: ProcessLockProvider {

    /// Whether acquireLock should succeed.
    var shouldSucceed: Bool = true

    /// Track calls for assertions.
    var acquireLockCalls: [URL] = []
    var releaseLockCallCount: Int = 0

    /// Whether the lock is currently held.
    private(set) var isLocked: Bool = false

    func acquireLock(at url: URL) throws -> Bool {
        acquireLockCalls.append(url)
        if shouldSucceed {
            isLocked = true
            return true
        }
        return false
    }

    func releaseLock() throws {
        releaseLockCallCount += 1
        isLocked = false
    }
}
