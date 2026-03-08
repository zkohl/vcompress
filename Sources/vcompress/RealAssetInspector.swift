import Foundation
import AVFoundation
import CoreMedia

/// Production AssetInspector wrapping AVFoundation for codec detection
/// and playability checking.
struct RealAssetInspector: AssetInspector {

    func videoTrackCodecs(forFileAt url: URL) async throws -> [CMVideoCodecType] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        var codecs: [CMVideoCodecType] = []
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            for desc in descriptions {
                let codecType = CMFormatDescriptionGetMediaSubType(desc)
                codecs.append(codecType)
            }
        }
        return codecs
    }

    func isPlayable(at url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        return isPlayable
    }
}
