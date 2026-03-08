import Foundation
@testable import vcompress

/// Mock xattr and metadata helpers for testing MetadataCopier.
/// This supplements MockFileSystem with convenient metadata setup methods.
final class MockMetadataProvider {

    let fs: MockFileSystem

    init(fs: MockFileSystem) {
        self.fs = fs
    }

    /// Set up a file with standard metadata attributes for testing.
    func addFileWithMetadata(
        path: String,
        size: Int64 = 1_000_000,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        finderTags: Data? = nil
    ) {
        var attrs: [FileAttributeKey: Any] = [:]
        attrs[.size] = size
        if let creationDate = creationDate {
            attrs[.creationDate] = creationDate
        }
        if let modificationDate = modificationDate {
            attrs[.modificationDate] = modificationDate
        }

        fs.addFile(path: path, size: size, attributes: attrs)

        if let finderTags = finderTags {
            fs.xattrs[path] = ["com.apple.metadata:_kMDItemUserTags": finderTags]
        }
    }

    /// Retrieve the Finder tags xattr from a path in the mock filesystem.
    func finderTags(atPath path: String) -> Data? {
        fs.xattrs[path]?["com.apple.metadata:_kMDItemUserTags"]
    }
}
