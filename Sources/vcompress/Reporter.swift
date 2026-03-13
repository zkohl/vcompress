import Foundation
import CoreMedia

/// Pure-logic reporting component. Takes data in, produces formatted strings out.
/// Writing log files to disk is the caller's responsibility.
public struct Reporter {
    public let clock: Clock

    public init(clock: Clock) {
        self.clock = clock
    }

    // MARK: - Plan Summary

    /// Formats the plan summary shown before encoding begins.
    public func formatPlan(_ result: ScanResult, config: Config) -> String {
        let pendingSize = result.pending.reduce(Int64(0)) { $0 + $1.fileSize }
        let estimate = Self.estimateOutput(inputSize: pendingSize, quality: config.quality)

        let presetLabel: String
        switch config.quality {
        case .standard:
            presetLabel = "HEVC Highest Quality (standard)"
        case .high:
            presetLabel = "HEVC Quality 0.65 (high)"
        case .veryHigh:
            presetLabel = "HEVC Quality 0.75 (very-high)"
        case .max:
            presetLabel = "HEVC Quality 0.85 (max)"
        }

        var lines: [String] = []
        lines.append("vcompress plan")
        lines.append("  Source: \(config.sourceDir.path)")
        lines.append("  Dest:   \(config.destDir.path)")
        lines.append("  Preset: \(presetLabel)")
        lines.append("  Jobs:   \(config.jobs)")
        lines.append("")

        let pendingSizeStr = Self.formatSize(pendingSize)
        lines.append("  Files to encode:   \(String(format: "%3d", result.pending.count))   (\(pendingSizeStr))")

        // Skip counts in display order
        let skipOrder: [(SkipReason, String)] = [
            (.alreadyHEVC, "Already HEVC:"),
            (.alreadyDone, "Already done:"),
            (.tooSmall, "Below min-size:"),
            (.alreadyEfficient, "Low bitrate:"),
            (.noVideoTrack, "No video track:"),
            (.notVideo, "Not video:"),
            (.unsupportedContainer, "Unsupported:"),
            (.excludedByTag, "Excluded by tag:"),
            (.missingTag, "Missing tag:"),
        ]
        for (reason, label) in skipOrder {
            let count = result.skipCounts[reason] ?? 0
            if count > 0 {
                lines.append("  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(String(format: "%4d", count))")
            }
        }

        let separator = String(repeating: "\u{2500}", count: 33)
        lines.append("  \(separator)")
        lines.append("  Total scanned:     \(String(format: "%3d", result.totalScanned))")
        lines.append("")
        lines.append("  Estimated output: ~\(Self.formatSize(estimate.low))\u{2013}\(Self.formatSize(estimate.high))")

        return lines.joined(separator: "\n")
    }

    // MARK: - File List

