import Foundation
@testable import vcompress

/// Mock FileTypeIdentifier that returns configurable results
/// for isMovie and fileExtension checks.
final class MockFileTypeIdentifier: FileTypeIdentifier {

    /// Set of file paths (or filenames) that should be considered movies.
    var movieFiles: Set<String> = []

    /// Override extensions by path. If not set, uses the URL's actual pathExtension.
    var extensionsByPath: [String: String] = [:]

    /// Track calls for assertions.
    var isMovieCalls: [URL] = []
    var fileExtensionCalls: [URL] = []

    func isMovie(at url: URL) -> Bool {
        isMovieCalls.append(url)
        // Check both the full path and just the last path component.
        return movieFiles.contains(url.path)
            || movieFiles.contains(url.lastPathComponent)
    }

    func fileExtension(at url: URL) -> String {
        fileExtensionCalls.append(url)
        if let override = extensionsByPath[url.path] {
            return override
        }
        return url.pathExtension.lowercased()
    }
}
