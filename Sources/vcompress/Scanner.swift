import Foundation
import CoreMedia

/// Walks a source directory, classifies each file, and returns a ScanResult
/// containing pending files to encode and counts of skipped files by reason.
public struct Scanner {
    public let fs: FileSystemProvider
    public let inspector: AssetInspector
    public let typeID: FileTypeIdentifier

    /// Supported output containers (lowercased extensions).
    private static let supportedContainers: Set<String> = ["mov", "mp4", "m4v"]

    public init(fs: FileSystemProvider, inspector: AssetInspector, typeID: FileTypeIdentifier) {
        self.fs = fs
        self.inspector = inspector
        self.typeID = typeID
    }

    /// Scans the source directory and classifies every file.
    ///
    /// - Parameters:
    ///   - source: The root source directory URL.
    ///   - dest: The root destination directory URL (used to build mirror paths).
    ///   - config: Scan configuration (minSize, fresh flag).
    ///   - state: Optional state file from a previous run.
    /// - Returns: A `ScanResult` with pending files, skip counts, warnings, and total scanned.
    public func scan(
        source: URL,
        dest: URL,
        config: ScanConfig,
        state: StateFile? = nil
    ) async throws -> ScanResult {
        let entries = try fs.enumerateFiles(
            at: source,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]
        )

        var pending: [FileEntry] = []
        var skipCounts: [SkipReason: Int] = [:]
        var warnings: [ScanWarning] = []
        var totalScanned = 0

        for entry in entries {
            let url = entry.url
            let relativePath = entry.relativePath
            let filename = url.lastPathComponent

            // Skip hidden files and .DS_Store entirely -- do not count them.
            if filename.hasPrefix(".") || filename == ".DS_Store" {
                continue
            }

            // Skip symlinks -- do not count them.
            let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true {
                continue
            }

            let attrs = try? fs.attributesOfItem(atPath: url.path)

            totalScanned += 1

            // 1. Not a video (typeID.isMovie returns false) -> skip(notVideo)
            guard typeID.isMovie(at: url) else {
                skipCounts[.notVideo, default: 0] += 1
                continue
            }

            // 2. Unsupported container
            let ext = typeID.fileExtension(at: url)
            guard Scanner.supportedContainers.contains(ext) else {
                skipCounts[.unsupportedContainer, default: 0] += 1
                warnings.append(.unsupportedContainer(path: relativePath, ext: ext))
                continue
            }

            // 3. No video track (inspector returns empty array) -> skip(noVideoTrack)
            let codecs: [CMVideoCodecType]
            do {
                codecs = try await inspector.videoTrackCodecs(forFileAt: url)
            } catch {
                warnings.append(.probeFailed(path: relativePath, error: error))
                skipCounts[.noVideoTrack, default: 0] += 1
                continue
            }

            if codecs.isEmpty {
                skipCounts[.noVideoTrack, default: 0] += 1
                continue
            }

            // 4. Below --min-size -> skip(tooSmall)
            let fileSize = (attrs?[.size] as? Int64)
                ?? (attrs?[.size] as? NSNumber)?.int64Value
                ?? 0
            if let minSize = config.minSize, fileSize < minSize {
                skipCounts[.tooSmall, default: 0] += 1
                continue
            }

            // 5. Already HEVC (hvc1 or hev1) -> skip(alreadyHEVC)
            let hevcCodecs: Set<FourCharCode> = [kCMVideoCodecType_HEVC, FourCharCode(0x68657631)]
            if codecs.contains(where: { hevcCodecs.contains($0) }) {
                skipCounts[.alreadyHEVC, default: 0] += 1
                continue
            }

            // 5.5. Already efficiently compressed -> skip(alreadyEfficient)
            if let info = try? await inspector.videoTrackInfo(forFileAt: url) {
                let isProRes = [
                    kCMVideoCodecType_AppleProRes4444,
                    kCMVideoCodecType_AppleProRes422,
                    kCMVideoCodecType_AppleProRes422HQ,
                    kCMVideoCodecType_AppleProRes422LT,
                    kCMVideoCodecType_AppleProRes422Proxy,
                    kCMVideoCodecType_AppleProResRAW,
                    kCMVideoCodecType_AppleProResRAWHQ
                ].contains(info.codec)

                if !isProRes,
                   info.width > 0, info.height > 0, info.frameRate > 0,
                   info.estimatedBitrate > 0
                {
                    let bpp = info.estimatedBitrate / (Double(info.width) * Double(info.height) * info.frameRate)
                    let mbPerMin = info.estimatedBitrate * 60.0 / 8.0 / 1_000_000.0
                    if bpp < 0.60 && mbPerMin < 150.0 {
                        skipCounts[.alreadyEfficient, default: 0] += 1
                        warnings.append(.efficientlyCompressed(path: relativePath, width: info.width, height: info.height, frameRate: info.frameRate, bpp: bpp, mbPerMin: mbPerMin))
                        continue
                    }
                }
            }

            // 6. State-aware skip logic
            if !config.fresh, let state = state, let stateEntry = state.files[relativePath] {
                if stateEntry.status == .completed {
                    // Preset must match for skip; otherwise re-encode.
                    // Treat legacy "hevc_highest_quality" as equivalent to "hevc_standard".
                    let normalizedPreset = stateEntry.preset == "hevc_highest_quality"
                        ? "hevc_standard" : stateEntry.preset
                    if normalizedPreset == config.preset {
                        skipCounts[.alreadyDone, default: 0] += 1
                        continue
                    }
                    // Preset mismatch -- fall through to pending (re-encode).
                }
            }

            // Build the FileEntry.
            let destPath = dest.appendingPathComponent(relativePath).path
            let fileEntry = FileEntry(
                sourcePath: url.path,
                relativePath: relativePath,
                destPath: destPath,
                fileSize: fileSize,
                sourceContainer: ext
            )
            pending.append(fileEntry)
        }

        return ScanResult(
            pending: pending,
            skipCounts: skipCounts,
            warnings: warnings,
            totalScanned: totalScanned
        )
    }
}
