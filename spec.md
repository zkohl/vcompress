# vcompress — Implementation Spec

## 1. Project Structure

```
vcompress/
├── Package.swift
├── Sources/
│   └── vcompress/
│       ├── Main.swift              # Entry point, ArgumentParser command
│       ├── CLI.swift               # Argument definitions, validation
│       ├── Scanner.swift           # Directory walking, file classification
│       ├── Encoder.swift           # AVAssetExportSession / fallback encoding
│       ├── MetadataCopier.swift    # Timestamps, Finder tags, xattrs
│       ├── StateManager.swift      # JSON state file read/write/locking
│       ├── Reporter.swift          # Dry-run report, summary, log file
│       ├── Models.swift            # Shared types (FileEntry, Status, etc.)
│       ├── Signals.swift           # SIGINT handler, graceful shutdown
│       └── Protocols.swift         # All protocol definitions for DI
└── Tests/
    └── vcompressTests/
        ├── ScannerTests.swift
        ├── StateManagerTests.swift
        ├── MetadataCopierTests.swift
        ├── CLITests.swift
        ├── ReporterTests.swift
        ├── EncoderTests.swift
        ├── SignalsTests.swift
        ├── Mocks/
        │   ├── MockFileSystem.swift
        │   ├── MockAssetInspector.swift
        │   ├── MockExportSessionFactory.swift
        │   ├── MockMetadataProvider.swift
        │   └── MockProcessInfo.swift
        └── Integration/
            ├── EncodeIntegrationTests.swift
            └── Fixtures/
                ├── sample_h264.mov       # 2-second H.264 clip
                ├── sample_hevc.mp4       # 2-second HEVC clip
                └── audio_only.mov        # audio-only container
```

### Build & Distribution

- **Swift Package Manager** with `swift-argument-parser` as the sole dependency.
- Minimum deployment target: **macOS 13** (Ventura) — required for reliable `AVAssetExportSession` HEVC presets and modern Swift Concurrency runtime.
- Single static binary via `swift build -c release`. No Homebrew formula initially; distribute as a compiled binary or build-from-source.

---

## 2. Modularization & Testability

The core design principle is **protocol-based dependency injection**. Every component that touches the outside world (filesystem, AVFoundation, system info) is accessed through a protocol. Production code injects real implementations; tests inject mocks. This makes every component unit-testable in isolation without needing real video files, a real filesystem, or AVFoundation.

### 2.1 Protocol Definitions (`Protocols.swift`)

All protocols live in a single file so that any component can reference them. They define the *seams* between the system and its environment.

```swift
// MARK: - Filesystem Abstraction

/// Abstracts all filesystem operations so Scanner, StateManager, and
/// MetadataCopier can be tested without touching disk.
protocol FileSystemProvider {
    /// List directory contents recursively. Returns (relativePath, attributes) pairs.
    func enumerateFiles(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]
    ) throws -> [(url: URL, relativePath: String)]

    /// Read attributes for a file (size, creation date, type, etc.)
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]

    /// Set attributes on a file (used by MetadataCopier for timestamps).
    func setAttributes(
        _ attrs: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws

    /// Check whether a file exists at the given path.
    func fileExists(atPath path: String) -> Bool

    /// Create directories with intermediate paths.
    func createDirectory(
        at url: URL,
        withIntermediateDirectories: Bool
    ) throws

    /// Read raw data from a file.
    func contents(atPath path: String) -> Data?

    /// Atomic write of data to a file.
    func write(_ data: Data, to url: URL, atomically: Bool) throws

    /// Delete a file.
    func removeItem(at url: URL) throws

    /// Move/rename a file.
    func moveItem(at src: URL, to dst: URL) throws

    /// Read an extended attribute (xattr) from a file.
    func getExtendedAttribute(
        _ name: String,
        atPath path: String
    ) throws -> Data

    /// Set an extended attribute (xattr) on a file.
    func setExtendedAttribute(
        _ name: String,
        data: Data,
        atPath path: String
    ) throws

    /// Get available disk space on the volume containing the given path.
    func availableSpace(atPath path: String) throws -> Int64

    /// Glob for files matching a pattern in a directory.
    func glob(pattern: String, inDirectory dir: URL) throws -> [URL]
}

// MARK: - AVFoundation Abstraction

/// Abstracts video file inspection (codec detection, track enumeration).
/// This is the boundary between Scanner and AVFoundation.
protocol AssetInspector {
    /// Returns the codec types of all video tracks in the file.
    /// An empty array means "no video tracks" (audio-only container).
    func videoTrackCodecs(forFileAt url: URL) async throws -> [CMVideoCodecType]

    /// Returns whether the asset is playable (used for output validation).
    func isPlayable(at url: URL) async throws -> Bool
}

/// Abstracts the encoding operation. In production this wraps
/// AVAssetExportSession; in tests it can be a mock that returns
/// success/failure without encoding anything.
protocol ExportSessionFactory {
    func export(
        source: URL,
        destination: URL,
        fileType: AVFileType,
        preset: String
    ) async throws
}

// MARK: - System Info Abstraction

/// Abstracts system-level queries (chip detection, process info)
/// so that auto-jobs logic can be unit tested.
protocol SystemInfoProvider {
    /// Returns the CPU brand string (e.g., "Apple M2 Pro").
    func cpuBrandString() -> String

    /// Returns true if running on Apple Silicon.
    func isAppleSilicon() -> Bool
}

// MARK: - UTType Abstraction

/// Abstracts file type identification so Scanner doesn't depend on
/// UTType directly (which requires real files on disk).
protocol FileTypeIdentifier {
    /// Returns true if the file at the given URL conforms to the
    /// .movie UTType.
    func isMovie(at url: URL) -> Bool

    /// Returns the file extension (lowercased).
    func fileExtension(at url: URL) -> String
}

// MARK: - Process Lock Abstraction

/// Abstracts the advisory file lock so StateManager tests don't
/// need to coordinate real file locks.
protocol ProcessLockProvider {
    /// Attempt to acquire an exclusive lock. Returns true on success.
    func acquireLock(at url: URL) throws -> Bool

    /// Release a previously acquired lock.
    func releaseLock() throws
}

// MARK: - Clock Abstraction

/// Abstracts time so that Reporter and StateManager can be tested
/// with deterministic timestamps.
protocol Clock {
    func now() -> Date
}
```

### 2.2 Component Dependency Map

Each component declares its dependencies as protocol-typed properties, injected via its initializer. This table shows what each component needs:

