import XCTest
@testable import vcompress

final class MetadataCopierTests: XCTestCase {

    // MARK: - test_copiesCreationDate

    func test_copiesCreationDate() throws {
        let fs = MockFileSystem()
        let srcDate = Date(timeIntervalSince1970: 1_700_000_000)
        fs.addFile(path: "/src.mov", attributes: [.creationDate: srcDate])
        fs.addFile(path: "/dst.mov")

        let copier = MetadataCopier(fs: fs, clock: MockClock())
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

        let copier = MetadataCopier(fs: fs, clock: MockClock())
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

        let copier = MetadataCopier(fs: fs, clock: MockClock())
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

        let copier = MetadataCopier(fs: fs, clock: MockClock())
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

        let copier = MetadataCopier(fs: fs, clock: MockClock())
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

        let copier = MetadataCopier(fs: fs, clock: MockClock())
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

    // MARK: - stampVcompress tests

    func test_stampVcompress_addsFinderTag() throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/dst.mov")

        let copier = MetadataCopier(fs: fs, clock: MockClock())
        try copier.stampVcompress(
            atPath: "/dst.mov",
            quality: .high,
            preset: "hevc_high",
            originalSize: 1_000_000,
            compressedSize: 100_000
        )

        // Read back the Finder tags plist.
        let xattrName = "com.apple.metadata:_kMDItemUserTags"
        let tagData = try fs.getExtendedAttribute(xattrName, atPath: "/dst.mov")
        let tags = try PropertyListSerialization.propertyList(
            from: tagData, options: [], format: nil
        ) as! [String]
        XCTAssertEqual(tags, ["vcompress:high:0.65\n0"])
    }

    func test_stampVcompress_preservesExistingFinderTags() throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/dst.mov")

        // Pre-populate with an existing tag (simulating tags copied from source).
        let existingTags = ["Red\n6"]
        let existingPlist = try PropertyListSerialization.data(
            fromPropertyList: existingTags, format: .binary, options: 0
        )
        let xattrName = "com.apple.metadata:_kMDItemUserTags"
        fs.xattrs["/dst.mov"] = [xattrName: existingPlist]

        let copier = MetadataCopier(fs: fs, clock: MockClock())
        try copier.stampVcompress(
            atPath: "/dst.mov",
            quality: .standard,
            preset: "hevc_standard",
            originalSize: 500_000,
            compressedSize: 50_000
        )

        let tagData = try fs.getExtendedAttribute(xattrName, atPath: "/dst.mov")
        let tags = try PropertyListSerialization.propertyList(
            from: tagData, options: [], format: nil
        ) as! [String]
        XCTAssertEqual(tags, ["Red\n6", "vcompress:standard:preset\n0"])
    }

    func test_stampVcompress_writesCustomXattr() throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/dst.mov")

        let clock = MockClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let copier = MetadataCopier(fs: fs, clock: clock)
        try copier.stampVcompress(
            atPath: "/dst.mov",
            quality: .max,
            preset: "hevc_max",
            originalSize: 1_000_000,
            compressedSize: 250_000
        )

        let xattrData = try fs.getExtendedAttribute(
            MetadataCopier.vcompressXattr, atPath: "/dst.mov"
        )
        let json = try JSONSerialization.jsonObject(with: xattrData) as! [String: Any]
        XCTAssertEqual(json["tool"] as? String, "vcompress")
        XCTAssertEqual(json["preset"] as? String, "hevc_max")
        XCTAssertEqual(json["quality"] as? String, "0.75")
        XCTAssertEqual(json["originalSize"] as? Int, 1_000_000)
        XCTAssertEqual(json["compressedSize"] as? Int, 250_000)
        XCTAssertEqual(json["ratio"] as? Double, 0.25)
        XCTAssertEqual(json["compressedAt"] as? String, "2023-11-14T22:13:20Z")
    }

    func test_stampVcompress_standardQuality() throws {
        let fs = MockFileSystem()
        fs.addFile(path: "/dst.mov")

        let copier = MetadataCopier(fs: fs, clock: MockClock())
        try copier.stampVcompress(
            atPath: "/dst.mov",
            quality: .standard,
            preset: "hevc_standard",
            originalSize: 2_000_000,
            compressedSize: 200_000
        )

        // Verify Finder tag uses "preset" as quality value.
        let xattrName = "com.apple.metadata:_kMDItemUserTags"
        let tagData = try fs.getExtendedAttribute(xattrName, atPath: "/dst.mov")
        let tags = try PropertyListSerialization.propertyList(
            from: tagData, options: [], format: nil
        ) as! [String]
        XCTAssertEqual(tags, ["vcompress:standard:preset\n0"])

        // Verify xattr JSON quality field.
        let xattrJsonData = try fs.getExtendedAttribute(
            MetadataCopier.vcompressXattr, atPath: "/dst.mov"
        )
        let json = try JSONSerialization.jsonObject(with: xattrJsonData) as! [String: Any]
        XCTAssertEqual(json["quality"] as? String, "preset")
        XCTAssertEqual(json["ratio"] as? Double, 0.1)
    }
}
