import Foundation
import AVFoundation

/// Production implementation of ExportSessionFactory that wraps AVAssetExportSession.
struct RealExportSessionFactory: ExportSessionFactory {
    func export(
        source: URL,
        destination: URL,
        fileType: AVFileType,
        preset: String
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: preset
        ) else {
            throw EncodingError.exportSessionCreation
        }
        session.outputURL = destination
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = false

        await session.export()

        guard session.status == .completed else {
            throw EncodingError.exportFailed(session.error)
        }
    }
}