| Component | Dependencies | What It Produces |
|---|---|---|
| **CLI** | `SystemInfoProvider` | Validated `Config` struct |
| **Scanner** | `FileSystemProvider`, `AssetInspector`, `FileTypeIdentifier` | `[FileEntry]` + `ScanResult` (counts by skip reason) |
| **StateManager** | `FileSystemProvider`, `ProcessLockProvider`, `Clock` | Read/write/query of `StateFile` |
| **Encoder** | `ExportSessionFactory`, `FileSystemProvider`, `AssetInspector` | Encoded files on disk |
| **MetadataCopier** | `FileSystemProvider` | Side-effects (timestamps + xattrs applied) |
| **Reporter** | `Clock` | Formatted strings (plan, summary, log lines) |
| **Signals** | (none — uses `DispatchSource` directly) | `ShutdownCoordinator` flag |
| **Main/Orchestrator** | All of the above | End-to-end pipeline |

### 2.3 Mock Implementations for Testing

Each protocol gets a corresponding mock that records calls and returns preconfigured data. Example for the filesystem:

```swift
/// A mock filesystem backed by an in-memory dictionary.
/// Tests build a virtual file tree, then run Scanner/StateManager against it.
final class MockFileSystem: FileSystemProvider {
    /// In-memory file store: path → (attributes, data)
    var files: [String: (attributes: [FileAttributeKey: Any], data: Data?)] = [:]
    var directories: Set<String> = []

    // Track calls for assertion
    var writtenFiles: [(url: URL, data: Data)] = []
    var removedItems: [URL] = []
    var movedItems: [(from: URL, to: URL)] = []

    var availableDiskSpace: Int64 = 500_000_000_000  // 500 GB default

    func fileExists(atPath path: String) -> Bool {
        files[path] != nil || directories.contains(path)
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        guard let entry = files[path] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return entry.attributes
    }

    // ... remaining implementations ...
}
```

```swift
/// Mock for AssetInspector. Returns preconfigured codec results
/// per file path, so Scanner classification can be fully tested.
final class MockAssetInspector: AssetInspector {
    /// Map of file path → codec types for video tracks.
    /// Empty array = audio-only. nil = file not found.
    var codecs: [String: [CMVideoCodecType]] = [:]
    var playability: [String: Bool] = [:]

    func videoTrackCodecs(forFileAt url: URL) async throws -> [CMVideoCodecType] {
        guard let result = codecs[url.path] else {
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }
        return result
    }

    func isPlayable(at url: URL) async throws -> Bool {
        playability[url.path] ?? false
    }
}
```

### 2.4 What Gets Mocked vs. What Gets Tested For Real

| Boundary | Unit Tests (Mocked) | Integration Tests (Real) |
|---|---|---|
| Filesystem (read/write/enumerate) | `MockFileSystem` — in-memory dictionary | Real temp directories with real files |
| AVFoundation (codec detection) | `MockAssetInspector` — returns canned codecs | Real `AVURLAsset` against fixture video files |
| AVFoundation (encoding) | `MockExportSessionFactory` — instant success/failure | Real `AVAssetExportSession` against 2-second clip |
| System info (chip/CPU) | `MockProcessInfo` — returns any chip string | Not needed (logic is pure string matching) |
| Extended attributes (xattrs) | `MockFileSystem` — in-memory xattr store | Real xattrs on temp files in a temp directory |
| Time/Clock | `MockClock` — returns fixed dates | Not needed (deterministic) |

---

## 3. TDD Testing Strategy

### 3.1 Test-First Workflow

Every component is built test-first. The workflow for each component is:

1. **Write the protocol** that defines the component's public interface.
2. **Write failing tests** against that protocol using mocks for dependencies.
3. **Implement the component** until all tests pass.
4. **Refactor** while keeping tests green.

### 3.2 Unit Tests by Component

#### CLI Tests (`CLITests.swift`)

Test the pure validation and parsing logic. No filesystem needed — just struct construction and validation calls.

```swift
// Tests for --min-size parsing
func test_minSize_parsesMB() {
    // "50MB" → 52_428_800 bytes
}
func test_minSize_parsesGB_caseInsensitive() {
    // "2gb" → 2_147_483_648 bytes
}
func test_minSize_rejectsInvalid() {
    // "50" → validation error
    // "50TB" → validation error
    // "abc" → validation error
}

// Tests for overlap detection
func test_overlap_sourceIsParentOfDest_rejects() { }
func test_overlap_destIsParentOfSource_rejects() { }
func test_overlap_symlinkResolvedBeforeCheck() { }
func test_overlap_unrelatedPaths_passes() { }

// Tests for --jobs validation
func test_jobs_0_rejects() { }
func test_jobs_9_rejects() { }
func test_jobs_1through8_passes() { }

// Tests for auto-jobs detection
func test_autoJobs_m2Pro_returns3() {
    let sysInfo = MockProcessInfo(cpuBrand: "Apple M2 Pro", isARM: true)
    XCTAssertEqual(resolveJobCount(nil, sysInfo: sysInfo), 3)
}
func test_autoJobs_unknownAppleSilicon_returns2() {
    let sysInfo = MockProcessInfo(cpuBrand: "Apple M99", isARM: true)
    XCTAssertEqual(resolveJobCount(nil, sysInfo: sysInfo), 2)
}
func test_autoJobs_intel_returns1() {
    let sysInfo = MockProcessInfo(cpuBrand: "Intel(R) Core(TM) i9", isARM: false)
    XCTAssertEqual(resolveJobCount(nil, sysInfo: sysInfo), 1)
}
```

#### Scanner Tests (`ScannerTests.swift`)

These are the most important unit tests. They verify the entire classification table from §3 of the spec using mocks. No real video files.

