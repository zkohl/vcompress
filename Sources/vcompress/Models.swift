import Foundation
import AVFoundation

// MARK: - FileEntry

/// Represents a single video file that has been classified as pending for encoding.
public struct FileEntry: Codable, Equatable {
    public let sourcePath: String
    public let relativePath: String
    public let destPath: String
    public let fileSize: Int64
    public let sourceContainer: String

    public init(
        sourcePath: String,
        relativePath: String,
        destPath: String,
        fileSize: Int64,
        sourceContainer: String
    ) {
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.destPath = destPath
        self.fileSize = fileSize
        self.sourceContainer = sourceContainer
    }
}

// MARK: - ScanResult

/// The output of a directory scan: files to encode, skip counts, and warnings.
public struct ScanResult {
    public let pending: [FileEntry]
    public let skipCounts: [SkipReason: Int]
    public let warnings: [ScanWarning]
    public let totalScanned: Int

    public init(
        pending: [FileEntry],
        skipCounts: [SkipReason: Int],
        warnings: [ScanWarning],
        totalScanned: Int
    ) {
        self.pending = pending
        self.skipCounts = skipCounts
        self.warnings = warnings
        self.totalScanned = totalScanned
    }
}

// MARK: - SkipReason

/// Why a file was skipped during scanning.
public enum SkipReason: Hashable {
    case notVideo
    case noVideoTrack
    case tooSmall
    case alreadyHEVC
    case alreadyDone
    case unsupportedContainer
}

// MARK: - FileStatus

/// The status of a file in the state file.
public enum FileStatus: String, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case skipped
}

// MARK: - Quality

/// Quality tier for HEVC encoding.
public enum Quality: String, CaseIterable, Codable {
    case standard
    case high
    case max
}

// MARK: - Config

/// Runtime configuration derived from CLI arguments.
public struct Config {
    public let sourceDir: URL
    public let destDir: URL
    public let jobs: Int
    public let minSize: Int64?
    public let quality: Quality
    public let yes: Bool
    public let dryRun: Bool
    public let fresh: Bool
    public let verbose: Bool

    public init(
        sourceDir: URL,
        destDir: URL,
        jobs: Int,
        minSize: Int64? = nil,
        quality: Quality = .standard,
        yes: Bool = false,
        dryRun: Bool = false,
        fresh: Bool = false,
        verbose: Bool = false
    ) {
        self.sourceDir = sourceDir
        self.destDir = destDir
        self.jobs = jobs
        self.minSize = minSize
        self.quality = quality
        self.yes = yes
        self.dryRun = dryRun
        self.fresh = fresh
        self.verbose = verbose
    }
}

// MARK: - ScanConfig

/// Configuration subset relevant to scanning.
public struct ScanConfig {
    public let minSize: Int64?
    public let fresh: Bool
    public let preset: String

    public init(minSize: Int64? = nil, fresh: Bool = false, preset: String = "hevc_standard") {
        self.minSize = minSize
        self.fresh = fresh
        self.preset = preset
    }
}

// MARK: - StateFile

/// The persisted state file tracking encoding progress across runs.
public struct StateFile: Codable {
    public var version: Int
    public var created: Date
    public var updated: Date
    public var files: [String: StateFileEntry]

    public init(
        version: Int = 1,
        created: Date = Date(),
        updated: Date = Date(),
        files: [String: StateFileEntry] = [:]
    ) {
        self.version = version
        self.created = created
        self.updated = updated
        self.files = files
    }
}

// MARK: - StateFileEntry

/// A single file's entry in the state file.
public struct StateFileEntry: Codable {
    public var status: FileStatus
    public var preset: String
    public var sourceSize: Int64
    public var outputSize: Int64?
    public var startedAt: Date?
    public var completedAt: Date?
    public var error: String?

    public init(
        status: FileStatus,
        preset: String,
        sourceSize: Int64,
        outputSize: Int64? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        error: String? = nil
    ) {
        self.status = status
        self.preset = preset
        self.sourceSize = sourceSize
        self.outputSize = outputSize
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.error = error
    }
}

// MARK: - EncodingError

/// Errors that can occur during the encoding process.
public enum EncodingError: Error {
    case exportSessionCreation
    case exportFailed(Error?)
    case outputValidation(String)
    case diskFull
}

// MARK: - ScanWarning

/// Warnings generated during scanning that don't prevent progress but should be reported.
public enum ScanWarning {
    case unsupportedContainer(path: String, ext: String)
    case probeFailed(path: String, error: Error)
}
