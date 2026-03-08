import Foundation

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
