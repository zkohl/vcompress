import Foundation
import AVFoundation
@testable import vcompress

/// Mock for ExportSessionFactory. Returns configurable success/failure results
/// without performing any actual encoding.
final class MockExportSessionFactory: ExportSessionFactory {

    /// The result to return from export calls.
    enum MockResult {
        case success
        case failure(Error)
    }

    /// Default result for all export calls.
    var defaultResult: MockResult = .success

    /// Per-source-path results (overrides defaultResult).
    var resultsByPath: [String: MockResult] = [:]

    /// Track calls for assertions.
    var exportCalls: [(source: URL, destination: URL, fileType: AVFileType, quality: Quality)] = []

    /// Optional side effect: write dummy data to the destination to simulate output.
    var writeDummyOutput: Bool = true

    /// Size of dummy output file in bytes.
    var dummyOutputSize: Int = 1024

    init(result: MockResult = .success) {
        self.defaultResult = result
    }

    func export(
        source: URL,
        destination: URL,
        fileType: AVFileType,
        quality: Quality
    ) async throws {
        exportCalls.append((
            source: source,
            destination: destination,
            fileType: fileType,
            quality: quality
        ))

        let result = resultsByPath[source.path] ?? defaultResult

        switch result {
        case .success:
            if writeDummyOutput {
                let data = Data(repeating: 0xFF, count: dummyOutputSize)
                try data.write(to: destination)
            }
        case .failure(let error):
            throw error
        }
    }
}
