import Foundation
import AVFoundation
import CoreMedia

// MARK: - Filesystem Abstraction

/// Abstracts all filesystem operations so Scanner, StateManager, and
/// MetadataCopier can be tested without touching disk.
public protocol FileSystemProvider {
    /// List directory contents recursively. Returns (url, relativePath) pairs.
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
public protocol AssetInspector {
    /// Returns the codec types of all video tracks in the file.
    /// An empty array means "no video tracks" (audio-only container).
    func videoTrackCodecs(forFileAt url: URL) async throws -> [CMVideoCodecType]

    /// Returns metadata about the first video track (resolution, fps, bitrate, codec).
    /// Returns nil if no video track exists.
    func videoTrackInfo(forFileAt url: URL) async throws -> VideoTrackInfo?

    /// Returns whether the asset is playable (used for output validation).
    func isPlayable(at url: URL) async throws -> Bool
}

/// Abstracts the encoding operation. In production this wraps
/// AVAssetExportSession; in tests it can be a mock that returns
/// success/failure without encoding anything.
public protocol ExportSessionFactory {
    func export(
        source: URL,
        destination: URL,
        fileType: AVFileType,
        quality: Quality
    ) async throws
}

// MARK: - System Info Abstraction

/// Abstracts system-level queries (chip detection, process info)
/// so that auto-jobs logic can be unit tested.
public protocol SystemInfoProvider {
    /// Returns the CPU brand string (e.g., "Apple M2 Pro").
    func cpuBrandString() -> String

    /// Returns true if running on Apple Silicon.
    func isAppleSilicon() -> Bool
}

// MARK: - UTType Abstraction

/// Abstracts file type identification so Scanner doesn't depend on
/// UTType directly (which requires real files on disk).
public protocol FileTypeIdentifier {
    /// Returns true if the file at the given URL conforms to the
    /// .movie UTType.
    func isMovie(at url: URL) -> Bool

    /// Returns the file extension (lowercased).
    func fileExtension(at url: URL) -> String
}

// MARK: - Process Lock Abstraction

/// Abstracts the advisory file lock so StateManager tests don't
/// need to coordinate real file locks.
public protocol ProcessLockProvider {
    /// Attempt to acquire an exclusive lock. Returns true on success.
    func acquireLock(at url: URL) throws -> Bool

    /// Release a previously acquired lock.
    func releaseLock() throws
}

// MARK: - Clock Abstraction

/// Abstracts time so that Reporter and StateManager can be tested
/// with deterministic timestamps.
public protocol Clock {
    func now() -> Date
}
