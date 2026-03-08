import XCTest
import AVFoundation
@testable import vcompress

final class EncoderTests: XCTestCase {

    // MARK: - Helpers

    /// Create a standard FileEntry for testing.
    private func makeEntry(
        sourcePath: String = "/source/video.mov",
        relativePath: String = "video.mov",
        destPath: String = "/dest/video.mov",
        fileSize: Int64 = 100_000_000,
        sourceContainer: String = "mov"
    ) -> FileEntry {
        FileEntry(
            sourcePath: sourcePath,
            relativePath: relativePath,
            destPath: destPath,
            fileSize: fileSize,
            sourceContainer: sourceContainer
        )
    }

    /// Create a MockExportSessionFactory that does not write to the real filesystem.
    /// All file state is managed through MockFileSystem instead.
    private func makeFactory(result: MockExportSessionFactory.MockResult = .success) -> MockExportSessionFactory {
        let factory = MockExportSessionFactory(result: result)
        factory.writeDummyOutput = false
        return factory
    }

    // MARK: - test_successfulEncode_movesToFinalPath

    func test_successfulEncode_movesToFinalPath() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry()

        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 1024)
        inspector.playability[entry.destPath] = true

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)
        try await encoder.encode(entry, quality: .standard)

        // Verify: tmp file was moved to final path
        XCTAssertEqual(fs.movedItems.count, 1)
        XCTAssert(fs.movedItems[0].from.path.hasSuffix(".tmp"))
        XCTAssertEqual(fs.movedItems[0].to.path, entry.destPath)
    }

    // MARK: - test_failedExport_deletesPartialOutput_throws

    func test_failedExport_deletesPartialOutput_throws() async throws {
        let fs = MockFileSystem()
        let exportError = NSError(domain: "test", code: 42, userInfo: nil)
        let factory = makeFactory(result: .failure(exportError))
        let inspector = MockAssetInspector()
        let entry = makeEntry()

        // Add the tmp file so cleanup can find it
        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 512)

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)

        do {
            try await encoder.encode(entry, quality: .standard)
            XCTFail("Expected encode to throw")
        } catch {
            // Verify tmp file was cleaned up
            XCTAssertEqual(fs.removedItems.count, 1)
            XCTAssert(fs.removedItems[0].path.hasSuffix(".tmp"))
        }
    }

    // MARK: - test_outputValidation_zeroBytesFile_throws

    func test_outputValidation_zeroBytesFile_throws() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry()

        // Tmp file exists but with 0 bytes
        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 0)

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)

        do {
            try await encoder.encode(entry, quality: .standard)
            XCTFail("Expected encode to throw for zero-byte file")
        } catch let error as EncodingError {
            if case .outputValidation(let msg) = error {
                XCTAssert(msg.contains("zero bytes"), "Expected zero bytes message, got: \(msg)")
            } else {
                XCTFail("Expected outputValidation error, got: \(error)")
            }
        }

        // Verify tmp file was cleaned up
        XCTAssertEqual(fs.removedItems.count, 1)
    }

    // MARK: - test_outputValidation_notPlayable_deletesOutput

    func test_outputValidation_notPlayable_deletesOutput() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry()

        // Tmp file exists with data but output is not playable after move
        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 1024)
        inspector.playability[entry.destPath] = false

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)

        do {
            try await encoder.encode(entry, quality: .standard)
            XCTFail("Expected encode to throw for non-playable output")
        } catch let error as EncodingError {
            if case .outputValidation(let msg) = error {
                XCTAssert(msg.contains("not playable"), "Expected not playable message, got: \(msg)")
            } else {
                XCTFail("Expected outputValidation error, got: \(error)")
            }
        }

        // Verify dest file was cleaned up (playability check happens after move)
        XCTAssertTrue(fs.removedItems.contains(where: { $0.path == entry.destPath }))
    }

    // MARK: - test_movContainer_usesMovFileType

    func test_movContainer_usesMovFileType() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry(sourceContainer: "mov")

        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 1024)
        inspector.playability[entry.destPath] = true

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)
        try await encoder.encode(entry, quality: .standard)

        XCTAssertEqual(factory.exportCalls.count, 1)
        XCTAssertEqual(factory.exportCalls[0].fileType, .mov)
    }

    // MARK: - test_mp4Container_usesMp4FileType

    func test_mp4Container_usesMp4FileType() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry(
            sourcePath: "/source/video.mp4",
            destPath: "/dest/video.mp4",
            sourceContainer: "mp4"
        )

        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 1024)
        inspector.playability[entry.destPath] = true

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)
        try await encoder.encode(entry, quality: .standard)

        XCTAssertEqual(factory.exportCalls.count, 1)
        XCTAssertEqual(factory.exportCalls[0].fileType, .mp4)
    }

    // MARK: - test_m4vContainer_usesMp4FileType_preservesExtension

    func test_m4vContainer_usesMp4FileType_preservesExtension() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry(
            sourcePath: "/source/video.m4v",
            destPath: "/dest/video.m4v",
            sourceContainer: "m4v"
        )

        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 1024)
        inspector.playability[entry.destPath] = true

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)
        try await encoder.encode(entry, quality: .standard)

        XCTAssertEqual(factory.exportCalls.count, 1)
        // m4v uses AVFileType.mp4 internally
        XCTAssertEqual(factory.exportCalls[0].fileType, .mp4)
        // But the output path preserves the .m4v extension
        XCTAssert(fs.movedItems[0].to.path.hasSuffix(".m4v"))
    }

    // MARK: - test_parentDirectoriesCreated

    func test_parentDirectoriesCreated() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry(
            destPath: "/dest/subdir/nested/video.mov"
        )

        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 1024)
        inspector.playability[entry.destPath] = true

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)
        try await encoder.encode(entry, quality: .standard)

        // Verify createDirectory was called for the parent directory
        XCTAssertEqual(fs.createdDirectories.count, 1)
        XCTAssertEqual(fs.createdDirectories[0].path, "/dest/subdir/nested")
    }

    // MARK: - test_standardQuality_passesCorrectQuality

    func test_standardQuality_passesCorrectQuality() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry()

        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 1024)
        inspector.playability[entry.destPath] = true

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)
        try await encoder.encode(entry, quality: .standard)

        XCTAssertEqual(factory.exportCalls.count, 1)
        XCTAssertEqual(factory.exportCalls[0].quality, .standard)
    }

    // MARK: - test_highQuality_passesCorrectQuality

    func test_highQuality_passesCorrectQuality() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry()

        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 1024)
        inspector.playability[entry.destPath] = true

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)
        try await encoder.encode(entry, quality: .high)

        XCTAssertEqual(factory.exportCalls.count, 1)
        XCTAssertEqual(factory.exportCalls[0].quality, .high)
    }

    // MARK: - test_maxQuality_passesCorrectQuality

    func test_maxQuality_passesCorrectQuality() async throws {
        let fs = MockFileSystem()
        let factory = makeFactory()
        let inspector = MockAssetInspector()
        let entry = makeEntry()

        let tmpPath = entry.destPath + ".tmp"
        fs.addFile(path: tmpPath, size: 1024)
        inspector.playability[entry.destPath] = true

        let encoder = Encoder(factory: factory, fs: fs, inspector: inspector)
        try await encoder.encode(entry, quality: .max)

        XCTAssertEqual(factory.exportCalls.count, 1)
        XCTAssertEqual(factory.exportCalls[0].quality, .max)
    }
}
