import Foundation
@testable import vcompress

/// A mock filesystem backed by an in-memory dictionary.
/// Tests build a virtual file tree, then run Scanner/StateManager against it.
final class MockFileSystem: FileSystemProvider {

    /// In-memory file store: path -> (attributes, data)
    var files: [String: (attributes: [FileAttributeKey: Any], data: Data?)] = [:]

    /// Known directories.
    var directories: Set<String> = []

    /// Extended attributes store: path -> (name -> data)
    var xattrs: [String: [String: Data]] = [:]

    // MARK: - Call tracking for assertions

    var writtenFiles: [(url: URL, data: Data, atomically: Bool)] = []
    var removedItems: [URL] = []
    var movedItems: [(from: URL, to: URL)] = []
    var createdDirectories: [URL] = []
    var setAttributesCalls: [(attrs: [FileAttributeKey: Any], path: String)] = []

    // MARK: - Configurable behavior

    var availableDiskSpace: Int64 = 500_000_000_000 // 500 GB default
    var globResults: [String: [URL]] = [:]

    /// Error to throw on specific operations, keyed by path.
    var errorOnWrite: [String: Error] = [:]
    var errorOnRead: [String: Error] = [:]
    var errorOnRemove: [String: Error] = [:]
    var errorOnMove: [String: Error] = [:]

    // MARK: - Helper methods

    /// Add a file to the in-memory filesystem.
    func addFile(
        path: String,
        size: Int64 = 0,
        attributes: [FileAttributeKey: Any] = [:],
        data: Data? = nil
    ) {
        var attrs = attributes
        attrs[.size] = size
        files[path] = (attributes: attrs, data: data)

        // Ensure parent directories exist.
        let url = URL(fileURLWithPath: path)
        var parent = url.deletingLastPathComponent().path
        while parent != "/" && !parent.isEmpty {
            directories.insert(parent)
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
    }

    /// Add a directory to the in-memory filesystem.
    func addDirectory(path: String) {
        directories.insert(path)
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != "/" && !parent.isEmpty {
            directories.insert(parent)
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
    }

    // MARK: - FileSystemProvider

    func enumerateFiles(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]
    ) throws -> [(url: URL, relativePath: String)] {
        let basePath = url.path
        var results: [(url: URL, relativePath: String)] = []

        for filePath in files.keys.sorted() {
            guard filePath.hasPrefix(basePath) else { continue }
            let relative = String(filePath.dropFirst(basePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            results.append((url: URL(fileURLWithPath: filePath), relativePath: relative))
        }

        return results
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if let error = errorOnRead[path] {
            throw error
        }
        guard let entry = files[path] else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadNoSuchFileError,
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        return entry.attributes
    }

    func setAttributes(
        _ attrs: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        guard files[path] != nil else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadNoSuchFileError,
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        setAttributesCalls.append((attrs: attrs, path: path))
        for (key, value) in attrs {
            files[path]!.attributes[key] = value
        }
    }

    func fileExists(atPath path: String) -> Bool {
        files[path] != nil || directories.contains(path)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories: Bool
    ) throws {
        createdDirectories.append(url)
        addDirectory(path: url.path)
    }

    func contents(atPath path: String) -> Data? {
        files[path]?.data
    }

    func write(_ data: Data, to url: URL, atomically: Bool) throws {
        let path = url.path
        if let error = errorOnWrite[path] {
            throw error
        }
        writtenFiles.append((url: url, data: data, atomically: atomically))
        if files[path] != nil {
            files[path]!.data = data
        } else {
            addFile(path: path, size: Int64(data.count), data: data)
        }
    }

    func removeItem(at url: URL) throws {
        let path = url.path
        if let error = errorOnRemove[path] {
            throw error
        }
        removedItems.append(url)
        files.removeValue(forKey: path)
        directories.remove(path)
    }

    func moveItem(at src: URL, to dst: URL) throws {
        let srcPath = src.path
        if let error = errorOnMove[srcPath] {
            throw error
        }
        movedItems.append((from: src, to: dst))
        if let entry = files[srcPath] {
            files[dst.path] = entry
            files.removeValue(forKey: srcPath)
        }
    }

    func getExtendedAttribute(
        _ name: String,
        atPath path: String
    ) throws -> Data {
        guard let attrs = xattrs[path], let data = attrs[name] else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOATTR),
                userInfo: nil
            )
        }
        return data
    }

    func setExtendedAttribute(
        _ name: String,
        data: Data,
        atPath path: String
    ) throws {
        if xattrs[path] == nil {
            xattrs[path] = [:]
        }
        xattrs[path]![name] = data
    }

    func availableSpace(atPath path: String) throws -> Int64 {
        availableDiskSpace
    }

    func glob(pattern: String, inDirectory dir: URL) throws -> [URL] {
        globResults[pattern] ?? []
    }
}
