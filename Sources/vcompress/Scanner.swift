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

    /// The xattr key used by macOS Finder for user tags.
    private static let finderTagsXattr = "com.apple.metadata:_kMDItemUserTags"

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
        var allFiles: [ScannedFile] = []
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

            let fileSize = (attrs?[.size] as? Int64)
                ?? (attrs?[.size] as? NSNumber)?.int64Value
                ?? 0

            let sourcePath = url.path
            let tags = readFinderTags(atPath: sourcePath)

            // 1. Not a video (typeID.isMovie returns false) -> skip(notVideo)
            guard typeID.isMovie(at: url) else {
                skipCounts[.notVideo, default: 0] += 1
                allFiles.append(ScannedFile(sourcePath: sourcePath, relativePath: relativePath, fileSize: fileSize, classification: .skipped(.notVideo), finderTags: tags))
                continue
            }

            // 2. Unsupported container
            let ext = typeID.fileExtension(at: url)
            guard Scanner.supportedContainers.contains(ext) else {
                skipCounts[.unsupportedContainer, default: 0] += 1
                warnings.append(.unsupportedContainer(path: relativePath, ext: ext))
                allFiles.append(ScannedFile(sourcePath: sourcePath, relativePath: relativePath, fileSize: fileSize, classification: .skipped(.unsupportedContainer), finderTags: tags))
                continue
            }

            // 3. No video track (inspector returns empty array) -> skip(noVideoTrack)
            let codecs: [CMVideoCodecType]
            do {
                codecs = try await inspector.videoTrackCodecs(forFileAt: url)
            } catch {
                warnings.append(.probeFailed(path: relativePath, error: error))
                skipCounts[.noVideoTrack, default: 0] += 1
                allFiles.append(ScannedFile(sourcePath: sourcePath, relativePath: relativePath, fileSize: fileSize, classification: .skipped(.noVideoTrack), finderTags: tags))
                continue
            }

            if codecs.isEmpty {
                skipCounts[.noVideoTrack, default: 0] += 1
                allFiles.append(ScannedFile(sourcePath: sourcePath, relativePath: relativePath, fileSize: fileSize, classification: .skipped(.noVideoTrack), finderTags: tags))
                continue
            }

            // 4. Below --min-size -> skip(tooSmall)
            if let minSize = config.minSize, fileSize < minSize {
                skipCounts[.tooSmall, default: 0] += 1
                allFiles.append(ScannedFile(sourcePath: sourcePath, relativePath: relativePath, fileSize: fileSize, classification: .skipped(.tooSmall), finderTags: tags))
                continue
            }

            // 5. Already HEVC (hvc1 or hev1) -> skip(alreadyHEVC)
            let hevcCodecs: Set<FourCharCode> = [kCMVideoCodecType_HEVC, FourCharCode(0x68657631)]
            if codecs.contains(where: { hevcCodecs.contains($0) }) {
                skipCounts[.alreadyHEVC, default: 0] += 1
                let info = try? await inspector.videoTrackInfo(forFileAt: url)
                allFiles.append(ScannedFile(sourcePath: sourcePath, relativePath: relativePath, fileSize: fileSize, classification: .skipped(.alreadyHEVC), trackInfo: info, finderTags: tags))
                continue
            }

            // 5.5. Already efficiently compressed -> skip(alreadyEfficient)
            let trackInfo = try? await inspector.videoTrackInfo(forFileAt: url)
            if let info = trackInfo {
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
                        allFiles.append(ScannedFile(sourcePath: sourcePath, relativePath: relativePath, fileSize: fileSize, classification: .skipped(.alreadyEfficient), trackInfo: info, finderTags: tags))
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
                        allFiles.append(ScannedFile(sourcePath: sourcePath, relativePath: relativePath, fileSize: fileSize, classification: .skipped(.alreadyDone), trackInfo: trackInfo, finderTags: tags))
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
                sourceContainer: ext,
                finderTags: tags
            )
            pending.append(fileEntry)
            allFiles.append(ScannedFile(sourcePath: sourcePath, relativePath: relativePath, fileSize: fileSize, classification: .pending, trackInfo: trackInfo, finderTags: tags))
        }

        return ScanResult(
            pending: pending,
            skipCounts: skipCounts,
            warnings: warnings,
            totalScanned: totalScanned,
            allFiles: allFiles
        )
    }

    /// Read Finder tags from a file's extended attributes.
    /// Returns an empty array if no tags are set or on error.
    private func readFinderTags(atPath path: String) -> [String] {
        guard let tagData = try? fs.getExtendedAttribute(Self.finderTagsXattr, atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: tagData, options: [], format: nil) as? [String]
        else {
            return []
        }
        // Tags are stored as "TagName\n<color_index>". Strip the color suffix.
        return plist.map { tag in
            if let newlineIndex = tag.firstIndex(of: "\n") {
                return String(tag[tag.startIndex..<newlineIndex])
            }
            return tag
        }
    }
}
