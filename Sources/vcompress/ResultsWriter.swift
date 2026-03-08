import Foundation
import CoreMedia

/// Thread-safe actor that builds and incrementally writes a JSON results file.
/// The file is rewritten atomically after each mutation, ensuring crash resilience
/// and no partial reads.
actor ResultsWriter {
    private let outputURL: URL
    private let fs: FileSystemProvider
    private var results: ResultsFile

    init(outputURL: URL, fs: FileSystemProvider) {
        self.outputURL = outputURL
        self.fs = fs
        self.results = ResultsFile()
    }

    /// Initialize the results file with scan data and job metadata.
    func initialize(config: Config, scanResult: ScanResult) throws {
        let formatter = ISO8601DateFormatter()

        results.source = config.sourceDir.path
        results.dest = config.destDir.path
        results.preset = config.quality.rawValue
        results.quality = config.quality.compressionQuality
        results.startedAt = formatter.string(from: Date())

        // Populate skip summary from scan
        for (reason, count) in scanResult.skipCounts {
            results.summary.skipped[Reporter.skipReasonLabel(reason)] = count
        }
        results.summary.totalScanned = scanResult.totalScanned
        results.summary.toEncode = scanResult.pending.count

        // Add all scanned files
        for file in scanResult.allFiles {
            var entry = ResultsFileEntry()
            entry.path = file.relativePath
            entry.sourcePath = file.sourcePath
            entry.size = file.fileSize
            entry.finderTags = file.finderTags

            switch file.classification {
            case .pending:
                entry.action = "encode"
            case .skipped(let reason):
                entry.action = "skip"
                entry.skipReason = Reporter.skipReasonLabel(reason)
            }

            if let info = file.trackInfo {
                entry.codec = Reporter.formatCodec(info.codec)
                entry.width = info.width
                entry.height = info.height
                entry.frameRate = round(info.frameRate * 10) / 10
                entry.bitrateMbps = round(info.estimatedBitrate / 1_000_000 * 10) / 10
                if info.width > 0, info.height > 0, info.frameRate > 0, info.estimatedBitrate > 0 {
                    let bpp = info.estimatedBitrate / (Double(info.width) * Double(info.height) * info.frameRate)
                    entry.bpp = round(bpp * 100) / 100
                }
            }

            results.files.append(entry)
        }

        try writeToDisk()
    }

    /// Record a successful encode for a file.
    func recordEncoded(relativePath: String, outputPath: String, outputSize: Int64) throws {
        if let index = results.files.firstIndex(where: { $0.path == relativePath }) {
            results.files[index].outputPath = outputPath
            results.files[index].outputSize = outputSize
            if results.files[index].size > 0 {
                let ratio = Double(outputSize) / Double(results.files[index].size)
                results.files[index].compressionRatio = round(ratio * 100) / 100
            }
        }
        results.summary.encoded += 1
        try writeToDisk()
    }

    /// Record a failed encode for a file.
    func recordFailed(relativePath: String, error: String) throws {
        if let index = results.files.firstIndex(where: { $0.path == relativePath }) {
            results.files[index].error = error
        }
        results.summary.failed += 1
        try writeToDisk()
    }

    /// Finalize the results file with completion timestamp.
    func finalize() throws {
        let formatter = ISO8601DateFormatter()
        results.completedAt = formatter.string(from: Date())
        try writeToDisk()
    }

    private func writeToDisk() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(results)
        try fs.write(data, to: outputURL, atomically: true)
    }
}

// MARK: - Results File Model

struct ResultsFile: Codable {
    var source: String = ""
    var dest: String = ""
    var preset: String = ""
    var quality: Double?
    var startedAt: String?
    var completedAt: String?
    var files: [ResultsFileEntry] = []
    var summary: ResultsSummary = ResultsSummary()
}

struct ResultsFileEntry: Codable {
    var path: String = ""
    var sourcePath: String = ""
    var size: Int64 = 0
    var action: String = ""
    var codec: String?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var bitrateMbps: Double?
    var bpp: Double?
    var finderTags: [String] = []
    var skipReason: String?
    var outputPath: String?
    var outputSize: Int64?
    var compressionRatio: Double?
    var error: String?
}

struct ResultsSummary: Codable {
    var totalScanned: Int = 0
    var toEncode: Int = 0
    var encoded: Int = 0
    var failed: Int = 0
    var skipped: [String: Int] = [:]
}
