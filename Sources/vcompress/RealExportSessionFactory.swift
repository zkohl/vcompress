import Foundation
import AVFoundation
import VideoToolbox

/// Production implementation of ExportSessionFactory that wraps AVAssetExportSession
/// for standard quality, and AVAssetReader/Writer for high/max quality tiers.
struct RealExportSessionFactory: ExportSessionFactory {
    func export(
        source: URL,
        destination: URL,
        fileType: AVFileType,
        quality: Quality
    ) async throws {
        switch quality {
        case .standard:
            try await exportWithSession(source: source, destination: destination, fileType: fileType)
        case .high, .max:
            let compressionQuality: Double = quality == .max ? 0.75 : 0.65
            try await exportWithWriter(
                source: source,
                destination: destination,
                fileType: fileType,
                compressionQuality: compressionQuality
            )
        }
    }

    // MARK: - AVAssetExportSession path (standard quality)

    private func exportWithSession(
        source: URL,
        destination: URL,
        fileType: AVFileType
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHEVCHighestQuality
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

    // MARK: - AVAssetReader/Writer path (high/max quality)

    private func exportWithWriter(
        source: URL,
        destination: URL,
        fileType: AVFileType,
        compressionQuality: Double
    ) async throws {
        let asset = AVURLAsset(url: source)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)

        // Video track
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if let videoTrack = videoTracks.first {
            let readerOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
            )
            readerOutput.alwaysCopiesSampleData = false

            let naturalSize = try await videoTrack.load(.naturalSize)
            let writerInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: Int(naturalSize.width),
                    AVVideoHeightKey: Int(naturalSize.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoQualityKey: compressionQuality
                    ]
                ]
            )
            writerInput.expectsMediaDataInRealTime = false

            let transform = try await videoTrack.load(.preferredTransform)
            writerInput.transform = transform

            if reader.canAdd(readerOutput) { reader.add(readerOutput) }
            if writer.canAdd(writerInput) { writer.add(writerInput) }
        }

        // Audio track (passthrough — nil outputSettings = copy)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = audioTracks.first {
            let audioReaderOutput = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: nil
            )
            audioReaderOutput.alwaysCopiesSampleData = false

            let audioWriterInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil
            )
            audioWriterInput.expectsMediaDataInRealTime = false

            if reader.canAdd(audioReaderOutput) { reader.add(audioReaderOutput) }
            if writer.canAdd(audioWriterInput) { writer.add(audioWriterInput) }
        }

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Process all inputs concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<writer.inputs.count {
                let writerInput = writer.inputs[i]
                let readerOutput = reader.outputs[i]
                group.addTask {
                    await withCheckedContinuation { continuation in
                        writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "vcompress.writer.\(i)")) {
                            while writerInput.isReadyForMoreMediaData {
                                if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                                    writerInput.append(sampleBuffer)
                                } else {
                                    writerInput.markAsFinished()
                                    continuation.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        await writer.finishWriting()

        if reader.status == .failed {
            throw EncodingError.exportFailed(reader.error)
        }
        if writer.status == .failed {
            throw EncodingError.exportFailed(writer.error)
        }
    }
}
