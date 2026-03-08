import Foundation

/// Copies filesystem metadata (timestamps, Finder tags) from a source file
/// to a destination file after encoding. All operations are graceful: if an
/// attribute is missing on the source, a warning is logged and the copy
/// continues without throwing.
struct MetadataCopier {
    let fs: FileSystemProvider
    let clock: Clock

    /// The xattr key used by macOS Finder for user tags.
    private static let finderTagsXattr = "com.apple.metadata:_kMDItemUserTags"

    /// The xattr key for vcompress encoding metadata.
    static let vcompressXattr = "com.vcompress.metadata"

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

    /// Stamp the output file with vcompress encoding metadata.
    ///
    /// Adds a Finder tag (e.g. `vcompress:high:0.65`) and a custom xattr
    /// with full encoding details as JSON.
    func stampVcompress(
        atPath path: String,
        quality: Quality,
        preset: String,
        originalSize: Int64,
        compressedSize: Int64
    ) throws {
        let qualityValue: String
        if let q = quality.compressionQuality {
            qualityValue = "\(q)"
        } else {
            qualityValue = "preset"
        }

        // --- Finder tag ---
        let tagName = "vcompress:\(quality.rawValue):\(qualityValue)"
        try addFinderTag(tagName, atPath: path)

        // --- Custom xattr (JSON) ---
        let ratio = originalSize > 0
            ? Double(compressedSize) / Double(originalSize)
            : 0.0
        let roundedRatio = (ratio * 100).rounded() / 100

        let formatter = ISO8601DateFormatter()
        let metadata: [String: Any] = [
            "tool": "vcompress",
            "preset": preset,
            "quality": qualityValue,
            "originalSize": originalSize,
            "compressedSize": compressedSize,
            "ratio": NSDecimalNumber(value: roundedRatio),
            "compressedAt": formatter.string(from: clock.now()),
        ]
        let jsonData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.sortedKeys]
        )
        try fs.setExtendedAttribute(Self.vcompressXattr, data: jsonData, atPath: path)
    }

    /// Add a Finder tag to a file, preserving any existing tags.
    private func addFinderTag(_ tag: String, atPath path: String) throws {
        var tags: [String] = []

        // Read existing tags if present.
        do {
            let existingData = try fs.getExtendedAttribute(
                Self.finderTagsXattr, atPath: path
            )
            if let plist = try PropertyListSerialization.propertyList(
                from: existingData, options: [], format: nil
            ) as? [String] {
                tags = plist
            }
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOATTR)
        {
            // No existing tags — start fresh.
        }

        // Append the new tag (with color code 0 = no color).
        tags.append("\(tag)\n0")

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: tags, format: .binary, options: 0
        )
        try fs.setExtendedAttribute(Self.finderTagsXattr, data: plistData, atPath: path)
    }

    /// Log a warning to stderr. In a full build this could route through a
    /// shared logging subsystem; for now, a simple fputs suffices.
    private func logWarning(_ message: String) {
        fputs("warning: \(message)\n", stderr)
    }
}
