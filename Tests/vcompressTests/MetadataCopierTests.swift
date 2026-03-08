import XCTest
@testable import vcompress

final class MetadataCopierTests: XCTestCase {

    // MARK: - test_copiesCreationDate

    func test_copiesCreationDate() throws {
        let fs = MockFileSystem()
        let srcDate = Date(timeIntervalSince1970: 1_700_000_000)
        fs.addFile(path: "/src.mov", attributes: [.creationDate: srcDate])
        fs.addFile(path: "/dst.mov")

        let copier = MetadataCopier(fs: fs)
        try copier.copy(from: "/src.mov", to: "/dst.mov")

        let dstAttrs = try fs.attributesOfItem(atPath: "/dst.mov")
        XCTAssertEqual(dstAttrs[.creationDate] as? Date, srcDate)
    }

    // MARK: - test_copiesModificationDate

    func test_copiesModificationDate() throws {
        let fs = MockFileSystem()
        let modDate = Date(timeIntervalSince1970: 1_700_100_000)
        fs.addFile(path: "/src.mov", attributes: [.modificationDate: modDate])
        fs.addFile(path: "/dst.mov")

        let copier = MetadataCopier(fs: fs)
        try copier.copy(from: "/src.mov", to: "/dst.mov")

        let dstAttrs = try fs.attributesOfItem(atPath: "/dst.mov")
        XCTAssertEqual(dstAttrs[.modificationDate] as? Date, modDate)
    }

    // MARK: - test_missingCreationDate_logsWarning_doesNotThrow

    func test_missingCreationDate_logsWarning_doesNotThrow() throws {
        let fs = MockFileSystem()
        // Source has a modification date but NO creation date.
        let modDate = Date(timeIntervalSince1970: 1_700_100_000)
        fs.addFile(path: "/src.mov", attributes: [.modificationDate: modDate])
        fs.addFile(path: "/dst.mov")

        let copier = MetadataCopier(fs: fs)
        // Must not throw.
        XCTAssertNoThrow(try copier.copy(from: "/src.mov", to: "/dst.mov"))

        // Modification date should still have been copied.
        let dstAttrs = try fs.attributesOfItem(atPath: "/dst.mov")
        XCTAssertEqual(dstAttrs[.modificationDate] as? Date, modDate)
        // Creation date should not appear on dest (was missing on source).
        XCTAssertNil(dstAttrs[.creationDate] as? Date)
    }

    // MARK: - test_copiesFinderTags_xattr

    func test_copiesFinderTags_xattr() throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/src.mov")
        fs.addFile(path: "/dst.mov")

        // Simulate a Finder tag xattr on the source.
        let tagData = Data("bplist-fake-tag-data".utf8)
        let xattrName = "com.apple.metadata:_kMDItemUserTags"
        fs.xattrs["/src.mov"] = [xattrName: tagData]

        let copier = MetadataCopier(fs: fs)
        try copier.copy(from: "/src.mov", to: "/dst.mov")

        // Verify the xattr was copied to the destination.
        let destTagData = try fs.getExtendedAttribute(xattrName, atPath: "/dst.mov")
        XCTAssertEqual(destTagData, tagData)
    }

    // MARK: - test_missingFinderTags_skipsGracefully

    func test_missingFinderTags_skipsGracefully() throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/src.mov")
        fs.addFile(path: "/dst.mov")
        // No xattrs set on source.

        let copier = MetadataCopier(fs: fs)
        // Must not throw.
        XCTAssertNoThrow(try copier.copy(from: "/src.mov", to: "/dst.mov"))

        // Dest should have no xattrs.
        XCTAssertNil(fs.xattrs["/dst.mov"])
    }

    // MARK: - test_copiesBothDatesAndTags

    func test_copiesBothDatesAndTags() throws {
        let fs = MockFileSystem()
        let creationDate = Date(timeIntervalSince1970: 1_600_000_000)
        let modDate = Date(timeIntervalSince1970: 1_700_000_000)
        fs.addFile(path: "/src.mov", attributes: [
            .creationDate: creationDate,
            .modificationDate: modDate,
        ])
        fs.addFile(path: "/dst.mov")

        let xattrName = "com.apple.metadata:_kMDItemUserTags"
        let tagData = Data("bplist-red-tag".utf8)
        fs.xattrs["/src.mov"] = [xattrName: tagData]

        let copier = MetadataCopier(fs: fs)
        try copier.copy(from: "/src.mov", to: "/dst.mov")

        // Verify creation date.
        let dstAttrs = try fs.attributesOfItem(atPath: "/dst.mov")
        XCTAssertEqual(dstAttrs[.creationDate] as? Date, creationDate)

        // Verify modification date.
        XCTAssertEqual(dstAttrs[.modificationDate] as? Date, modDate)

        // Verify Finder tags.
        let destTagData = try fs.getExtendedAttribute(xattrName, atPath: "/dst.mov")
        XCTAssertEqual(destTagData, tagData)
    }
}