```swift
// Build a virtual file tree and verify classification
func test_skipsNonVideoFiles() {
    let fs = MockFileSystem()
    fs.addFile("photos/IMG_001.jpg", size: 5_000_000)
    fs.addFile("docs/notes.txt", size: 1_000)

    let typeID = MockFileTypeIdentifier()
    typeID.movieFiles = []  // neither is a movie

    let scanner = Scanner(fs: fs, inspector: MockAssetInspector(), typeID: typeID)
    let result = try await scanner.scan(source: sourceURL, dest: destURL, config: config)

    XCTAssertEqual(result.pending.count, 0)
    XCTAssertEqual(result.skipCounts[.notVideo], 2)
}

func test_skipsAudioOnlyMovFiles() {
    let fs = MockFileSystem()
    fs.addFile("podcast.mov", size: 50_000_000)

    let typeID = MockFileTypeIdentifier()
    typeID.movieFiles = ["podcast.mov"]

    let inspector = MockAssetInspector()
    inspector.codecs["podcast.mov"] = []  // no video tracks

    let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
    let result = try await scanner.scan(...)

    XCTAssertEqual(result.skipCounts[.noVideoTrack], 1)
}

func test_skipsAlreadyHEVC() {
    // inspector returns [kCMVideoCodecType_HEVC] → skip
}

func test_skipsBelowMinSize() {
    // file size < config.minSize → skip
}

func test_skipsAlreadyDoneInState() {
    // state says "completed" with matching preset → skip
}

func test_pendingWhenPresetMismatch() {
    // state says "completed" but with different preset → pending
}

func test_pendingForNormalH264File() {
    // H.264 file, no state entry → pending
}

func test_containerMapping_mov() {
    // .mov source → FileEntry.sourceContainer == "mov"
}

func test_containerMapping_m4v() {
    // .m4v source → FileEntry.sourceContainer == "m4v"
}

func test_skipsUnsupportedContainers() {
    // .avi, .mkv, .mts → skip with unsupportedContainer
}

func test_skipsHiddenFiles() {
    // .hidden_video.mp4 → skipped entirely (not counted)
}

func test_skipsSymlinks() {
    // symlink → skipped, logged in verbose
}
```

#### StateManager Tests (`StateManagerTests.swift`)

Tests operate on an in-memory filesystem. They verify serialization, recovery logic, and concurrency semantics.

```swift
func test_loadEmpty_createsDefaultState() {
    // no state file on disk → returns empty state with version 1
}

func test_roundTrip_writeAndRead() {
    // write state, read it back, verify fields match
}

func test_inProgressResetToPendingOnLoad() {
    // state has in_progress entries → after load, they are pending
}

func test_freshIgnoresExistingState() {
    // with --fresh, completed entries are ignored
}

func test_presetMismatchReturnsPending() {
    // completed entry with "hevc_highest_quality" but
    // current run is lossless → treated as pending
}

func test_markCompleted_recordsPresetAndSizes() {
    // after markCompleted, entry has correct preset, sizes, timestamps
}

func test_markFailed_recordsErrorMessage() { }

func test_atomicWrite_neverCorruptsOnCrash() {
    // simulate crash mid-write: old state file still valid
    // (verified by checking MockFileSystem.writtenFiles uses atomic flag)
}

func test_debounce_coalesceRapidWrites() {
    // call markCompleted 10 times rapidly → only 1-2 disk writes
}
```

#### MetadataCopier Tests (`MetadataCopierTests.swift`)

```swift
func test_copiesCreationDate() {
    let fs = MockFileSystem()
    let srcDate = Date(timeIntervalSince1970: 1_700_000_000)
    fs.addFile("src.mov", attributes: [.creationDate: srcDate])
    fs.addFile("dst.mov", attributes: [:])

    let copier = MetadataCopier(fs: fs)
    try copier.copy(from: "src.mov", to: "dst.mov")

    let dstAttrs = try fs.attributesOfItem(atPath: "dst.mov")
    XCTAssertEqual(dstAttrs[.creationDate] as? Date, srcDate)
}

func test_copiesModificationDate() { }

func test_missingCreationDate_logsWarning_doesNotThrow() {
    // source has no creationDate → warning logged, no crash
}

func test_copiesFinderTags_xattr() {
    // set xattr on mock source, verify it appears on mock dest
}

func test_missingFinderTags_skipsGracefully() { }
```

#### Reporter Tests (`ReporterTests.swift`)

Reporter is pure logic — it takes data and produces strings. No mocks needed except a fixed clock for timestamps.

```swift
func test_planSummary_formatsAllCounts() {
    let result = ScanResult(
        pending: [/* 142 entries */],
        skipCounts: [.alreadyHEVC: 38, .alreadyDone: 12, .tooSmall: 6, ...]
    )
    let plan = Reporter.formatPlan(result, config: config, clock: fixedClock)

    XCTAssert(plan.contains("Files to encode:     142"))
    XCTAssert(plan.contains("Already HEVC:         38"))
}

func test_planSummary_showsDiskSpaceWarning() {
    // available < estimated high → warning block appears
}

func test_progressLine_formatsCorrectly() {
    let line = Reporter.formatProgress(
        index: 42, total: 142, path: "Trip/clip.mp4",
        inputSize: 500_000_000, outputSize: 125_000_000,
        elapsed: 38
    )
    XCTAssertEqual(line, "[  42/142]  encoded  Trip/clip.mp4  500 MB → 125 MB (75%)  38s")
}

func test_completionSummary_computesSavingsPercentage() { }

func test_logLine_usesISO8601WithColons() { }
func test_logFilename_usesCompactTimestampWithoutColons() { }

func test_estimatedOutput_lossy_rangeCorrect() {
    let est = Reporter.estimateOutput(inputSize: 312_500_000_000, lossless: false)
    XCTAssertEqual(est.low, 62_500_000_000)    // 20%
    XCTAssertEqual(est.high, 109_375_000_000)  // 35%
}

func test_estimatedOutput_lossless_rangeCorrect() {
    let est = Reporter.estimateOutput(inputSize: 312_500_000_000, lossless: true)
    XCTAssertEqual(est.low, 187_500_000_000)   // 60%
    XCTAssertEqual(est.high, 250_000_000_000)  // 80%
}
```

#### Encoder Tests (`EncoderTests.swift`)

Unit tests mock the export session. They test the orchestration logic around encoding — not the actual video transcoding.

```swift
func test_successfulEncode_movesToFinalPath() {
    let factory = MockExportSessionFactory(result: .success)
    let fs = MockFileSystem()
    let encoder = Encoder(factory: factory, fs: fs, inspector: MockAssetInspector())

    try await encoder.encode(entry, lossless: false)

    // Verify: tmp file was created, then moved to final path
    XCTAssertEqual(fs.movedItems.count, 1)
    XCTAssert(fs.movedItems[0].from.path.hasSuffix(".tmp"))
    XCTAssertEqual(fs.movedItems[0].to.path, entry.destPath)
}

func test_failedExport_deletesPartialOutput_throws() {
    let factory = MockExportSessionFactory(result: .failure(.exportFailed))
    // ...
    XCTAssertEqual(fs.removedItems.count, 1)  // tmp cleaned up
}

func test_outputValidation_zeroBytesFile_throws() {
    // factory succeeds but output file is 0 bytes → validation error
}

func test_outputValidation_notPlayable_deletesOutput() {
    // factory succeeds, file exists, but isPlayable returns false
}

func test_movContainer_usesMovFileType() {
    // .mov source → export called with AVFileType.mov
}

func test_mp4Container_usesMp4FileType() { }
func test_m4vContainer_usesMp4FileType_preservesExtension() { }
```

