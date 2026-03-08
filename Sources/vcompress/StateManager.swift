import Foundation

/// Errors specific to StateManager operations.
public enum StateManagerError: Error, Equatable {
    case processLockFailed
    case corruptStateFile(String)
}

/// Manages persistent state for the vcompress encoding pipeline.
/// Tracks which files have been encoded, their status, and handles
/// crash recovery by resetting in-progress entries on load.
public actor StateManager {
    public let fs: FileSystemProvider
    public let lock: ProcessLockProvider
    public let clock: Clock
    public let stateURL: URL
    public let lockURL: URL
    public let destDir: URL
    public let fresh: Bool

    /// The in-memory state representation.
    private var state: StateFile

    /// Timestamp of the last flush to disk.
    private var lastFlush: Date

    /// Whether there are unsaved changes since the last flush.
    private var dirty: Bool = false

    /// Preset string for the current run (derived from lossless flag).
    private let preset: String

    // MARK: - Initialization

    public init(
        destDir: URL,
        fs: FileSystemProvider,
        lock: ProcessLockProvider,
        clock: Clock,
        fresh: Bool = false,
        lossless: Bool = false
    ) {
        self.destDir = destDir
        self.fs = fs
        self.lock = lock
        self.clock = clock
        self.fresh = fresh
        self.preset = lossless ? "hevc_lossless" : "hevc_highest_quality"
        self.stateURL = destDir.appendingPathComponent(".vcompress-state.json")
        self.lockURL = destDir.appendingPathComponent(".vcompress.lock")
        self.state = StateFile(
            version: 1,
            created: clock.now(),
            updated: clock.now(),
            files: [:]
        )
        self.lastFlush = Date.distantPast
    }

    // MARK: - Load

    /// Load state from disk. Acquires the process lock, reads/parses the
    /// state file, resets in-progress entries to pending, and cleans
    /// orphaned .tmp files.
    public func load() throws {
        // Acquire process lock
        let locked = try lock.acquireLock(at: lockURL)
        guard locked else {
            throw StateManagerError.processLockFailed
        }

        if fresh {
            // --fresh: ignore existing state, start clean
            state = StateFile(
                version: 1,
                created: clock.now(),
                updated: clock.now(),
                files: [:]
            )
        } else if let data = fs.contents(atPath: stateURL.path) {
            // Try to parse existing state file
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                state = try decoder.decode(StateFile.self, from: data)

                // Reset any in_progress entries to pending
                for (key, entry) in state.files {
                    if entry.status == .inProgress {
                        state.files[key]?.status = .pending
                    }
                }
            } catch {
                // Corrupt JSON: log and start fresh
                state = StateFile(
                    version: 1,
                    created: clock.now(),
                    updated: clock.now(),
                    files: [:]
                )
            }
        } else {
            // No state file on disk: create default
            state = StateFile(
                version: 1,
                created: clock.now(),
                updated: clock.now(),
                files: [:]
            )
        }

        // Clean orphaned .tmp files in dest tree
        cleanOrphanedTmpFiles()
    }

    // MARK: - Save / Flush

    /// Save state to disk if enough time has elapsed since the last flush
    /// (debounce: >1 second). Marks state as dirty if not yet flushed.
    public func save() throws {
        dirty = true
        let now = clock.now()
        if now.timeIntervalSince(lastFlush) > 1.0 {
            try flush()
        }
    }

    /// Force-write state to disk regardless of debounce timing.
    public func flush() throws {
        state.updated = clock.now()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try fs.write(data, to: stateURL, atomically: true)
        lastFlush = clock.now()
        dirty = false
    }

    // MARK: - Status Transitions

    /// Mark a file as in-progress.
    public func markInProgress(
        relativePath: String,
        preset: String,
        sourceSize: Int64
    ) throws {
        state.files[relativePath] = StateFileEntry(
            status: .inProgress,
            preset: preset,
            sourceSize: sourceSize,
            startedAt: clock.now()
        )
        try save()
    }

    /// Mark a file as completed.
    public func markCompleted(
        relativePath: String,
        preset: String,
        sourceSize: Int64,
        outputSize: Int64
    ) throws {
        state.files[relativePath] = StateFileEntry(
            status: .completed,
            preset: preset,
            sourceSize: sourceSize,
            outputSize: outputSize,
            startedAt: state.files[relativePath]?.startedAt ?? clock.now(),
            completedAt: clock.now()
        )
        try save()
    }

    /// Mark a file as failed.
    public func markFailed(
        relativePath: String,
        preset: String,
        sourceSize: Int64,
        error: String
    ) throws {
        state.files[relativePath] = StateFileEntry(
            status: .failed,
            preset: preset,
            sourceSize: sourceSize,
            startedAt: state.files[relativePath]?.startedAt ?? clock.now(),
            error: error
        )
        try save()
    }

    // MARK: - Query

    /// Look up the state entry for a given relative path.
    public func status(for relativePath: String) -> StateFileEntry? {
        state.files[relativePath]
    }

    /// Returns the current in-memory state (for testing/inspection).
    public func currentState() -> StateFile {
        state
    }

    /// Returns the preset string for the current run.
    public func currentPreset() -> String {
        preset
    }

    // MARK: - Private Helpers

    /// Delete orphaned .tmp files in the destination tree.
    private func cleanOrphanedTmpFiles() {
        guard let tmpFiles = try? fs.glob(pattern: "*.tmp", inDirectory: destDir) else {
            return
        }
        for tmpURL in tmpFiles {
            try? fs.removeItem(at: tmpURL)
        }
    }
}