    /// Formats a per-file listing of all scanned files with their classification.
    public func formatFileList(_ files: [ScannedFile]) -> String {
        guard !files.isEmpty else { return "" }

        var lines: [String] = []
        for file in files {
            let size = Self.formatSize(file.fileSize)
            let meta = Self.formatTrackMeta(file.trackInfo)
            switch file.classification {
            case .pending:
                lines.append("  encode  \(file.relativePath)  \(size)\(meta)")
            case .skipped(let reason):
                if reason == .notVideo { continue }
                let reasonLabel = Self.skipReasonLabel(reason)
                lines.append("  skip    \(file.relativePath)  \(size)\(meta)  (\(reasonLabel))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Formats a JSON representation of scan results for machine consumption.
    public func formatJSON(_ result: ScanResult, config: Config) -> String {
        var files: [[String: Any]] = []
        for file in result.allFiles {
            if case .skipped(.notVideo) = file.classification { continue }
            var entry: [String: Any] = [
                "path": file.relativePath,
                "sourcePath": file.sourcePath,
                "size": file.fileSize,
                "finderTags": file.finderTags,
            ]
            switch file.classification {
            case .pending:
                entry["action"] = "encode"
            case .skipped(let reason):
                entry["action"] = "skip"
                entry["reason"] = Self.skipReasonLabel(reason)
            }
            if let info = file.trackInfo {
                entry["codec"] = Self.formatCodec(info.codec)
                entry["width"] = info.width
                entry["height"] = info.height
                entry["frameRate"] = round(info.frameRate * 10) / 10
                entry["bitrateMbps"] = round(info.estimatedBitrate / 1_000_000 * 10) / 10
                if info.width > 0, info.height > 0, info.frameRate > 0, info.estimatedBitrate > 0 {
                    let bpp = info.estimatedBitrate / (Double(info.width) * Double(info.height) * info.frameRate)
                    let mbPerMin = info.estimatedBitrate * 60.0 / 8.0 / 1_000_000.0
                    entry["bpp"] = round(bpp * 100) / 100
                    entry["mbPerMin"] = round(mbPerMin * 10) / 10
                }
            }
            files.append(entry)
        }

        var skipSummary: [String: Int] = [:]
        for (reason, count) in result.skipCounts {
            skipSummary[Self.skipReasonLabel(reason)] = count
        }

        let root: [String: Any] = [
            "source": config.sourceDir.path,
            "dest": config.destDir.path,
            "preset": config.quality.rawValue,
            "files": files,
            "summary": [
                "totalScanned": result.totalScanned,
                "toEncode": result.pending.count,
                "skipped": skipSummary,
            ] as [String: Any],
        ]

        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }

    /// Human-readable label for a skip reason.
    public static func skipReasonLabel(_ reason: SkipReason) -> String {
        switch reason {
        case .alreadyHEVC: return "already HEVC"
        case .alreadyDone: return "already done"
        case .tooSmall: return "below min-size"
        case .alreadyEfficient: return "low bitrate"
        case .noVideoTrack: return "no video track"
        case .notVideo: return "not video"
        case .unsupportedContainer: return "unsupported"
        case .excludedByTag: return "excluded by tag"
        case .missingTag: return "missing tag"
        }
    }

    /// Formats video track metadata as a compact suffix string.
    private static func formatTrackMeta(_ info: VideoTrackInfo?) -> String {
        guard let info = info else { return "" }
        let codec = formatCodec(info.codec)
        let mbps = Int(round(info.estimatedBitrate / 1_000_000))
        return "  \(codec) \(info.width)x\(info.height) \(Int(info.frameRate))fps \(mbps)Mbps"
    }

    /// Formats a CMVideoCodecType as a human-readable string.
    public static func formatCodec(_ codec: CMVideoCodecType) -> String {
        switch codec {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        case kCMVideoCodecType_AppleProRes422HQ: return "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422LT: return "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy: return "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProResRAW: return "ProRes RAW"
        case kCMVideoCodecType_AppleProResRAWHQ: return "ProRes RAW HQ"
        default:
            // Fall back to FourCC string
            let chars = [
                UInt8((codec >> 24) & 0xFF),
                UInt8((codec >> 16) & 0xFF),
                UInt8((codec >> 8) & 0xFF),
                UInt8(codec & 0xFF),
            ]
            let str = String(bytes: chars, encoding: .ascii) ?? "????"
            return str
        }
    }

    // MARK: - Copy Mode Plan

    /// Formats the plan summary for copy mode.
    public func formatCopyPlan(_ result: ScanResult, config: Config, fs: FileSystemProvider) -> String {
        let pendingSize = result.pending.reduce(Int64(0)) { $0 + $1.fileSize }

        var lines: [String] = []
        lines.append("vcompress copy plan")
        lines.append("  Source: \(config.sourceDir.path)")
        lines.append("  Dest:   \(config.destDir.path)")
        lines.append("  Jobs:   \(config.jobs)")
        lines.append("")

        let pendingSizeStr = Self.formatSize(pendingSize)
        lines.append("  Files to copy:     \(String(format: "%3d", result.pending.count))   (\(pendingSizeStr))")

        let overwriteCount = result.pending.filter { file in
            fs.fileExists(atPath: config.destDir.appendingPathComponent(file.relativePath).path)
        }.count
        if overwriteCount > 0 {
            lines.append("  Overwriting:       \(String(format: "%3d", overwriteCount))")
        }

        let skipOrder: [(SkipReason, String)] = [
            (.excludedByTag, "Excluded by tag:"),
            (.missingTag, "Missing tag:"),
        ]
        for (reason, label) in skipOrder {
            let count = result.skipCounts[reason] ?? 0
            if count > 0 {
                lines.append("  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(String(format: "%4d", count))")
            }
        }

        let separator = String(repeating: "\u{2500}", count: 33)
        lines.append("  \(separator)")
        lines.append("  Total scanned:     \(String(format: "%3d", result.totalScanned))")

        return lines.joined(separator: "\n")
    }

    /// Formats the per-file listing for copy mode.
    public func formatCopyFileList(_ files: [ScannedFile], fs: FileSystemProvider, destDir: URL) -> String {
        guard !files.isEmpty else { return "" }

        var lines: [String] = []
        for file in files {
            let size = Self.formatSize(file.fileSize)
            switch file.classification {
            case .pending:
                let destPath = destDir.appendingPathComponent(file.relativePath).path
                let exists = fs.fileExists(atPath: destPath)
                let suffix = exists ? "  (overwrite)" : ""
                lines.append("  copy    \(file.relativePath)  \(size)\(suffix)")
            case .skipped(let reason):
                let reasonLabel = Self.skipReasonLabel(reason)
                lines.append("  skip    \(file.relativePath)  \(size)  (\(reasonLabel))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Formats a single progress line for a copied file.
    public func formatCopyProgress(
        index: Int,
        total: Int,
        path: String,
        fileSize: Int64,
        overwritten: Bool
    ) -> String {
        let totalWidth = String(total).count
        let indexStr = String(index).leftPadded(toLength: totalWidth)
        let sizeStr = Self.formatSize(fileSize)
        let suffix = overwritten ? "  (overwritten)" : ""

        return "[\(indexStr)/\(total)]  copied  \(path)  \(sizeStr)\(suffix)"
    }

    /// Formats the completion summary for copy mode.
    public func formatCopySummary(
        copied: Int,
        skipped: Int,
        failed: Int,
        totalSize: Int64,
        overwrittenCount: Int,
        wallTime: TimeInterval
    ) -> String {
        var lines: [String] = []
        lines.append("vcompress copy complete")
        lines.append("  Copied:      \(String(format: "%5d", copied)) files")
        if overwrittenCount > 0 {
            lines.append("  Overwritten: \(String(format: "%5d", overwrittenCount)) files")
        }
        lines.append("  Skipped:     \(String(format: "%5d", skipped)) files")
        lines.append("  Failed:      \(String(format: "%5d", failed)) files")
        lines.append("")
        lines.append("  Total size:  \(Self.formatSize(totalSize))")
        lines.append("  Wall time:   \(Self.formatTime(wallTime))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Encoding Start Line

    /// Formats a line printed when a file begins encoding.
    public func formatStarting(path: String, inputSize: Int64) -> String {
        let size = Self.formatSize(inputSize)
        return "  encoding  \(path)  (\(size))"
    }

    // MARK: - Progress Line

    /// Formats a single progress line for a completed file.
    public func formatProgress(
        index: Int,
        total: Int,
        path: String,
        inputSize: Int64,
        outputSize: Int64,
        elapsed: TimeInterval
    ) -> String {
        let totalWidth = String(total).count
        let indexStr = String(index).leftPadded(toLength: totalWidth)
        let inputStr = Self.formatSize(inputSize)
        let outputStr = Self.formatSize(outputSize)
        let savings = inputSize > 0
            ? Int(round(Double(inputSize - outputSize) / Double(inputSize) * 100))
            : 0
        let timeStr = Self.formatTime(elapsed)

        return "[\(indexStr)/\(total)]  encoded  \(path)  \(inputStr) \u{2192} \(outputStr) (\(savings)%)  \(timeStr)"
    }

    // MARK: - Completion Summary

    /// Formats the completion summary shown after all encoding is done.
    public func formatSummary(
        encoded: Int,
        skipped: Int,
        failed: Int,
        inputSize: Int64,
        outputSize: Int64,
        wallTime: TimeInterval,
        stateFilePath: String,
        logFilePath: String
    ) -> String {
        let saved = inputSize - outputSize
        let savingsPercent = inputSize > 0
            ? Double(saved) / Double(inputSize) * 100
            : 0

        var lines: [String] = []
        lines.append("vcompress complete")
        lines.append("  Encoded:  \(String(format: "%5d", encoded)) files")
        lines.append("  Skipped:  \(String(format: "%5d", skipped)) files")
        lines.append("  Failed:   \(String(format: "%5d", failed)) files")
        lines.append("")
        lines.append("  Input size:   \(Self.formatSize(inputSize))")
        lines.append("  Output size:  \(Self.formatSize(outputSize))")
        lines.append("  Saved:        \(Self.formatSize(saved)) (\(String(format: "%.1f", savingsPercent))%)")
        lines.append("  Wall time:    \(Self.formatTime(wallTime))")
        lines.append("")
        lines.append("  State: \(stateFilePath)")
        lines.append("  Log:   \(logFilePath)")

        return lines.joined(separator: "\n")
    }

    // MARK: - Log Line

    /// Formats a single log line with an ISO 8601 timestamp (with colons).
    public func formatLogLine(level: String, message: String) -> String {
        let date = clock.now()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: date)
        return "[\(timestamp)] [\(level)] \(message)"
    }

    // MARK: - Estimation

    /// Estimates the output size range for a given input size and quality tier.
    /// Standard: 5%-15%, High: 5%-20%, Very-High: 10%-30%, Max: 20%-45%.
    public static func estimateOutput(inputSize: Int64, quality: Quality) -> (low: Int64, high: Int64) {
        let (lowFraction, highFraction): (Double, Double)
        switch quality {
        case .standard:
            (lowFraction, highFraction) = (0.05, 0.15)
        case .high:
            (lowFraction, highFraction) = (0.05, 0.20)
        case .veryHigh:
            (lowFraction, highFraction) = (0.10, 0.30)
        case .max:
            (lowFraction, highFraction) = (0.20, 0.45)
        }
        let low = Int64(Double(inputSize) * lowFraction)
        let high = Int64(Double(inputSize) * highFraction)
        return (low, high)
    }

    // MARK: - Log Filename

    /// Generates a log filename using compact timestamp format: YYYYMMDDTHHmmssZ (no colons).
    public static func logFilename(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return ".vcompress-log-\(formatter.string(from: date)).txt"
    }

    // MARK: - Size Formatting

    /// Formats a byte count as KB/MB/GB with 1 decimal place.
    /// Uses the largest unit where the value is >= 1.0.
    /// Uses binary units (1 KB = 1024 bytes).
    public static func formatSize(_ bytes: Int64) -> String {
        let absBytes = abs(bytes)
        let gb = Double(absBytes) / (1024.0 * 1024.0 * 1024.0)
        let mb = Double(absBytes) / (1024.0 * 1024.0)
        let kb = Double(absBytes) / 1024.0

        let sign = bytes < 0 ? "-" : ""

        if gb >= 1.0 {
            return "\(sign)\(String(format: "%.1f", gb)) GB"
        } else if mb >= 1.0 {
            return "\(sign)\(String(format: "%.1f", mb)) MB"
        } else if kb >= 1.0 {
            return "\(sign)\(String(format: "%.1f", kb)) KB"
        } else {
            return "\(sign)\(absBytes) B"
        }
    }

    // MARK: - Time Formatting

    /// Formats seconds as a human-readable duration.
    /// < 60s: "Xs", < 60m: "Xm Ys", >= 60m: "Xh Ym Zs"
    public static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60

        if totalSeconds < 60 {
            return "\(s)s"
        } else if totalSeconds < 3600 {
            return "\(m)m \(s)s"
        } else {
            return "\(h)h \(m)m \(s)s"
        }
    }
}

// MARK: - String Padding Helper

extension String {
    /// Left-pads the string with spaces to the given length.
    func leftPadded(toLength length: Int) -> String {
        if self.count >= length { return self }
        return String(repeating: " ", count: length - self.count) + self
    }
}
