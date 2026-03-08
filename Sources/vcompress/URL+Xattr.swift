import Foundation

/// Convenience extensions on URL for reading and writing POSIX extended
/// attributes (xattrs) using the `fgetxattr` / `fsetxattr` C API.
/// These are used by `RealFileSystem` (the production `FileSystemProvider`)
/// to support Finder tag copying.
extension URL {

    /// Read the raw bytes of the named extended attribute.
    ///
    /// - Parameter name: The xattr name, e.g. `"com.apple.metadata:_kMDItemUserTags"`.
    /// - Returns: The raw attribute data.
    /// - Throws: A POSIX error if the attribute does not exist or cannot be read.
    func getExtendedAttribute(_ name: String) throws -> Data {
        let path = self.path
        // First call: determine the size of the attribute value.
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }

        // Second call: read the data.
        var buffer = Data(count: size)
        let result = buffer.withUnsafeMutableBytes { ptr -> Int in
            getxattr(path, name, ptr.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard result >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }

        return buffer
    }

    /// Write raw bytes as the named extended attribute, replacing any
    /// existing value.
    ///
    /// - Parameters:
    ///   - name: The xattr name.
    ///   - data: The raw bytes to write.
    /// - Throws: A POSIX error if the attribute cannot be written.
    func setExtendedAttribute(_ name: String, data: Data) throws {
        let path = self.path
        let result = data.withUnsafeBytes { ptr -> Int32 in
            setxattr(
                path, name,
                ptr.baseAddress, data.count,
                0, XATTR_NOFOLLOW
            )
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
    }
}
