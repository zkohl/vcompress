import ArgumentParser
import Foundation
import AVFoundation

extension Quality: ExpressibleByArgument {}

@main
struct VCompress: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vcompress",
        abstract: "Batch-convert H.264 video files to HEVC."
    )

    @Argument(help: "Source directory containing video files.")
    var sourceDir: String

    @Argument(help: "Destination directory for encoded output.")
    var destDir: String

    @Option(name: .long, help: "Operating mode: encode (default) or copy.")
    var mode: OperatingMode = .encode

    @Option(name: .long, help: "Parallel encode jobs (default: auto).")
    var jobs: Int?

    @Option(name: .long, help: "Skip files smaller than this (e.g. 50MB, 1GB).")
    var minSize: String?

    @Option(name: .long, help: "Quality tier: standard (default), high, very-high, or max.")
    var quality: Quality = .standard

    @Option(name: .long, help: "Skip files with any of these Finder tags (comma-separated).")
    var ignoreTags: String?

    @Option(name: .long, help: "Only include files with any of these Finder tags (comma-separated).")
    var includeTags: String?

    @Flag(name: .long, help: "Skip confirmation prompt.")
    var yes: Bool = false

    @Flag(name: .long, help: "Print plan and exit without encoding.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Ignore existing state file; re-encode all files.")
    var fresh: Bool = false

    @Flag(name: .long, help: "Enable verbose output.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Output scan results as JSON (use with --dry-run).")
    var json: Bool = false

    // MARK: - Validation

    func validate() throws {
        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourceDir).standardizedFileURL
        let destURL = URL(fileURLWithPath: destDir).standardizedFileURL

        // Source must exist and be a directory
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw ValidationError("Source '\(sourceDir)' does not exist or is not a directory.")
        }

        // Source must be readable
        guard fm.isReadableFile(atPath: sourceURL.path) else {
            throw ValidationError("Source '\(sourceDir)' is not readable.")
        }

        // Dest: create if absent
        if !fm.fileExists(atPath: destURL.path) {
            do {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            } catch {
                throw ValidationError("Cannot create destination '\(destDir)': \(error.localizedDescription)")
            }
        } else {
            var destIsDir: ObjCBool = false
            guard fm.fileExists(atPath: destURL.path, isDirectory: &destIsDir), destIsDir.boolValue else {
                throw ValidationError("Destination '\(destDir)' exists but is not a directory.")
            }
        }

        // Dest must be writable
        guard fm.isWritableFile(atPath: destURL.path) else {
            throw ValidationError("Destination '\(destDir)' is not writable.")
        }

        // Source and dest must not overlap
        if pathsOverlap(sourceURL, destURL) {
            throw ValidationError("Source and destination paths overlap. They must be separate directory trees.")
        }

        // Validate --jobs
        if let j = jobs {
            try validateJobCount(j)
        }

        // Validate --min-size (just check it parses; the value is used later)
        if let ms = minSize {
            _ = try parseMinSize(ms)
        }

        // --ignore-tags and --include-tags are mutually exclusive
        if ignoreTags != nil && includeTags != nil {
            throw ValidationError("--ignore-tags and --include-tags are mutually exclusive.")
        }
    }

    // MARK: - Run

    func run() async throws {
        // Build resolved URLs
        let sourceURL = URL(fileURLWithPath: sourceDir).standardizedFileURL
        let destURL = URL(fileURLWithPath: destDir).standardizedFileURL

        // Parse min-size
        let parsedMinSize: Int64? = try minSize.map { try parseMinSize($0) }

        // Resolve job count
        let sysInfo = RealSystemInfo()
        let resolvedJobs = resolveJobCount(jobs, sysInfo: sysInfo)

        // Parse tag filters
        let parsedIgnoreTags = parseTagList(ignoreTags)
        let parsedIncludeTags = parseTagList(includeTags)

        // Build Config
        let config = Config(
            sourceDir: sourceURL,
            destDir: destURL,
            jobs: resolvedJobs,
            minSize: parsedMinSize,
            quality: quality,
            yes: yes,
            dryRun: dryRun,
            fresh: fresh,
            verbose: verbose,
            mode: mode,
            ignoreTags: parsedIgnoreTags,
            includeTags: parsedIncludeTags
        )

        // Install signal handler
        installSignalHandler()

        // Create real implementations
        let fs = RealFileSystem()
        let clock = RealClock()
        let inspector = RealAssetInspector()
        let typeID = RealFileTypeIdentifier()

        // Branch by mode
        if config.mode == .copy {
            try await runCopyMode(config: config, fs: fs, inspector: inspector, typeID: typeID, clock: clock)
            return
        }

        // Encode mode
        let preset: String
        switch quality {
        case .standard: preset = "hevc_standard"
        case .high: preset = "hevc_high"
        case .veryHigh: preset = "hevc_very_high"
        case .max: preset = "hevc_max"
        }

        let processLock = RealProcessLock()
        let exportFactory = RealExportSessionFactory()

        // Create StateManager and acquire process lock
        let stateManager = StateManager(
            destDir: destURL,
            fs: fs,
            lock: processLock,
            clock: clock,
            fresh: fresh,
            quality: quality
        )

        do {
            try await stateManager.load()
        } catch StateManagerError.processLockFailed {
            fputs("error: Another vcompress process is already running against this destination.\n", stderr)
            throw ExitCode(2)
        }

        // Run Scanner
        let scanConfig = ScanConfig(
            minSize: parsedMinSize,
            fresh: fresh,
            preset: preset,
            ignoreTags: parsedIgnoreTags,
            includeTags: parsedIncludeTags
        )

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let state = await stateManager.currentState()
        let scanResult: ScanResult
        do {
            scanResult = try await scanner.scan(
                source: sourceURL,
                dest: destURL,
                config: scanConfig,
                state: state
            )
        } catch {
            fputs("error: Scan failed: \(error.localizedDescription)\n", stderr)
            try? await stateManager.flush()
            try? processLock.releaseLock()
            throw ExitCode(2)
        }

        // Print plan
        let reporter = Reporter(clock: clock)

        if json {
            // JSON mode: output structured data and exit
            print(reporter.formatJSON(scanResult, config: config))
            try? processLock.releaseLock()
            return
        }

        let plan = reporter.formatPlan(scanResult, config: config)
        print(plan)

        // Print per-file scan results
        let fileList = reporter.formatFileList(scanResult.allFiles)
        if !fileList.isEmpty {
            print("")
            print(fileList)
        }

        // Verbose: print per-file efficiency skip details
        if verbose {
            for warning in scanResult.warnings {
                if case .efficientlyCompressed(let path, let width, let height, let frameRate, let bpp, let mbPerMin) = warning {
                    fputs("  skip: \(path) — already efficient (\(width)×\(height) \(Int(frameRate))fps, \(String(format: "%.2f", bpp)) bpp, \(Int(mbPerMin)) MB/min)\n", stderr)
                }
            }
        }

        // Check disk space and warn
        if let availableSpace = try? fs.availableSpace(atPath: destURL.path) {
            let estimate = Reporter.estimateOutput(
                inputSize: scanResult.pending.reduce(Int64(0)) { $0 + $1.fileSize },
                quality: quality
            )
            if availableSpace < estimate.high {
                print("\n  \u{26a0} Warning: Available disk space (\(Reporter.formatSize(availableSpace))) may be insufficient.")
                print("    Estimated output could be up to \(Reporter.formatSize(estimate.high)).")
            }
        }

        // Dry run: exit now
        if dryRun {
            try? processLock.releaseLock()
            return
        }

        // No files to encode
        if scanResult.pending.isEmpty {
            print("\nNo files to encode.")
            try? await stateManager.flush()
            try? processLock.releaseLock()
            return
        }

        // Confirmation gate
        if !yes {
            print("\nPress Enter to start encoding, or Ctrl-C to cancel...")
            _ = readLine()
        }

        // Check for shutdown after confirmation
        if ShutdownCoordinator.shared.isShutdownRequested {
            try? await stateManager.flush()
            try? processLock.releaseLock()
            throw ExitCode(130)
        }

        // Initialize results writer
        let resultsURL = destURL.appendingPathComponent(".vcompress-results.json")
        let resultsWriter = ResultsWriter(outputURL: resultsURL, fs: fs)
        try await resultsWriter.initialize(config: config, scanResult: scanResult)

        // Encoding loop
        let encoder = Encoder(factory: exportFactory, fs: fs, inspector: inspector)
        let metadataCopier = MetadataCopier(fs: fs, clock: RealClock())
        let pendingFiles = scanResult.pending
        let totalFiles = pendingFiles.count
        let totalSkipped = scanResult.skipCounts.values.reduce(0, +)

        // Track results using an actor for thread safety
        let tracker = EncodeTracker()

        let startTime = Date()
        var diskFullDetected = false

        print("\nEncoding \(totalFiles) file\(totalFiles == 1 ? "" : "s") with \(resolvedJobs) parallel job\(resolvedJobs == 1 ? "" : "s")...\n")

        // Bounded TaskGroup dispatch loop per spec section 7
        await withTaskGroup(of: Void.self) { group in
            var iterator = pendingFiles.makeIterator()

            // Seed the group with initial tasks
            for _ in 0..<resolvedJobs {
                guard let entry = iterator.next() else { break }
                group.addTask {
                    await processFile(
                        entry: entry,
                        encoder: encoder,
                        metadataCopier: metadataCopier,
                        stateManager: stateManager,
                        resultsWriter: resultsWriter,
                        reporter: reporter,
                        tracker: tracker,
                        preset: preset,
                        quality: quality,
                        totalFiles: totalFiles,
                        verbose: verbose
                    )
                }
            }

            // Refill as tasks complete
            for await _ in group {
                // Check shutdown
                if ShutdownCoordinator.shared.isShutdownRequested {
                    break
                }

                // Check disk full
                if await tracker.isDiskFull {
                    diskFullDetected = true
                    break
                }

                guard let entry = iterator.next() else { continue }
                group.addTask {
                    await processFile(
                        entry: entry,
                        encoder: encoder,
                        metadataCopier: metadataCopier,
                        stateManager: stateManager,
                        resultsWriter: resultsWriter,
                        reporter: reporter,
                        tracker: tracker,
                        preset: preset,
                        quality: quality,
                        totalFiles: totalFiles,
                        verbose: verbose
                    )
                }
            }
        }

        let wallTime = Date().timeIntervalSince(startTime)

        // Finalize results JSON
        try? await resultsWriter.finalize()

        // Flush state
        try? await stateManager.flush()

        // Gather results
        let encodedCount = await tracker.encodedCount
        let failedCount = await tracker.failedCount
        let totalInputSize = await tracker.totalInputSize
        let totalOutputSize = await tracker.totalOutputSize
        let trackerDiskFull = await tracker.isDiskFull
        diskFullDetected = diskFullDetected || trackerDiskFull

        // Write log file
        let logFilename = Reporter.logFilename(date: clock.now())
        let logURL = destURL.appendingPathComponent(logFilename)
        let logLines = await tracker.logLines
        let logContent = logLines.joined(separator: "\n") + "\n"
        try? fs.write(
            logContent.data(using: .utf8) ?? Data(),
            to: logURL,
            atomically: true
        )

        // Print summary
        let stateFilePath = destURL.appendingPathComponent(".vcompress-state.json").path
        let summary = reporter.formatSummary(
            encoded: encodedCount,
            skipped: totalSkipped,
            failed: failedCount,
            inputSize: totalInputSize,
            outputSize: totalOutputSize,
            wallTime: wallTime,
            stateFilePath: stateFilePath,
            logFilePath: logURL.path
        )
        print("\n\(summary)")

        // Release lock
        try? processLock.releaseLock()

        // Exit code
        if ShutdownCoordinator.shared.isShutdownRequested {
            throw ExitCode(130)
        } else if diskFullDetected {
            throw ExitCode(2)
        } else if failedCount > 0 {
            throw ExitCode(1)
        }
        // Exit 0 is implicit
    }
}

