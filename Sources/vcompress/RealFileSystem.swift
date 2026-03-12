import Foundation

/// Production FileSystemProvider wrapping FileManager and POSIX xattr functions.
struct RealFileSystem: FileSystemProvider {

    private let fm = FileManager.default

    func enumerateFiles(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]
    ) throws -> [(url: URL, relativePath: String)] {
        var allKeys = keys
        // Always include isDirectory so we can skip directories
        if !allKeys.contains(.isDirectoryKey) {
            allKeys.append(.isDirectoryKey)
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: allKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        let basePath = url.standardizedFileURL.path
        var results: [(url: URL, relativePath: String)] = []

        for case let fileURL as URL in enumerator {
            // Skip directories
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory == true {
                continue
            }

            let filePath = fileURL.standardizedFileURL.path
            var relative = filePath
            if filePath.hasPrefix(basePath) {
                relative = String(filePath.dropFirst(basePath.count))
                if relative.hasPrefix("/") {
                    relative = String(relative.dropFirst())
                }
            }

            results.append((url: fileURL, relativePath: relative))
        }

        return results
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try fm.attributesOfItem(atPath: path)
    }

    func setAttributes(
        _ attrs: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        try fm.setAttributes(attrs, ofItemAtPath: path)
    }

    func fileExists(atPath path: String) -> Bool {
        fm.fileExists(atPath: path)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories: Bool
    ) throws {
        try fm.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func contents(atPath path: String) -> Data? {
        fm.contents(atPath: path)
    }

    func write(_ data: Data, to url: URL, atomically: Bool) throws {
        if atomically {
            try data.write(to: url, options: .atomic)
        } else {
            try data.write(to: url)
        }
    }

    func removeItem(at url: URL) throws {
        try fm.removeItem(at: url)
    }

    func moveItem(at src: URL, to dst: URL) throws {
        try fm.moveItem(at: src, to: dst)
    }

    func copyItem(at src: URL, to dst: URL) throws {
        try fm.copyItem(at: src, to: dst)
    }

    func getExtendedAttribute(
        _ name: String,
        atPath path: String
    ) throws -> Data {
        try URL(fileURLWithPath: path).getExtendedAttribute(name)
    }

    func setExtendedAttribute(
        _ name: String,
        data: Data,
        atPath path: String
    ) throws {
        try URL(fileURLWithPath: path).setExtendedAttribute(name, data: data)
    }

    func availableSpace(atPath path: String) throws -> Int64 {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let capacity = values.volumeAvailableCapacity else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        return Int64(capacity)
    }

    func glob(pattern: String, inDirectory dir: URL) throws -> [URL] {
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var matches: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasSuffix(
                String(pattern.dropFirst())  // Drop the "*" from "*.tmp"
            ) {
                matches.append(fileURL)
            }
        }
        return matches
    }
}