#### Signals Tests (`SignalsTests.swift`)

```swift
func test_shutdownCoordinator_initiallyFalse() {
    let coord = ShutdownCoordinator()
    XCTAssertFalse(coord.isShutdownRequested)
}

func test_shutdownCoordinator_requestShutdown_setsFlag() {
    let coord = ShutdownCoordinator()
    coord.requestShutdown()
    XCTAssertTrue(coord.isShutdownRequested)
}

func test_shutdownCoordinator_threadSafe() {
    // dispatch requestShutdown from 100 concurrent tasks
    // verify no crashes, flag is true at the end
}
```

### 3.3 Integration Tests

Integration tests use **real AVFoundation** and **real filesystem** operations. They are slower and require macOS hardware, but verify that the protocol implementations actually work.

These require **test fixture video files** checked into the repo under `Tests/vcompressTests/Integration/Fixtures/`. Generate them once using `ffmpeg`:

```bash
# 2-second H.264 test clip (small, ~200KB)
ffmpeg -f lavfi -i testsrc2=duration=2:size=320x240:rate=30 \
       -f lavfi -i sine=frequency=440:duration=2 \
       -c:v libx264 -preset ultrafast -c:a aac \
       sample_h264.mov

# 2-second HEVC test clip
ffmpeg -f lavfi -i testsrc2=duration=2:size=320x240:rate=30 \
       -c:v libx265 -preset ultrafast \
       sample_hevc.mp4

# Audio-only .mov container
ffmpeg -f lavfi -i sine=frequency=440:duration=2 \
       -c:a aac audio_only.mov
```

#### Encode Integration Test

```swift
func test_realEncode_h264ToHEVC() async throws {
    let source = fixtureURL("sample_h264.mov")
    let dest = tempDir.appendingPathComponent("output.mov")

    let encoder = Encoder(
        factory: RealExportSessionFactory(),
        fs: RealFileSystem(),
        inspector: RealAssetInspector()
    )

    let entry = FileEntry(
        sourcePath: source.path,
        relativePath: "sample_h264.mov",
        destPath: dest.path,
        fileSize: try source.fileSize(),
        sourceContainer: "mov"
    )

    try await encoder.encode(entry, lossless: false)

    // Verify output exists and is HEVC
    let inspector = RealAssetInspector()
    let codecs = try await inspector.videoTrackCodecs(forFileAt: dest)
    XCTAssertEqual(codecs.first, kCMVideoCodecType_HEVC)

    // Verify output is playable
    XCTAssertTrue(try await inspector.isPlayable(at: dest))

    // Verify output has audio track
    // (use AVURLAsset directly for this check)
}
```

#### Scanner Integration Test (Real Codec Detection)

```swift
func test_realCodecDetection_h264() async throws {
    let inspector = RealAssetInspector()
    let codecs = try await inspector.videoTrackCodecs(
        forFileAt: fixtureURL("sample_h264.mov")
    )
    XCTAssertEqual(codecs, [kCMVideoCodecType_H264])
}

func test_realCodecDetection_hevc() async throws {
    let inspector = RealAssetInspector()
    let codecs = try await inspector.videoTrackCodecs(
        forFileAt: fixtureURL("sample_hevc.mp4")
    )
    XCTAssertEqual(codecs, [kCMVideoCodecType_HEVC])
}

func test_realCodecDetection_audioOnly_returnsEmpty() async throws {
    let inspector = RealAssetInspector()
    let codecs = try await inspector.videoTrackCodecs(
        forFileAt: fixtureURL("audio_only.mov")
    )
    XCTAssertTrue(codecs.isEmpty)
}
```

#### Metadata Integration Test (Real xattrs)

```swift
func test_realXattrRoundTrip() throws {
    // Create a temp file, set a Finder tag xattr, copy it, verify it survives
    let copier = MetadataCopier(fs: RealFileSystem())
    // ...
}
```

#### SIGINT Integration Test

```swift
func test_sigint_stopsDispatchingAndSavesState() async throws {
    // 1. Start an encode run with 10 files (use tiny fixtures so it's fast)
    // 2. After 2 files complete, send SIGINT to the process
    // 3. Verify: state file has 2 completed, remaining are pending
    // 4. Verify: no .tmp files left behind
    // 5. Verify: exit code is 130
}
```

---

## 4. CLI Parsing (`CLI.swift`)

Use `swift-argument-parser`. Define a top-level `ParsableCommand`:

```swift
struct VCompress: AsyncParsableCommand {
    @Argument var sourceDir: String
    @Argument var destDir: String

    @Option(name: .long, help: "Parallel encode jobs (default: auto)")
    var jobs: Int?                 // nil = auto-detect

    @Option(name: .long, help: "Skip files smaller than this (e.g. 50MB, 1GB)")
    var minSize: String?           // parsed into bytes

    @Flag var lossless: Bool = false  // HEVCHighestQualityLossless vs HEVCHighestQuality
    @Flag var yes: Bool = false       // skip confirmation prompt
    @Flag var dryRun: Bool = false
    @Flag var fresh: Bool = false
    @Flag var verbose: Bool = false
}
```

### Validation (in `validate()`)

1. Both paths exist and are directories.
2. Source is readable; dest is writable (create if absent).
3. Source and dest do not overlap — resolve both to real paths (`URL.resolvingSymlinksInPath()`) and confirm neither is a prefix of the other.
4. `--jobs` when specified: 1–8 (cap at reasonable limit; VideoToolbox has finite HW encoder sessions). When omitted: auto-detect (see §7 Parallelism).
5. `--min-size` parses via regex: `^(\d+)(KB|MB|GB)$` (case-insensitive). Reject unparseable values.
6. `--lossless` requires no validation — it selects the export preset.

### Testability Notes

The overlap-detection and min-size parsing logic should be extracted as **free functions or static methods** that take strings/URLs and return results. This way CLI tests don't need to construct a full `ParsableCommand` — they test the pure logic directly:

```swift
// Extracted pure functions for testability
static func parseMinSize(_ raw: String) throws -> Int64
static func pathsOverlap(_ a: URL, _ b: URL) -> Bool
func resolveJobCount(_ explicit: Int?, sysInfo: SystemInfoProvider) -> Int
```

---

## 5. Directory Scanning (`Scanner.swift`)

### Constructor

