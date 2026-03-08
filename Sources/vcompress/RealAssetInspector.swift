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

    func videoTrackInfo(forFileAt url: URL) async throws -> VideoTrackInfo? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }

        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let transformedSize = naturalSize.applying(transform)
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))

        var fps = try await track.load(.nominalFrameRate)
        if fps <= 0 { fps = 30.0 }

        var bitrate = Double(try await track.load(.estimatedDataRate))
        if bitrate <= 0 {
            let duration = try await asset.load(.duration)
            let durationSec = CMTimeGetSeconds(duration)
            if durationSec > 0 {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = (attrs?[.size] as? Int64) ?? 0
                bitrate = Double(fileSize) * 8.0 / durationSec
            }
        }

        let descriptions = try await track.load(.formatDescriptions)
        let codec = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? kCMVideoCodecType_H264

        return VideoTrackInfo(
            width: width,
            height: height,
            frameRate: Double(fps),
            estimatedBitrate: bitrate,
            codec: codec
        )
    }

    func isPlayable(at url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        return isPlayable
    }
}
