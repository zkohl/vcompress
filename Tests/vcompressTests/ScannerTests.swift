import XCTest
import CoreMedia
@testable import vcompress

final class ScannerTests: XCTestCase {

    // MARK: - Helpers

    private let sourceURL = URL(fileURLWithPath: "/source")
    private let destURL = URL(fileURLWithPath: "/dest")

    private func makeConfig(
        minSize: Int64? = nil,
        fresh: Bool = false,
        preset: String = "hevc_highest_quality"
    ) -> ScanConfig {
        ScanConfig(minSize: minSize, fresh: fresh, preset: preset)
    }

    // MARK: - test_skipsNonVideoFiles

    func test_skipsNonVideoFiles() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/photos/IMG_001.jpg", size: 5_000_000)
        fs.addFile(path: "/source/docs/notes.txt", size: 1_000)

        let typeID = MockFileTypeIdentifier()
        // Neither file is a movie.
        typeID.movieFiles = []

        let scanner = Scanner(fs: fs, inspector: MockAssetInspector(), typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: makeConfig()
        )

        XCTAssertEqual(result.pending.count, 0)
        XCTAssertEqual(result.skipCounts[.notVideo], 2)
    }

    // MARK: - test_skipsAudioOnlyMovFiles

    func test_skipsAudioOnlyMovFiles() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/podcast.mov", size: 50_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["podcast.mov"]

        let inspector = MockAssetInspector()
        inspector.codecs["/source/podcast.mov"] = [] // no video tracks

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: makeConfig()
        )

        XCTAssertEqual(result.pending.count, 0)
        XCTAssertEqual(result.skipCounts[.noVideoTrack], 1)
    }

    // MARK: - test_skipsAlreadyHEVC

    func test_skipsAlreadyHEVC() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/already_hevc.mp4", size: 100_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["already_hevc.mp4"]

        let inspector = MockAssetInspector()
        inspector.codecs["/source/already_hevc.mp4"] = [kCMVideoCodecType_HEVC]

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: makeConfig()
        )

        XCTAssertEqual(result.pending.count, 0)
        XCTAssertEqual(result.skipCounts[.alreadyHEVC], 1)
    }

    // MARK: - test_skipsBelowMinSize

    func test_skipsBelowMinSize() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/tiny.mp4", size: 1_000_000) // 1 MB

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["tiny.mp4"]

        let inspector = MockAssetInspector()
        inspector.codecs["/source/tiny.mp4"] = [kCMVideoCodecType_H264]

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let config = makeConfig(minSize: 50_000_000) // 50 MB minimum
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: config
        )

        XCTAssertEqual(result.pending.count, 0)
        XCTAssertEqual(result.skipCounts[.tooSmall], 1)
    }

    // MARK: - test_skipsAlreadyDoneInState

    func test_skipsAlreadyDoneInState() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/done.mp4", size: 200_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["done.mp4"]

        let inspector = MockAssetInspector()
        inspector.codecs["/source/done.mp4"] = [kCMVideoCodecType_H264]

        var state = StateFile()
        state.files["done.mp4"] = StateFileEntry(
            status: .completed,
            preset: "hevc_highest_quality",
            sourceSize: 200_000_000
        )

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL,
            config: makeConfig(), state: state
        )

        XCTAssertEqual(result.pending.count, 0)
        XCTAssertEqual(result.skipCounts[.alreadyDone], 1)
    }

    // MARK: - test_pendingWhenPresetMismatch

    func test_pendingWhenPresetMismatch() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/mismatch.mp4", size: 200_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["mismatch.mp4"]

        let inspector = MockAssetInspector()
        inspector.codecs["/source/mismatch.mp4"] = [kCMVideoCodecType_H264]

        var state = StateFile()
        state.files["mismatch.mp4"] = StateFileEntry(
            status: .completed,
            preset: "hevc_highest_quality",
            sourceSize: 200_000_000
        )

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        // Current run uses lossless preset, but state has lossy.
        let config = makeConfig(preset: "hevc_lossless")
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL,
            config: config, state: state
        )

        XCTAssertEqual(result.pending.count, 1)
        XCTAssertEqual(result.pending.first?.relativePath, "mismatch.mp4")
        XCTAssertNil(result.skipCounts[.alreadyDone])
    }

    // MARK: - test_pendingForNormalH264File

    func test_pendingForNormalH264File() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/trip/clip.mp4", size: 500_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["clip.mp4"]

        let inspector = MockAssetInspector()
        inspector.codecs["/source/trip/clip.mp4"] = [kCMVideoCodecType_H264]

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: makeConfig()
        )

        XCTAssertEqual(result.pending.count, 1)
        let entry = result.pending[0]
        XCTAssertEqual(entry.sourcePath, "/source/trip/clip.mp4")
        XCTAssertEqual(entry.relativePath, "trip/clip.mp4")
        XCTAssertEqual(entry.destPath, "/dest/trip/clip.mp4")
        XCTAssertEqual(entry.fileSize, 500_000_000)
        XCTAssertEqual(entry.sourceContainer, "mp4")
    }

    // MARK: - test_containerMapping_mov

    func test_containerMapping_mov() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/video.mov", size: 100_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["video.mov"]

        let inspector = MockAssetInspector()
        inspector.codecs["/source/video.mov"] = [kCMVideoCodecType_H264]

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: makeConfig()
        )

        XCTAssertEqual(result.pending.count, 1)
        XCTAssertEqual(result.pending[0].sourceContainer, "mov")
    }

    // MARK: - test_containerMapping_m4v

    func test_containerMapping_m4v() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/video.m4v", size: 100_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["video.m4v"]

        let inspector = MockAssetInspector()
        inspector.codecs["/source/video.m4v"] = [kCMVideoCodecType_H264]

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: makeConfig()
        )

        XCTAssertEqual(result.pending.count, 1)
        XCTAssertEqual(result.pending[0].sourceContainer, "m4v")
    }

    // MARK: - test_skipsUnsupportedContainers

    func test_skipsUnsupportedContainers() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/video.avi", size: 100_000_000)
        fs.addFile(path: "/source/video.mkv", size: 200_000_000)
        fs.addFile(path: "/source/video.mts", size: 150_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["video.avi", "video.mkv", "video.mts"]

        let inspector = MockAssetInspector()
        // Inspector should not be called for unsupported containers.

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: makeConfig()
        )

        XCTAssertEqual(result.pending.count, 0)
        XCTAssertEqual(result.skipCounts[.unsupportedContainer], 3)
        XCTAssertEqual(result.warnings.count, 3)
    }

    // MARK: - test_skipsHiddenFiles

    func test_skipsHiddenFiles() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/.hidden_video.mp4", size: 100_000_000)
        fs.addFile(path: "/source/.DS_Store", size: 4_096)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = [".hidden_video.mp4"]

        let inspector = MockAssetInspector()

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: makeConfig()
        )

        XCTAssertEqual(result.pending.count, 0)
        XCTAssertEqual(result.totalScanned, 0)
        // Hidden files should not be counted at all.
        XCTAssertTrue(result.skipCounts.isEmpty)
    }

    // MARK: - test_skipsSymlinks

    func test_skipsSymlinks() async throws {
        let fs = MockFileSystem()
        fs.addFile(
            path: "/source/link.mp4",
            size: 100_000_000,
            attributes: [.type: FileAttributeType.typeSymbolicLink]
        )

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["link.mp4"]

        let inspector = MockAssetInspector()

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: makeConfig()
        )

        XCTAssertEqual(result.pending.count, 0)
        XCTAssertEqual(result.totalScanned, 0)
    }

    // MARK: - test_freshFlag_ignoresCompletedState

    func test_freshFlag_ignoresCompletedState() async throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/source/done.mp4", size: 200_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = ["done.mp4"]

        let inspector = MockAssetInspector()
        inspector.codecs["/source/done.mp4"] = [kCMVideoCodecType_H264]

        var state = StateFile()
        state.files["done.mp4"] = StateFileEntry(
            status: .completed,
            preset: "hevc_highest_quality",
            sourceSize: 200_000_000
        )

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        // With fresh=true, completed state entries should be ignored -> file is pending.
        let config = makeConfig(fresh: true)
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL,
            config: config, state: state
        )

        XCTAssertEqual(result.pending.count, 1,
            "With --fresh, completed state should be ignored and file should be pending")
        XCTAssertNil(result.skipCounts[.alreadyDone],
            "With --fresh, nothing should be skipped as alreadyDone")
    }

    // MARK: - test_multipleFiles_correctCounts

    func test_multipleFiles_correctCounts() async throws {
        let fs = MockFileSystem()
        // 1. A normal H.264 file -> pending
        fs.addFile(path: "/source/h264.mp4", size: 500_000_000)
        // 2. A non-video file -> skip(notVideo)
        fs.addFile(path: "/source/photo.jpg", size: 5_000_000)
        // 3. An HEVC file -> skip(alreadyHEVC)
        fs.addFile(path: "/source/hevc.mp4", size: 300_000_000)
        // 4. An audio-only mov -> skip(noVideoTrack)
        fs.addFile(path: "/source/audio.mov", size: 50_000_000)
        // 5. A tiny file below min-size -> skip(tooSmall)
        fs.addFile(path: "/source/tiny.mp4", size: 1_000)
        // 6. An unsupported container -> skip(unsupportedContainer)
        fs.addFile(path: "/source/video.avi", size: 200_000_000)
        // 7. A hidden file -> not counted
        fs.addFile(path: "/source/.hidden.mp4", size: 100_000_000)

        let typeID = MockFileTypeIdentifier()
        typeID.movieFiles = [
            "h264.mp4", "hevc.mp4", "audio.mov", "tiny.mp4", "video.avi"
        ]
        // photo.jpg is not in movieFiles, so isMovie returns false.

        let inspector = MockAssetInspector()
        inspector.codecs["/source/h264.mp4"] = [kCMVideoCodecType_H264]
        inspector.codecs["/source/hevc.mp4"] = [kCMVideoCodecType_HEVC]
        inspector.codecs["/source/audio.mov"] = []
        inspector.codecs["/source/tiny.mp4"] = [kCMVideoCodecType_H264]

        let scanner = Scanner(fs: fs, inspector: inspector, typeID: typeID)
        let config = makeConfig(minSize: 10_000) // 10 KB min
        let result = try await scanner.scan(
            source: sourceURL, dest: destURL, config: config
        )

        // Only h264.mp4 should be pending.
        XCTAssertEqual(result.pending.count, 1)
        XCTAssertEqual(result.pending[0].relativePath, "h264.mp4")

        // Skip counts.
        XCTAssertEqual(result.skipCounts[.notVideo], 1)        // photo.jpg
        XCTAssertEqual(result.skipCounts[.alreadyHEVC], 1)     // hevc.mp4
        XCTAssertEqual(result.skipCounts[.noVideoTrack], 1)    // audio.mov
        XCTAssertEqual(result.skipCounts[.tooSmall], 1)        // tiny.mp4
        XCTAssertEqual(result.skipCounts[.unsupportedContainer], 1) // video.avi

        // Total scanned excludes the hidden file.
        XCTAssertEqual(result.totalScanned, 6)
    }
}
