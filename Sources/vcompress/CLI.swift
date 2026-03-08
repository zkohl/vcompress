import Foundation
import ArgumentParser

// MARK: - Min-Size Parsing

/// Parses a human-readable size string like "50MB", "1GB", "500KB" into bytes.
/// Uses binary units: 1 KB = 1024, 1 MB = 1048576, 1 GB = 1073741824.
/// Regex: ^(\d+)(KB|MB|GB)$ case-insensitive. Rejects anything else.
public func parseMinSize(_ raw: String) throws -> Int64 {
    let pattern = #"^(\d+)(KB|MB|GB)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
          let numberRange = Range(match.range(at: 1), in: raw),
          let unitRange = Range(match.range(at: 2), in: raw),
          let number = Int64(raw[numberRange])
    else {
        throw ValidationError(
            "Invalid --min-size value '\(raw)'. Expected format: <number><KB|MB|GB> (e.g. 50MB, 1GB)."
        )
    }

    let unit = raw[unitRange].uppercased()
    let multiplier: Int64
    switch unit {
    case "KB": multiplier = 1024
    case "MB": multiplier = 1024 * 1024
    case "GB": multiplier = 1024 * 1024 * 1024
    default:
        throw ValidationError(
            "Invalid --min-size unit '\(unit)'. Supported units: KB, MB, GB."
        )
    }

    return number * multiplier
}

// MARK: - Path Overlap Detection

/// Returns true if either resolved path is a prefix of the other.
/// Both URLs are resolved through symlinks before comparison.
public func pathsOverlap(_ a: URL, _ b: URL) -> Bool {
    let resolvedA = a.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedB = b.resolvingSymlinksInPath().standardizedFileURL.path

    // Normalize: ensure paths end with "/" for prefix comparison so that
    // /foo/bar does not falsely match /foo/barbaz.
    let pathA = resolvedA.hasSuffix("/") ? resolvedA : resolvedA + "/"
    let pathB = resolvedB.hasSuffix("/") ? resolvedB : resolvedB + "/"

    return pathA.hasPrefix(pathB) || pathB.hasPrefix(pathA)
}

// MARK: - Auto-Jobs Resolution

/// Resolves the number of parallel encoding jobs.
/// When `explicit` is provided, returns it directly.
/// When nil, auto-detects based on the chip via `sysInfo`:
///   - M* base (no suffix): 2
///   - M* Pro: 3
///   - M* Max or Ultra: 4
///   - Unrecognized Apple Silicon: 2
///   - Intel: 1
public func resolveJobCount(_ explicit: Int?, sysInfo: SystemInfoProvider) -> Int {
    if let explicit = explicit {
        return explicit
    }

    guard sysInfo.isAppleSilicon() else {
        return 1
    }

    let brand = sysInfo.cpuBrandString()

    // Match chip suffix: look for "Pro", "Max", "Ultra" at the end of
    // the brand string (after "Apple M<digit(s)>").
    let uppercased = brand.uppercased()
    if uppercased.contains("ULTRA") {
        return 4
    } else if uppercased.contains("MAX") {
        return 4
    } else if uppercased.contains("PRO") {
        return 3
    }

    // Base Apple Silicon (M1, M2, M3, M4, or unknown like M99)
    return 2
}

// MARK: - Jobs Validation

/// Validates that an explicit jobs value is within the allowed range of 1-8.
/// Throws a ValidationError if out of range.
public func validateJobCount(_ jobs: Int) throws {
    guard jobs >= 1, jobs <= 64 else {
        throw ValidationError(
            "Invalid --jobs value '\(jobs)'. Must be between 1 and 64."
        )
    }
}
