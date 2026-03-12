import Foundation
import ArgumentParser

/// Runs copy mode: copies all files from source to destination, preserving directory structure.
func runCopyMode(config: Config, fs: FileSystemProvider, inspector: AssetInspector, typeID: FileTypeIdentifier, clock: Clock) async throws {
    let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
    let scanConfig = ScanConfig(
        ignoreTags: config.ignoreTags,
        includeTags: config.includeTags
    )

    let scanResult = try await scanner.scanForCopy(
        source: config.sourceDir,
        dest: config.destDir,
        config: scanConfig
    )

    let reporter = Reporter(clock: clock)

    // Print plan
    let plan = reporter.formatCopyPlan(scanResult, config: config)
    print(plan)

    // Print per-file listing
    let fileList = reporter.formatCopyFileList(scanResult.allFiles, fs: fs, destDir: config.destDir)
    if !fileList.isEmpty {
        print("")
        print(fileList)
    }

    // Check disk space
    if let availableSpace = try? fs.availableSpace(atPath: config.destDir.path) {
        let totalSize = scanResult.pending.reduce(Int64(0)) { $0 + $1.fileSize }
        if availableSpace < totalSize {
            print("\n  \u{26a0} Warning: Available disk space (\(Reporter.formatSize(availableSpace))) may be insufficient.")
            print("    Total copy size: \(Reporter.formatSize(totalSize)).")
        }
    }

    // Dry run: exit now
    if config.dryRun {
        return
    }

    // No files to copy
    if scanResult.pending.isEmpty {
        print("\nNo files to copy.")
        return
    }

    // Confirmation gate
    if !config.yes {
        print("\nPress Enter to start copying, or Ctrl-C to cancel...")
        _ = readLine()
    }

    // Check for shutdown after confirmation
    if ShutdownCoordinator.shared.isShutdownRequested {
        throw ExitCode(130)
    }

    let pendingFiles = scanResult.pending
    let totalFiles = pendingFiles.count
    let totalSkipped = scanResult.skipCounts.values.reduce(0, +)
    let tracker = CopyTracker()
    let startTime = Date()

    print("\nCopying \(totalFiles) file\(totalFiles == 1 ? "" : "s") with \(config.jobs) parallel job\(config.jobs == 1 ? "" : "s")...\n")

    // Bounded TaskGroup copy loop
    await withTaskGroup(of: Void.self) { group in
        var iterator = pendingFiles.makeIterator()

        // Seed the group
        for _ in 0..<config.jobs {
            guard let entry = iterator.next() else { break }
            group.addTask {
                await copyFile(
                    entry: entry,
                    fs: fs,
                    tracker: tracker,
                    reporter: reporter,
                    totalFiles: totalFiles,
                    verbose: config.verbose
                )
            }
        }

        // Refill as tasks complete
        for await _ in group {
            if ShutdownCoordinator.shared.isShutdownRequested {
                break
            }

            guard let entry = iterator.next() else { continue }
            group.addTask {
                await copyFile(
                    entry: entry,
                    fs: fs,
                    tracker: tracker,
                    reporter: reporter,
                    totalFiles: totalFiles,
                    verbose: config.verbose
                )
            }
        }
    }

    let wallTime = Date().timeIntervalSince(startTime)

    // Gather results
    let copiedCount = await tracker.copiedCount
    let failedCount = await tracker.failedCount
    let totalSize = await tracker.totalSize
    let overwrittenCount = await tracker.overwrittenCount

    // Print summary
    let summary = reporter.formatCopySummary(
        copied: copiedCount,
        skipped: totalSkipped,
        failed: failedCount,
        totalSize: totalSize,
        overwrittenCount: overwrittenCount,
        wallTime: wallTime
    )
    print("\n\(summary)")

    // Exit code
    if ShutdownCoordinator.shared.isShutdownRequested {
        throw ExitCode(130)
    } else if failedCount > 0 {
        throw ExitCode(1)
    }
}

/// Copy a single file from source to destination.
/// Errors never escape this function.
private func copyFile(
    entry: FileEntry,
    fs: FileSystemProvider,
    tracker: CopyTracker,
    reporter: Reporter,
    totalFiles: Int,
    verbose: Bool
) async {
    do {
        // Create parent directory
        let destURL = URL(fileURLWithPath: entry.destPath)
        let parentDir = destURL.deletingLastPathComponent()
        try fs.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Check if destination already exists
        let overwritten = fs.fileExists(atPath: entry.destPath)

        // Remove existing file if present (copyItem requires dest not to exist)
        if overwritten {
            try fs.removeItem(at: destURL)
        }

        // Copy
        let sourceURL = URL(fileURLWithPath: entry.sourcePath)
        try fs.copyItem(at: sourceURL, to: destURL)

        let index = await tracker.recordSuccess(size: entry.fileSize, overwritten: overwritten)

        // Print progress
        let progress = reporter.formatCopyProgress(
            index: index,
            total: totalFiles,
            path: entry.relativePath,
            fileSize: entry.fileSize,
            overwritten: overwritten
        )
        print(progress)

    } catch {
        await tracker.recordFailure()

        if verbose {
            fputs("error: \(entry.relativePath): \(error)\n", stderr)
        }
    }
}

// MARK: - Copy Tracker

/// Thread-safe tracker for copy mode results.
actor CopyTracker {
    private(set) var copiedCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var totalSize: Int64 = 0
    private(set) var overwrittenCount: Int = 0

    func recordSuccess(size: Int64, overwritten: Bool) -> Int {
        copiedCount += 1
        totalSize += size
        if overwritten { overwrittenCount += 1 }
        return copiedCount
    }

    func recordFailure() {
        failedCount += 1
    }
}