// MARK: - Process File (error-contained per spec section 10)

/// Process a single file: encode, copy metadata, update state.
/// Errors never escape this function.
private func processFile(
    entry: FileEntry,
    encoder: Encoder,
    metadataCopier: MetadataCopier,
    stateManager: StateManager,
    resultsWriter: ResultsWriter,
    reporter: Reporter,
    tracker: EncodeTracker,
    preset: String,
    quality: Quality,
    totalFiles: Int,
    verbose: Bool
) async {
    let fileStart = Date()

    // Mark in-progress
    try? await stateManager.markInProgress(
        relativePath: entry.relativePath,
        preset: preset,
        sourceSize: entry.fileSize
    )

    do {
        // Print starting line
        print(reporter.formatStarting(path: entry.relativePath, inputSize: entry.fileSize))

        // Encode
        try await encoder.encode(entry, quality: quality)

        // Copy metadata
        try metadataCopier.copy(from: entry.sourcePath, to: entry.destPath)

        // Get output size
        let outputSize: Int64
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: entry.destPath),
           let size = attrs[.size] as? Int64 ?? (attrs[.size] as? NSNumber)?.int64Value {
            outputSize = size
        } else {
            outputSize = 0
        }

        // Stamp vcompress metadata
        try metadataCopier.stampVcompress(
            atPath: entry.destPath,
            quality: quality,
            preset: preset,
            originalSize: entry.fileSize,
            compressedSize: outputSize
        )

        // Mark completed
        try await stateManager.markCompleted(
            relativePath: entry.relativePath,
            preset: preset,
            sourceSize: entry.fileSize,
            outputSize: outputSize
        )

        let elapsed = Date().timeIntervalSince(fileStart)
        let index = await tracker.recordSuccess(
            inputSize: entry.fileSize,
            outputSize: outputSize
        )

        // Record in results JSON
        try? await resultsWriter.recordEncoded(
            relativePath: entry.relativePath,
            outputPath: entry.destPath,
            outputSize: outputSize
        )

        // Print progress
        let progress = reporter.formatProgress(
            index: index,
            total: totalFiles,
            path: entry.relativePath,
            inputSize: entry.fileSize,
            outputSize: outputSize,
            elapsed: elapsed
        )
        print(progress)

        // Log line
        let logLine = reporter.formatLogLine(
            level: "INFO",
            message: "encoded \(entry.relativePath) \(quality.logLabel) \(Reporter.formatSize(entry.fileSize)) -> \(Reporter.formatSize(outputSize))"
        )
        await tracker.addLogLine(logLine)

    } catch {
        // Detect disk full
        let isDiskFull = isDiskFullError(error)
        if isDiskFull {
            await tracker.setDiskFull()
        }

        // Clean up partial output
        let destURL = URL(fileURLWithPath: entry.destPath)
        let tmpURL = URL(fileURLWithPath: entry.destPath + ".tmp")
        try? FileManager.default.removeItem(at: tmpURL)
        try? FileManager.default.removeItem(at: destURL)

        // Mark failed in state
        let errorMessage = "\(error)"
        try? await stateManager.markFailed(
            relativePath: entry.relativePath,
            preset: preset,
            sourceSize: entry.fileSize,
            error: errorMessage
        )

        await tracker.recordFailure()

        // Record in results JSON
        try? await resultsWriter.recordFailed(
            relativePath: entry.relativePath,
            error: errorMessage
        )

        // Log the failure
        let logLine = reporter.formatLogLine(
            level: "ERROR",
            message: "failed \(entry.relativePath): \(errorMessage)"
        )
        await tracker.addLogLine(logLine)

        if verbose {
            fputs("error: \(entry.relativePath): \(errorMessage)\n", stderr)
        }
    }
}