```swift
struct Scanner {
    let fs: FileSystemProvider
    let inspector: AssetInspector
    let typeID: FileTypeIdentifier

    func scan(
        source: URL,
        dest: URL,
        config: ScanConfig,
        state: StateFile?
    ) async throws -> ScanResult
}
```

### Walk

Use `fs.enumerateFiles(at:includingPropertiesForKeys:)`. Skip hidden files (`.` prefix) and `.DS_Store`.

### Classification

For each file, determine action:

| Condition | Result |
|---|---|
| Not a video (UTType does not conform to `.movie`) | `skip(notVideo)` |
| No video track (e.g., audio-only `.mov`) | `skip(noVideoTrack)` |
| Below `--min-size` | `skip(tooSmall)` |
| Already HEVC (probe first video track) | `skip(alreadyHEVC)` |
| Output already exists in dest at mirror path | `skip(alreadyDone)` |
| State file says `completed` (and `--fresh` not set), **and** preset matches current run | `skip(alreadyDone)` |
| State file says `completed` but preset differs from current run (and `--fresh` not set) | `pending` (re-encode with new preset) |
| Otherwise | `pending` |

### Video Track Check

Use `inspector.videoTrackCodecs(forFileAt:)`. If the returned array is empty, the file has no video track — skip it as `noVideoTrack`. This catches audio-only `.mov` files (screen recordings of podcasts, QuickTime voice memos, etc.) that conform to `UTType.movie` but have nothing to re-encode.

### HEVC Detection

If any codec in the returned array equals `kCMVideoCodecType_HEVC`, the file is already HEVC.

### Output: `ScanResult`

```swift
struct ScanResult {
    let pending: [FileEntry]
    let skipCounts: [SkipReason: Int]
    let warnings: [ScanWarning]
    let totalScanned: Int
}

enum SkipReason {
    case notVideo, noVideoTrack, tooSmall, alreadyHEVC
    case alreadyDone, unsupportedContainer
}
```

```swift
struct FileEntry: Codable {
    let sourcePath: String       // absolute
    let relativePath: String     // relative to sourceDir, used to mirror
    let destPath: String         // absolute path in destDir
    let fileSize: Int64          // bytes
    let sourceContainer: String  // "mov", "mp4", or "m4v"
}
```

---

## 6. State Management (`StateManager.swift`)

### Constructor

```swift
actor StateManager {
    let fs: FileSystemProvider
    let lock: ProcessLockProvider
    let clock: Clock
    let stateURL: URL

    init(destDir: URL, fs: FileSystemProvider,
         lock: ProcessLockProvider, clock: Clock)
}
```

### State File

Located at `<destDir>/.vcompress-state.json`. Structure:

```json
{
  "version": 1,
  "created": "2025-06-01T10:00:00Z",
  "updated": "2025-06-01T12:34:56Z",
  "files": {
    "2024-Japan/DSC00001.MP4": {
      "status": "completed",
      "preset": "hevc_highest_quality",
      "sourceSize": 524288000,
      "outputSize": 132120000,
      "startedAt": "...",
      "completedAt": "..."
    },
    "2024-Japan/DSC00003.MOV": {
      "status": "failed",
      "preset": "hevc_highest_quality",
      "sourceSize": 1048576000,
      "startedAt": "...",
      "error": "export_failed: The operation could not be completed"
    }
  }
}
```

Keys in `files` are **relative paths** (to sourceDir), ensuring portability if directories are moved.

Each entry records the **preset** used (`"hevc_highest_quality"` or `"hevc_lossless"`). On resume, if the current `--lossless` flag selects a different preset than what a `completed` entry was encoded with, that file is treated as `pending` and re-encoded. This prevents half a library being lossy and half lossless after a flag change without `--fresh`. Failed entries include an **error** string capturing the failure reason, making the state file self-contained for post-run debugging without cross-referencing the log.

### Status Enum

```swift
enum FileStatus: String, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case skipped
}
```

### Concurrency Safety

`StateManager` is an `actor`. All reads/writes are serialized. Writes are debounced — flush to disk at most once per second and on shutdown. Use atomic write (`fs.write(_:to:atomically: true)`) to prevent corruption on crash.

### Multi-Process Safety

On startup, acquire an advisory lock on `<destDir>/.vcompress.lock` using `lock.acquireLock(at:)`. If the lock cannot be acquired, print an error ("another vcompress process is already running against this destination") and exit with code 2. Release the lock on shutdown.

### `--fresh` Behavior

Ignore the existing state file entirely. Re-scan all files. Keep the existing state file intact during the scan; overwrite it atomically only once the new scan results are ready.

### Startup Recovery

On load, perform two cleanup steps:

1. **State-tracked recovery:** Any file marked `in_progress` is treated as interrupted — reset to `pending` and delete its partial output file if one exists.

2. **Orphaned `.tmp` cleanup:** Glob for `*.tmp` files anywhere in the dest tree. Delete them and log each deletion in verbose mode.

---

## 7. Encoding (`Encoder.swift`)

### Constructor

```swift
struct Encoder {
    let factory: ExportSessionFactory
    let fs: FileSystemProvider
    let inspector: AssetInspector

    func encode(_ entry: FileEntry, lossless: Bool) async throws
}
```

### Primary Path: `AVAssetExportSession`

The real `ExportSessionFactory` wraps `AVAssetExportSession`:

```swift
struct RealExportSessionFactory: ExportSessionFactory {
    func export(
        source: URL, destination: URL,
        fileType: AVFileType, preset: String
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: preset
        ) else {
            throw EncodingError.exportSessionCreation
        }
        session.outputURL = destination
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = false
        await session.export()
        guard session.status == .completed else {
            throw EncodingError.exportFailed(session.error)
        }
    }
}
```

The `Encoder.encode()` method handles the orchestration around this:

1. Compute temp URL (dest path + `.tmp` suffix).
2. Create parent directories via `fs.createDirectory`.
3. Call `factory.export(source:destination:fileType:preset:)` to the temp URL.
4. Move temp to final path via `fs.moveItem`.
5. Validate output: size > 0, `inspector.isPlayable` returns true.
6. On any failure: delete temp/output, rethrow.

### Fallback Path: None (Fail Explicitly)

If `AVAssetExportSession` cannot be created for a file, the scanner flags it during the scan phase. There is no automatic `avconvert` retry.

### Parallelism

**Auto-detect default for `--jobs`:** When the user doesn't specify `--jobs`, detect the Apple Silicon tier via `SystemInfoProvider` and pick a default:

