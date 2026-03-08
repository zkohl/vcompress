import Foundation

/// Copies filesystem metadata (timestamps, Finder tags) from a source file
/// to a destination file after encoding. All operations are graceful: if an
/// attribute is missing on the source, a warning is logged and the copy
/// continues without throwing.
struct MetadataCopier {
    let fs: FileSystemProvider

    /// The xattr key used by macOS Finder for user tags.
    private static let finderTagsXattr = "com.apple.metadata:_kMDItemUserTags"

    /// Copy creation date, modification date, and Finder tags from source to dest.
    ///
    /// Missing metadata is logged and skipped. Only actual I/O errors that
    /// prevent the copy from proceeding are thrown.
    func copy(from source: String, to dest: String) throws {
        let sourceAttrs: [FileAttributeKey: Any]
        do {
            sourceAttrs = try fs.attributesOfItem(atPath: source)
        } catch {
            throw error
        }

        // --- Creation date ---
        if let creationDate = sourceAttrs[.creationDate] as? Date {
            do {
                try fs.setAttributes([.creationDate: creationDate], ofItemAtPath: dest)
            } catch {
                throw error
            }
        } else {
            logWarning("Creation date missing on source: \(source)")
        }

        // --- Modification date ---
        if let modDate = sourceAttrs[.modificationDate] as? Date {
            do {
                try fs.setAttributes([.modificationDate: modDate], ofItemAtPath: dest)
            } catch {
                throw error
            }
        } else {
            logWarning("Modification date missing on source: \(source)")
        }

        // --- Finder tags (xattr) ---
        do {
            let tagData = try fs.getExtendedAttribute(
                Self.finderTagsXattr, atPath: source
            )
            try fs.setExtendedAttribute(
                Self.finderTagsXattr, data: tagData, atPath: dest
            )
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOATTR)
        {
            logWarning("Finder tags not present on source: \(source)")
        } catch {
            throw error
        }
    }

    /// Log a warning to stderr. In a full build this could route through a
    /// shared logging subsystem; for now, a simple fputs suffices.
    private func logWarning(_ message: String) {
        fputs("warning: \(message)\n", stderr)
    }
}
