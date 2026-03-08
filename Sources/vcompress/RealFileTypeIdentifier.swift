import Foundation
import UniformTypeIdentifiers

/// Production FileTypeIdentifier using UTType to check file types.
struct RealFileTypeIdentifier: FileTypeIdentifier {

    func isMovie(at url: URL) -> Bool {
        guard let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = resourceValues.contentType else {
            // Fallback: check by extension if UTType detection fails
            let movieExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mts"]
            return movieExtensions.contains(url.pathExtension.lowercased())
        }
        return contentType.conforms(to: .movie)
    }

    func fileExtension(at url: URL) -> String {
        url.pathExtension.lowercased()
    }
}
