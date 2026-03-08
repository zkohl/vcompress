import Foundation
import AVFoundation

/// Orchestrates video encoding: manages temp files, calls the export factory,
/// validates output, and handles cleanup on failure.
struct Encoder {
    let factory: ExportSessionFactory
    let fs: FileSystemProvider
    let inspector: AssetInspector

    /// Encode a single file entry to HEVC.
    ///
    /// Orchestration:
    /// 1. Compute temp URL: destPath + ".tmp"
    /// 2. Create parent directories via fs.createDirectory
    /// 3. Determine AVFileType from sourceContainer
    /// 4. Call factory.export to temp URL with quality tier
    /// 5. Validate output: file exists, size > 0, inspector.isPlayable
    /// 6. Move temp to final path
    /// 7. On ANY failure: delete temp file if it exists, rethrow
    func encode(_ entry: FileEntry, quality: Quality) async throws {
        let destURL = URL(fileURLWithPath: entry.destPath)
        let tmpURL = URL(fileURLWithPath: entry.destPath + ".tmp")
        let sourceURL = URL(fileURLWithPath: entry.sourcePath)

        // Determine file type from source container
        let fileType: AVFileType = Self.fileType(for: entry.sourceContainer)

        do {
            // Create parent directories
            let parentDir = destURL.deletingLastPathComponent()
            try fs.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Export to temp URL
            try await factory.export(
                source: sourceURL,
                destination: tmpURL,
                fileType: fileType,
                quality: quality
            )

            // Validate output exists and has size > 0
            guard fs.fileExists(atPath: tmpURL.path) else {
                throw EncodingError.outputValidation("Output file does not exist")
            }

            let attrs = try fs.attributesOfItem(atPath: tmpURL.path)
            let size = (attrs[.size] as? Int64) ?? (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                throw EncodingError.outputValidation("Output file is zero bytes")
            }

            // Remove existing destination if present (e.g. --fresh re-encode)
            if fs.fileExists(atPath: destURL.path) {
                try fs.removeItem(at: destURL)
            }

            // Move temp to final path (before playability check, since AVFoundation
            // needs a recognized file extension to determine playability)
            try fs.moveItem(at: tmpURL, to: destURL)

            // Validate output is playable
            let playable = try await inspector.isPlayable(at: destURL)
            guard playable else {
                try? fs.removeItem(at: destURL)
                throw EncodingError.outputValidation("Output file is not playable")
            }

        } catch {
            // Cleanup: delete temp and dest files if they exist
            if fs.fileExists(atPath: tmpURL.path) {
                try? fs.removeItem(at: tmpURL)
            }
            if fs.fileExists(atPath: destURL.path) {
                try? fs.removeItem(at: destURL)
            }
            throw error
        }
    }

    /// Map source container extension to AVFileType.
    /// - "mov" -> AVFileType.mov
    /// - "mp4", "m4v" -> AVFileType.mp4
    static func fileType(for container: String) -> AVFileType {
        switch container.lowercased() {
        case "mov":
            return .mov
        case "mp4", "m4v":
            return .mp4
        default:
            return .mp4
        }
    }
}
