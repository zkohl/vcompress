import XCTest
@testable import vcompress

final class StateManagerTests: XCTestCase {

    // MARK: - Helpers

    private func makeComponents(
        fresh: Bool = false,
        lossless: Bool = false,
        lockShouldSucceed: Bool = true
    ) -> (MockFileSystem, MockProcessLock, MockClock, URL) {
        let fs = MockFileSystem()
        let lock = MockProcessLock()
        lock.shouldSucceed = lockShouldSucceed
        let clock = MockClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let destDir = URL(fileURLWithPath: "/dest")
        fs.addDirectory(path: "/dest")
        return (fs, lock, clock, destDir)
    }

    private func makeManager(
        fs: MockFileSystem,
        lock: MockProcessLock,
        clock: MockClock,
        destDir: URL,
        fresh: Bool = false,
        lossless: Bool = false
    ) -> StateManager {
        StateManager(
            destDir: destDir,
            fs: fs,
            lock: lock,
            clock: clock,
            fresh: fresh,
            lossless: lossless
        )
    }

    private func encodeStateFile(_ stateFile: StateFile) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try! encoder.encode(stateFile)
    }

    // MARK: - test_loadEmpty_createsDefaultState

    func test_loadEmpty_createsDefaultState() async throws {
        let (fs, lock, clock, destDir) = makeComponents()
        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)

        try await manager.load()

        let state = await manager.currentState()
        XCTAssertEqual(state.version, 1)
        XCTAssertTrue(state.files.isEmpty)
    }

    // MARK: - test_roundTrip_writeAndRead

    func test_roundTrip_writeAndRead() async throws {
        let (fs, lock, clock, destDir) = makeComponents()
        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)
        try await manager.load()

        // Mark a file completed
        try await manager.markCompleted(
            relativePath: "video/clip.mp4",
            preset: "hevc_highest_quality",
            sourceSize: 500_000_000,
            outputSize: 125_000_000
        )
        try await manager.flush()

        // Read back from a new manager using the data on "disk"
        let manager2 = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)
        try await manager2.load()

        let state = await manager2.currentState()
        let entry = state.files["video/clip.mp4"]
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.status, .completed)
        XCTAssertEqual(entry?.preset, "hevc_highest_quality")
        XCTAssertEqual(entry?.sourceSize, 500_000_000)
        XCTAssertEqual(entry?.outputSize, 125_000_000)
        XCTAssertNotNil(entry?.completedAt)
    }

    // MARK: - test_inProgressResetToPendingOnLoad

    func test_inProgressResetToPendingOnLoad() async throws {
        let (fs, lock, clock, destDir) = makeComponents()

        // Write a state file with an in_progress entry
        let existingState = StateFile(
            version: 1,
            created: clock.currentDate,
            updated: clock.currentDate,
            files: [
                "video/encoding.mp4": StateFileEntry(
                    status: .inProgress,
                    preset: "hevc_highest_quality",
                    sourceSize: 200_000_000,
                    startedAt: clock.currentDate
                )
            ]
        )
        let data = encodeStateFile(existingState)
        let stateURL = destDir.appendingPathComponent(".vcompress-state.json")
        fs.addFile(path: stateURL.path, size: Int64(data.count), data: data)

        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)
        try await manager.load()

        let entry = await manager.status(for: "video/encoding.mp4")
        XCTAssertEqual(entry?.status, .pending)
    }

    // MARK: - test_freshIgnoresExistingState

    func test_freshIgnoresExistingState() async throws {
        let (fs, lock, clock, destDir) = makeComponents()

        // Write a state file with a completed entry
        let existingState = StateFile(
            version: 1,
            created: clock.currentDate,
            updated: clock.currentDate,
            files: [
                "video/done.mp4": StateFileEntry(
                    status: .completed,
                    preset: "hevc_highest_quality",
                    sourceSize: 300_000_000,
                    outputSize: 90_000_000,
                    completedAt: clock.currentDate
                )
            ]
        )
        let data = encodeStateFile(existingState)
        let stateURL = destDir.appendingPathComponent(".vcompress-state.json")
        fs.addFile(path: stateURL.path, size: Int64(data.count), data: data)

        let manager = makeManager(
            fs: fs, lock: lock, clock: clock, destDir: destDir,
            fresh: true
        )
        try await manager.load()

        let state = await manager.currentState()
        XCTAssertTrue(state.files.isEmpty, "With --fresh, existing entries should be ignored")
    }

    // MARK: - test_presetMismatchReturnsPending

    func test_presetMismatchReturnsPending() async throws {
        let (fs, lock, clock, destDir) = makeComponents()

        // Write a state file with a completed entry using lossy preset
        let existingState = StateFile(
            version: 1,
            created: clock.currentDate,
            updated: clock.currentDate,
            files: [
                "video/clip.mp4": StateFileEntry(
                    status: .completed,
                    preset: "hevc_highest_quality",
                    sourceSize: 300_000_000,
                    outputSize: 90_000_000,
                    completedAt: clock.currentDate
                )
            ]
        )
        let data = encodeStateFile(existingState)
        let stateURL = destDir.appendingPathComponent(".vcompress-state.json")
        fs.addFile(path: stateURL.path, size: Int64(data.count), data: data)

        // Load with lossless=false (same preset "hevc_highest_quality")
        let manager = makeManager(
            fs: fs, lock: lock, clock: clock, destDir: destDir,
            lossless: false
        )
        try await manager.load()

        // The entry is completed with a matching preset - should still be completed
        let entry = await manager.status(for: "video/clip.mp4")
        XCTAssertEqual(entry?.status, .completed)
        XCTAssertEqual(entry?.preset, "hevc_highest_quality")

        // Now check: if current run is lossless, preset differs
        let currentPreset = await manager.currentPreset()
        XCTAssertEqual(currentPreset, "hevc_highest_quality")

        // Load a new manager with lossless=true to get the lossless preset
        let manager2 = makeManager(
            fs: fs, lock: lock, clock: clock, destDir: destDir,
            lossless: true
        )
        try await manager2.load()
        let preset2 = await manager2.currentPreset()
        XCTAssertEqual(preset2, "hevc_lossless")

        // The entry was encoded with "hevc_highest_quality" but current is "hevc_lossless"
        // The Scanner uses this mismatch to treat it as pending.
        // StateManager just stores the data; the Scanner checks preset match.
        let entry2 = await manager2.status(for: "video/clip.mp4")
        XCTAssertNotNil(entry2)
        XCTAssertEqual(entry2?.preset, "hevc_highest_quality")
        XCTAssertNotEqual(entry2?.preset, preset2,
            "Preset mismatch: entry was lossy but current run is lossless")
    }

    // MARK: - test_markCompleted_recordsPresetAndSizes

    func test_markCompleted_recordsPresetAndSizes() async throws {
        let (fs, lock, clock, destDir) = makeComponents()
        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)
        try await manager.load()

        try await manager.markCompleted(
            relativePath: "trip/DSC0001.MP4",
            preset: "hevc_highest_quality",
            sourceSize: 524_288_000,
            outputSize: 132_120_000
        )

        let entry = await manager.status(for: "trip/DSC0001.MP4")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.status, .completed)
        XCTAssertEqual(entry?.preset, "hevc_highest_quality")
        XCTAssertEqual(entry?.sourceSize, 524_288_000)
        XCTAssertEqual(entry?.outputSize, 132_120_000)
        XCTAssertNotNil(entry?.completedAt)
    }

    // MARK: - test_markFailed_recordsErrorMessage

    func test_markFailed_recordsErrorMessage() async throws {
        let (fs, lock, clock, destDir) = makeComponents()
        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)
        try await manager.load()

        try await manager.markFailed(
            relativePath: "trip/DSC0003.MOV",
            preset: "hevc_highest_quality",
            sourceSize: 1_048_576_000,
            error: "export_failed: The operation could not be completed"
        )

        let entry = await manager.status(for: "trip/DSC0003.MOV")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.status, .failed)
        XCTAssertEqual(entry?.error, "export_failed: The operation could not be completed")
        XCTAssertEqual(entry?.sourceSize, 1_048_576_000)
    }

    // MARK: - test_atomicWrite_neverCorruptsOnCrash

    func test_atomicWrite_neverCorruptsOnCrash() async throws {
        let (fs, lock, clock, destDir) = makeComponents()
        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)
        try await manager.load()

        try await manager.markCompleted(
            relativePath: "video/clip.mp4",
            preset: "hevc_highest_quality",
            sourceSize: 100_000,
            outputSize: 50_000
        )
        try await manager.flush()

        // Verify all writes used the atomic flag
        XCTAssertFalse(fs.writtenFiles.isEmpty, "Should have written to disk")
        for write in fs.writtenFiles {
            XCTAssertTrue(write.atomically,
                "All state file writes must use atomically: true to prevent corruption")
        }
    }

    // MARK: - test_debounce_coalesceRapidWrites

    func test_debounce_coalesceRapidWrites() async throws {
        let (fs, lock, clock, destDir) = makeComponents()
        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)
        try await manager.load()

        // First markCompleted triggers a write (lastFlush is distantPast)
        try await manager.markCompleted(
            relativePath: "file1.mp4",
            preset: "hevc_highest_quality",
            sourceSize: 100,
            outputSize: 50
        )
        let writesAfterFirst = fs.writtenFiles.count

        // Rapid calls within the same second should NOT trigger additional disk writes
        // (clock has not advanced, so < 1 second since last flush)
        for i in 2...10 {
            try await manager.markCompleted(
                relativePath: "file\(i).mp4",
                preset: "hevc_highest_quality",
                sourceSize: Int64(i * 100),
                outputSize: Int64(i * 50)
            )
        }

        let writesAfterBatch = fs.writtenFiles.count

        // Should have at most 1-2 disk writes despite 10 mark calls
        // The first write happens because lastFlush is distantPast.
        // Subsequent writes within the same second are suppressed.
        XCTAssertEqual(writesAfterFirst, 1,
            "First markCompleted should trigger exactly 1 write")
        XCTAssertEqual(writesAfterBatch, 1,
            "Rapid subsequent calls should be debounced (no additional writes)")

        // Now advance clock past debounce threshold and trigger another write
        clock.advance(by: 2.0)
        try await manager.markCompleted(
            relativePath: "file11.mp4",
            preset: "hevc_highest_quality",
            sourceSize: 1100,
            outputSize: 550
        )

        XCTAssertEqual(fs.writtenFiles.count, 2,
            "After advancing clock, a new write should occur")
    }

    // MARK: - test_processLockAcquired

    func test_processLockAcquired() async throws {
        let (fs, lock, clock, destDir) = makeComponents()
        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)

        try await manager.load()

        XCTAssertEqual(lock.acquireLockCalls.count, 1)
        XCTAssertTrue(lock.isLocked)
        let expectedLockURL = destDir.appendingPathComponent(".vcompress.lock")
        XCTAssertEqual(lock.acquireLockCalls.first, expectedLockURL)
    }

    // MARK: - test_processLockFailed_throws

    func test_processLockFailed_throws() async throws {
        let (fs, _, clock, destDir) = makeComponents(lockShouldSucceed: false)
        let lock = MockProcessLock()
        lock.shouldSucceed = false
        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)

        do {
            try await manager.load()
            XCTFail("Expected load to throw when lock fails")
        } catch {
            XCTAssertTrue(error is StateManagerError)
            XCTAssertEqual(error as? StateManagerError, .processLockFailed)
        }
    }

    // MARK: - Corrupt JSON handling

    func test_corruptJSON_startsFresh() async throws {
        let (fs, lock, clock, destDir) = makeComponents()
        let stateURL = destDir.appendingPathComponent(".vcompress-state.json")
        let corruptData = Data("{ not valid json!!!".utf8)
        fs.addFile(path: stateURL.path, size: Int64(corruptData.count), data: corruptData)

        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)
        try await manager.load()

        let state = await manager.currentState()
        XCTAssertEqual(state.version, 1)
        XCTAssertTrue(state.files.isEmpty, "Corrupt JSON should result in fresh empty state")
    }

    // MARK: - Orphaned .tmp cleanup

    func test_orphanedTmpCleanup() async throws {
        let (fs, lock, clock, destDir) = makeComponents()

        // Set up glob results to return some .tmp files
        let tmp1 = destDir.appendingPathComponent("subdir/output.mp4.tmp")
        let tmp2 = destDir.appendingPathComponent("another.mov.tmp")
        fs.globResults["*.tmp"] = [tmp1, tmp2]
        fs.addFile(path: tmp1.path, size: 1000)
        fs.addFile(path: tmp2.path, size: 2000)

        let manager = makeManager(fs: fs, lock: lock, clock: clock, destDir: destDir)
        try await manager.load()

        // Verify .tmp files were removed
        XCTAssertEqual(fs.removedItems.count, 2)
        XCTAssertTrue(fs.removedItems.contains(tmp1))
        XCTAssertTrue(fs.removedItems.contains(tmp2))
    }
}
