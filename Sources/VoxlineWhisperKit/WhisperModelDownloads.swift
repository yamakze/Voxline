import Foundation
import WhisperKit

/// Converts SDK download progress into an application-owned value.
public enum WhisperModelDownloads {
    public static func download(modelID: String, directory: URL,
                                onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(variant: modelID, downloadBase: directory,
                                      progressCallback: { onProgress($0.fractionCompleted) })
    }
}