// MARK: - Disk Full Detection

private func isDiskFullError(_ error: Error) -> Bool {
    let nsError = error as NSError
    // ENOSPC
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
        return true
    }
    // NSCocoaErrorDomain code 640 (NSFileWriteOutOfSpaceError)
    if nsError.domain == NSCocoaErrorDomain && nsError.code == 640 {
        return true
    }
    // Check underlying error
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        return isDiskFullError(underlying)
    }
    return false
}

// MARK: - Encode Tracker (actor for thread-safe result accumulation)

actor EncodeTracker {
    private(set) var encodedCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var totalInputSize: Int64 = 0
    private(set) var totalOutputSize: Int64 = 0
    private(set) var isDiskFull: Bool = false
    private(set) var logLines: [String] = []

    /// Record a successful encode. Returns the 1-based index of this encode.
    func recordSuccess(inputSize: Int64, outputSize: Int64) -> Int {
        encodedCount += 1
        totalInputSize += inputSize
        totalOutputSize += outputSize
        return encodedCount
    }

    func recordFailure() {
        failedCount += 1
    }

    func setDiskFull() {
        isDiskFull = true
    }

    func addLogLine(_ line: String) {
        logLines.append(line)
    }
}

// MARK: - Real System Info

/// Production SystemInfoProvider using sysctl.
struct RealSystemInfo: SystemInfoProvider {
    func cpuBrandString() -> String {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        return String(cString: brand)
    }

    func isAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
