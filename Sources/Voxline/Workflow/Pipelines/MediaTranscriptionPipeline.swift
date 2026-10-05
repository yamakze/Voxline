import Foundation
import VoxlineCore
import VoxlineMedia
import VoxlineWhisperKit

/// The two external operations of a media run; checkpoints remain owned by the queue.
public protocol MediaTranscriptionPipeline: Sendable {
    func extract(item: TaskMediaItem, progress: @escaping @Sendable (AudioExtractionProgress) -> Void) async throws -> [TranscriptionAudio]
    func transcribe(mediaID: UUID, audio: TranscriptionAudio, settings: TranscriptionSettings,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionEvidence
}

public struct LocalMediaTranscriptionPipeline: MediaTranscriptionPipeline {
    let mediaStore: LocalMediaStore
    let extractor: AudioExtractor
    let modelStore: WhisperModelStore
    let evidenceDirectory: URL?

    public init(mediaStore: LocalMediaStore = .shared, extractor: AudioExtractor = .shared,
         modelStore: WhisperModelStore = .shared, evidenceDirectory: URL? = nil) {
        self.mediaStore = mediaStore
        self.extractor = extractor
        self.modelStore = modelStore
        self.evidenceDirectory = evidenceDirectory
    }

    public func extract(item: TaskMediaItem, progress: @escaping @Sendable (AudioExtractionProgress) -> Void) async throws -> [TranscriptionAudio] {
        guard let media = item.media else { throw TaskValidationError.unassociatedMedia(item.id) }
        guard let bookmark = try await mediaStore.resolve(projectID: item.id, identity: media) else {
            throw QueueError.unavailable("找不到本机媒体文件，请在详情中重新关联。")
        }
        // Extraction verifies the selected track and content before reusing or producing PCM.
        let result = try await extractor.extract(mediaURL: bookmark.url, mediaID: item.id, identity: media, onProgress: progress)
        if bookmark.isStale { try await mediaStore.save(projectID: item.id, identity: media, url: bookmark.url) }
        return result.chunks
    }

    public func transcribe(mediaID: UUID, audio: TranscriptionAudio, settings: TranscriptionSettings,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionEvidence {
        let provider = try WhisperKitTranscriptionProvider(settings: settings, store: modelStore, evidenceDirectory: evidenceDirectory, mediaID: mediaID, onProgress: progress)
        return try await provider.transcribeEvidence(audio: audio)
    }
}
