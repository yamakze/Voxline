import Foundation
import VoxlineCore
import VoxlineMedia
import VoxlineWhisperKit

/// The two external operations of a media run; checkpoints remain owned by the queue.
protocol MediaTranscriptionPipeline: Sendable {
    func extract(item: TaskMediaItem, progress: @escaping @Sendable (AudioExtractionProgress) -> Void) async throws -> [TranscriptionAudio]
    func transcribe(audio: TranscriptionAudio, settings: TranscriptionSettings,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionEvidence
}

struct LocalMediaTranscriptionPipeline: MediaTranscriptionPipeline {
    let mediaStore: LocalMediaStore
    let extractor: AudioExtractor
    let modelStore: WhisperModelStore

    init(mediaStore: LocalMediaStore = .shared, extractor: AudioExtractor = .shared,
         modelStore: WhisperModelStore = .shared) {
        self.mediaStore = mediaStore
        self.extractor = extractor
        self.modelStore = modelStore
    }

    func extract(item: TaskMediaItem, progress: @escaping @Sendable (AudioExtractionProgress) -> Void) async throws -> [TranscriptionAudio] {
        guard let media = item.media else { throw TaskValidationError.unassociatedMedia(item.id) }
        guard let bookmark = try await mediaStore.resolve(projectID: item.id, identity: media) else {
            throw QueueError.unavailable("找不到本机媒体文件，请在详情中重新关联。")
        }
        // Extraction verifies the selected track and content before reusing or producing PCM.
        let result = try await extractor.extract(mediaURL: bookmark.url, mediaID: item.id, identity: media, onProgress: progress)
        if bookmark.isStale { try await mediaStore.save(projectID: item.id, identity: media, url: bookmark.url) }
        return result.chunks
    }

    func transcribe(audio: TranscriptionAudio, settings: TranscriptionSettings,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionEvidence {
        let provider = try WhisperKitTranscriptionProvider(settings: settings, store: modelStore, onProgress: progress)
        return try await provider.transcribeEvidence(audio: audio)
    }
}
