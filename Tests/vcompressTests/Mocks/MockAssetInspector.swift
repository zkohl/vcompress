import Foundation
import CoreMedia
@testable import vcompress

/// Mock for AssetInspector. Returns preconfigured codec results
/// per file path, so Scanner classification can be fully tested.
final class MockAssetInspector: AssetInspector {

    /// Map of file path -> codec types for video tracks.
    /// Empty array = audio-only. Missing key = file not found (throws).
    var codecs: [String: [CMVideoCodecType]] = [:]

    /// Map of file path -> video track info for efficiency checks.
    var trackInfo: [String: VideoTrackInfo] = [:]

    /// Map of file path -> playability result.
    var playability: [String: Bool] = [:]

    /// Track calls for assertions.
    var videoTrackCodecsCalls: [URL] = []
    var isPlayableCalls: [URL] = []

    func videoTrackCodecs(forFileAt url: URL) async throws -> [CMVideoCodecType] {
        videoTrackCodecsCalls.append(url)
        guard let result = codecs[url.path] else {
            throw NSError(
                domain: "MockAssetInspector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No codecs configured for \(url.path)"]
            )
        }
        return result
    }

    func videoTrackInfo(forFileAt url: URL) async throws -> VideoTrackInfo? {
        return trackInfo[url.path]
    }

    func isPlayable(at url: URL) async throws -> Bool {
        isPlayableCalls.append(url)
        return playability[url.path] ?? false
    }
}