| Chip | Default jobs |
|---|---|
| M1 / M2 / M3 / M4 (base) | 2 |
| M1/M2/M3/M4 Pro | 3 |
| M1/M2/M3/M4 Max / Ultra | 4 |
| Unrecognized Apple Silicon | 2 |
| Intel | 1 |

Detection: use `sysInfo.isAppleSilicon()` and `sysInfo.cpuBrandString()`. Match the chip suffix (Pro, Max, Ultra) rather than a fixed list of chip names.

Use a Swift `TaskGroup` with max concurrency limited to the resolved job count. Use a **bounded dispatch loop**:

```swift
await withTaskGroup(of: Void.self) { group in
    var iterator = pendingFiles.makeIterator()

    for _ in 0..<jobs {
        guard let entry = iterator.next() else { break }
        group.addTask { await processFile(entry) }
    }

    for await _ in group {
        if shutdownRequested { break }
        guard let entry = iterator.next() else { continue }
        group.addTask { await processFile(entry) }
    }
}
```

### Progress Reporting

In **non-verbose mode**, print one line per file completion:

```
[  42/142]  encoded  Trip/clip.mp4  500 MB → 125 MB (75%)  38s
```

---

## 8. Metadata Copying (`MetadataCopier.swift`)

### Constructor

```swift
struct MetadataCopier {
    let fs: FileSystemProvider

    func copy(from source: String, to dest: String) throws
}
```

Run **after** each successful encode, on the output file.

### File Creation Timestamp (Birthtime)

Read source creation date and modification date via `fs.attributesOfItem`. Apply to output via `fs.setAttributes`. If the creation date attribute is missing, log a warning and skip rather than crashing.

### Finder Tags

Read and write via `fs.getExtendedAttribute` / `fs.setExtendedAttribute` for `"com.apple.metadata:_kMDItemUserTags"`. Copy the raw bytes verbatim.

### Embedded Metadata (GPS, Camera Model, etc.)

`AVAssetExportSession` carries over QuickTime/EXIF metadata from source to output automatically — no action needed.

---

## 9. Reporting & Confirmation (`Reporter.swift`)

### Constructor

```swift
struct Reporter {
    let clock: Clock

    // All methods are pure functions: data in, strings out.
    func formatPlan(_ result: ScanResult, config: Config) -> String
    func formatProgress(...) -> String
    func formatSummary(...) -> String
    func formatLogLine(...) -> String
    static func estimateOutput(inputSize: Int64, lossless: Bool)
        -> (low: Int64, high: Int64)
    static func logFilename(date: Date) -> String
}
```

Reporter is deliberately a pure-logic component with no dependencies on the filesystem. It takes data and returns formatted strings. Writing the log file to disk is the caller's (orchestrator's) responsibility using `FileSystemProvider`.

### Plan Summary (always shown, both normal and dry-run)

```
vcompress plan
  Source: /Volumes/Media/Raw
  Dest:   /Volumes/Media/Compressed
  Preset: HEVC Highest Quality (lossy)
  Jobs:   3 (auto, M2 Pro)

  Files to encode:     142   (312.5 GB)
  Already HEVC:         38
  Already in dest:      12
  Below min-size:        6
  No video track:        2
  Not video:            21
  ─────────────────────────────
  Total scanned:       221

  Estimated output: ~78–125 GB (60–75% reduction typical for H.264→HEVC)
```

### Output Size Estimation

| Preset | Low estimate | High estimate |
|---|---|---|
| Lossy (`HEVCHighestQuality`) | 20% of input | 35% of input |
| Lossless (`HEVCHighestQualityLossless`) | 60% of input | 80% of input |

### Disk Space Pre-Check

Compare available disk space on the destination volume against the estimated output size. Warning only — does not block execution.

### Confirmation Gate

In **normal mode**: prompt for Enter. In **`--dry-run` mode**: print the plan and exit (code 0). **`--yes` flag** skips the prompt.

### Log File

Written to `<destDir>/.vcompress-log-<compact-timestamp>.txt`. Filename uses `YYYYMMDDTHHmmssZ` format. Content timestamps use standard ISO 8601.

### Completion Summary (stdout)

```
vcompress complete
  Encoded:    130 files
  Skipped:     89 files
  Failed:       2 files

  Input size:   312.5 GB
  Output size:   82.1 GB
  Saved:        230.4 GB (73.7%)
  Wall time:    2h 14m 37s

  State: /Volumes/Media/Compressed/.vcompress-state.json
  Log:   /Volumes/Media/Compressed/.vcompress-log-20250601T120000Z.txt
```

---

## 10. Error Handling

### Per-File Errors

Wrap each file's encode in a do/catch **inside `processFile`** (the function called per-task in the TaskGroup). On failure:

1. Log the error with file path and message.
2. Delete partial output (the `.tmp` file and any renamed output that failed validation) if it exists.
3. Mark `failed` in state with error message.
4. Continue to next file.

Errors must never escape the per-file task.

### Specific Error Cases

| Error | Detection | Action |
|---|---|---|
| Disk full | `NSCocoaErrorDomain` code 640 / `ENOSPC` | Log, halt encoding, print summary |
| Corrupt source | `AVAssetExportSession.status == .failed` | Log, mark failed, continue |
| Corrupt output | Output validation fails (zero bytes or not playable) | Delete output, log, mark failed, continue |
| Permission denied | `EACCES` on read/write | Log, mark failed, continue |
| Source disappeared | File not found at encode time | Log, mark failed, continue |

### Disk Full — Special Case

On disk full, stop dispatching new jobs. Let in-progress jobs finish. Print summary. Exit with code 2.

### Graceful Shutdown (SIGINT / Ctrl-C)

Use `DispatchSource` instead of the C `signal()` function:

```swift
signal(SIGINT, SIG_IGN)

let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
source.setEventHandler {
    ShutdownCoordinator.shared.requestShutdown()
}
source.resume()
```

`ShutdownCoordinator` is a `Sendable` class with an `AtomicBool` flag. On shutdown:

1. Stop dispatching new encodes.
2. Wait for in-progress encodes to finish.
3. Update state file.
4. Print summary of work done so far.
5. Exit with code 130.

---

## 11. Concurrency Architecture

```
Main Thread
  └─ VCompress.run()
       ├─ acquireProcessLock()
       ├─ cleanOrphanedTempFiles()
       ├─ Scanner.scan()
       ├─ StateManager.load()
       ├─ Reporter.printPlan()
       ├─ waitForConfirmation()
       ├─ TaskGroup (bounded concurrency = --jobs)
       │    ├─ Task: processFile(A)
       │    ├─ Task: processFile(B)
       │    └─ ...
       │         ├─ Encoder.encode()
       │         ├─ MetadataCopier.copy()
       │         └─ StateManager.markCompleted()
       └─ Reporter.printSummary()
```

---

## 12. Edge Cases & Decisions

### Container Mapping

Map by source file **extension**, not by probing the container format:
- `.mov` → output as `.mov` (`AVFileType.mov`)
- `.mp4` → output as `.mp4` (`AVFileType.mp4`)
- `.m4v` → output as `.m4v` (use `AVFileType.mp4` internally; preserve `.m4v` extension on output filename)
- Other extensions (`.avi`, `.mkv`, `.mts`): skip with reason `unsupportedContainer`.

### Files with Identical Names

Mirror structure preserves full relative path. No special handling.

### Symlinks

Disable following symlinks. Skip symlinks to avoid cycles and double-processing. Log in verbose mode.

### Empty Directories

Do not create empty directories in dest. Only create parent directories when writing an output file.

### Very Large Files

No special handling. `AVAssetExportSession` streams the encode.

### Re-wrapped HEVC

Cameras shooting HEVC are correctly detected and skipped during scan.

---

## 13. Exit Codes

| Code | Meaning |
|---|---|
| 0 | Success (all files encoded or skipped) |
| 1 | Partial failure (some files failed, rest succeeded) |
| 2 | Fatal error (invalid args, source/dest overlap, disk full, process lock conflict) |
| 130 | Interrupted by SIGINT |

---

## 14. Agent Work Breakdown

This section defines how to split implementation across multiple AI coding agents, each with a focused context window. The fundamental constraint is that each agent has a limited context window, so each task must be self-contained: the agent receives the protocol definitions, relevant spec sections, and test expectations — and delivers a working, tested component.

### 14.1 Principles

1. **Protocol-first.** The protocol definitions in `Protocols.swift` and the shared types in `Models.swift` are the contract between agents. These are written first by a single agent, and every subsequent agent receives them as immutable context.
2. **Tests travel with components.** Each agent writes both the implementation and its unit tests (TDD). The tests ARE the acceptance criteria.
3. **No cross-agent dependencies at implementation time.** Agent B does not need Agent A's implementation — only the shared protocols and types. Agents work against mocks, not each other's code.
4. **One integration agent at the end.** A final agent wires everything together and writes the orchestrator + integration tests.

### 14.2 Task Definitions

#### Task 0: Foundation (Models, Protocols, Mocks)

**Context required:** Full spec (this document).

**Delivers:**
- `Package.swift` — project setup with swift-argument-parser dependency
- `Models.swift` — all shared types (`FileEntry`, `ScanResult`, `SkipReason`, `FileStatus`, `Config`, `ScanConfig`, `StateFile`, `EncodingError`, `ScanWarning`)
- `Protocols.swift` — all protocol definitions (as in §2.1)
- `Mocks/MockFileSystem.swift` — complete mock filesystem (in-memory dictionary)
- `Mocks/MockAssetInspector.swift` — mock video inspector
- `Mocks/MockExportSessionFactory.swift` — mock encoder
- `Mocks/MockMetadataProvider.swift` — mock xattr provider
- `Mocks/MockProcessInfo.swift` — mock system info
- `Mocks/MockClock.swift` — fixed-time clock

**Acceptance criteria:** `swift build` succeeds. All mocks compile against their protocols.

**Estimated complexity:** Medium. ~400-600 lines. This is the keystone — getting the types and protocols right determines everything else.

---

#### Task 1: CLI Parsing & Validation

**Context required:** `Models.swift`, `Protocols.swift`, spec §4 (CLI Parsing).

**Delivers:**
- `CLI.swift` — `VCompress` command definition, `validate()`, extracted pure functions
- `CLITests.swift` — all tests from §3.2 CLI Tests section

**Acceptance criteria:** All CLI tests pass. `swift build` succeeds.

**Key details for agent:**
- Extract `parseMinSize`, `pathsOverlap`, `resolveJobCount` as testable free functions.
- `resolveJobCount` takes `SystemInfoProvider` for chip detection.
- Validation errors should use `ValidationError` from swift-argument-parser.

---

#### Task 2: Scanner

**Context required:** `Models.swift`, `Protocols.swift`, all mocks, spec §5 (Directory Scanning).

**Delivers:**
- `Scanner.swift`
- `ScannerTests.swift` — all tests from §3.2 Scanner Tests section

**Acceptance criteria:** All scanner tests pass against mocks. Scanner correctly classifies every case in the classification table.

**Key details for agent:**
- Scanner receives `FileSystemProvider`, `AssetInspector`, `FileTypeIdentifier` via init.
- Returns `ScanResult`, not `[FileEntry]` — the result includes skip counts and warnings.
- Must handle the state-aware skip logic (preset mismatch, `--fresh` flag).
- Must produce `ScanWarning` entries for unsupported containers, probe failures, large ProRes files.

---

#### Task 3: StateManager

**Context required:** `Models.swift`, `Protocols.swift`, mocks, spec §6 (State Management).

**Delivers:**
- `StateManager.swift` — the actor
- `StateManagerTests.swift` — all tests from §3.2 StateManager Tests section

**Acceptance criteria:** All state tests pass. Actor compiles correctly. Debounce logic verified.

**Key details for agent:**
- Must be an `actor`.
- The debounce mechanism: maintain a `lastFlush` timestamp; only write to disk if >1 second since last flush, OR on explicit `flush()` call (used at shutdown).
- `load()` must handle: missing file, corrupt JSON (log and start fresh), `in_progress` recovery.
- Process lock acquisition via `ProcessLockProvider`.

---

#### Task 4: Encoder

**Context required:** `Models.swift`, `Protocols.swift`, mocks, spec §7 (Encoding).

**Delivers:**
- `Encoder.swift` — the encode orchestration logic
- `EncoderTests.swift` — all tests from §3.2 Encoder Tests section
- `RealExportSessionFactory.swift` — the production `ExportSessionFactory` implementation wrapping `AVAssetExportSession`

**Acceptance criteria:** All encoder unit tests pass against mocks. `RealExportSessionFactory` compiles.

**Key details for agent:**
- The `Encoder` struct is the orchestration layer: tmp file management, validation, cleanup.
- `RealExportSessionFactory` is a thin wrapper around `AVAssetExportSession` — it's the only code in this component that touches AVFoundation directly.
- Output validation: check file size > 0 AND `inspector.isPlayable`.
- Container mapping: `.mov` → `.mov`, `.mp4` → `.mp4`, `.m4v` → `.mp4` internally with `.m4v` extension preserved.

---

#### Task 5: MetadataCopier

**Context required:** `Models.swift`, `Protocols.swift`, mocks, spec §8 (Metadata Copying).

**Delivers:**
- `MetadataCopier.swift`
- `MetadataCopierTests.swift` — all tests from §3.2 MetadataCopier Tests section
- `URL+Xattr.swift` — real xattr extensions (`fgetxattr`/`fsetxattr` wrappers) for production use

**Acceptance criteria:** All metadata tests pass against mocks.

**Key details for agent:**
- Copies: creation date, modification date, Finder tags (xattr).
- All operations are graceful on missing data — log and skip, never throw.
- The xattr extension should be a clean, reusable `URL` extension.

---

#### Task 6: Reporter

**Context required:** `Models.swift`, `Protocols.swift`, `MockClock`, spec §9 (Reporting).

**Delivers:**
- `Reporter.swift`
- `ReporterTests.swift` — all tests from §3.2 Reporter Tests section

**Acceptance criteria:** All reporter tests pass. All output formatting matches the spec exactly.

**Key details for agent:**
- Reporter is the most "pure" component — it's all input→string transformations.
- Size formatting: use KB/MB/GB with 1 decimal place. Pick the largest unit that's >= 1.
- Time formatting: `Xs` for < 60s, `Xm Ys` for < 60m, `Xh Ym Zs` for >= 60m.
- The right-aligned counter format `[  42/142]` must pad to the width of the total.
- Estimation logic must be tested for both lossy and lossless presets.

---

#### Task 7: Signals & Shutdown Coordinator

**Context required:** `Models.swift`, spec §10 (Error Handling — SIGINT section).

**Delivers:**
- `Signals.swift` — `ShutdownCoordinator` and SIGINT setup
- `SignalsTests.swift` — thread-safety tests

**Acceptance criteria:** `ShutdownCoordinator` is thread-safe. SIGINT registration compiles.

**Key details for agent:**
- `ShutdownCoordinator` must be `Sendable`. Use `os_unfair_lock` or `ManagedAtomic<Bool>` — implementer's choice, but the spec prefers avoiding the swift-atomics dependency.
- The `DispatchSource` setup is only a few lines but must follow the exact pattern in §10 (ignore default SIGINT first, then register the source).

---

#### Task 8: Orchestrator + Integration Tests

**Context required:** All prior deliverables, full spec.

**Delivers:**
- `Main.swift` — the `run()` method that wires everything together
- `RealFileSystem.swift` — production `FileSystemProvider` implementation
- `RealAssetInspector.swift` — production `AssetInspector` implementation
- `RealFileTypeIdentifier.swift` — production `FileTypeIdentifier` implementation
- `RealProcessLock.swift` — production `ProcessLockProvider` implementation
- `RealClock.swift` — production `Clock` implementation
- `Integration/EncodeIntegrationTests.swift` — real encode tests
- `Integration/Fixtures/` — test video files (generated via ffmpeg commands in §3.3)

**Acceptance criteria:** `swift build` succeeds. Unit tests pass. Integration tests pass (real encode of 2-second clip produces HEVC output with metadata).

**Key details for agent:**
- This is the only agent that needs to see all implementations.
- The `run()` method follows the architecture diagram in §11 exactly.
- Must implement the bounded TaskGroup dispatch loop.
- Must wire up `processFile` with the do/catch error containment.
- Must implement disk-full detection and special exit.
- Real implementations are thin wrappers around system APIs — most logic is in the tested components above.

### 14.3 Dependency Graph & Execution Order

```
Task 0: Foundation (Models, Protocols, Mocks)
   │
   ├──→ Task 1: CLI         (independent)
   ├──→ Task 2: Scanner     (independent)
   ├──→ Task 3: StateManager (independent)
   ├──→ Task 4: Encoder     (independent)
   ├──→ Task 5: MetadataCopier (independent)
   ├──→ Task 6: Reporter    (independent)
   └──→ Task 7: Signals     (independent)
              │
              └──all──→ Task 8: Orchestrator + Integration
```

Tasks 1–7 can run **in parallel** since they only depend on Task 0's outputs (protocols and types). Task 8 runs last and pulls everything together.

### 14.4 Context Budget Per Agent

Each agent receives:

| Item | Approximate Tokens |
|---|---|
| Relevant spec section(s) | 1,500–3,000 |
| `Models.swift` | ~500 |
| `Protocols.swift` | ~800 |
| Relevant mock file(s) | ~300–500 |
| Test expectations (from §3.2) | ~500–1,000 |
| **Total per agent** | **~3,500–5,500** |

This leaves ample room for the agent to think and generate code, even in smaller context windows.

### 14.5 Handoff Artifacts

Each agent produces a deliverable that is checked into the repo. The handoff checklist:

1. All `.swift` files compile (verified by running `swift build`).
2. All tests pass (verified by running `swift test`).
3. No `import` of another component's implementation — only protocols and models.
4. No global mutable state — only `StateManager` (actor) and `ShutdownCoordinator` (atomic).

If an agent's tests reveal a needed change to `Models.swift` or `Protocols.swift`, that change must be flagged and applied to Task 0's outputs before other agents consume them. In practice, Task 0 should be thorough enough that this is rare.

---

## 15. Resolved Decisions

1. **Quality preset:** CLI flag `--lossless` switches between `HEVCHighestQuality` (default, lossy) and `HEVCHighestQualityLossless`.
2. **`.m4v` handling:** Preserve the `.m4v` extension on output files. Internally use `AVFileType.mp4` for encoding.
3. **`--jobs` default:** Auto-detect based on Apple Silicon chip suffix.
4. **Plan → Confirm → Execute:** Every run scans first, prints a plan summary, and waits for Enter before encoding.
5. **No avconvert fallback.**
6. **Audio re-encode:** Acceptable if rare. No two-pass mux workaround planned.
7. **Signal handling:** `DispatchSource.makeSignalSource` instead of C `signal()`.
8. **Bounded concurrency:** TaskGroup uses a seed-and-refill loop.
9. **Process lock:** Advisory `flock()` on `.vcompress.lock`.
10. **Preset tracking in state:** Each completed entry records which preset was used.
11. **Audio-only video containers:** Skipped as `noVideoTrack` during scan.
12. **Output validation:** After each encode, verify non-zero bytes and playable.
13. **Orphaned `.tmp` cleanup:** On startup, glob and delete stale `.tmp` files in dest.
