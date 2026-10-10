import Foundation
import VoxlineCore
import VoxlineMedia
import VoxlineWhisperKit
import VoxlineTranslation

/// The two external operations of a media run; checkpoints remain owned by the queue.
public protocol MediaTranscriptionPipeline: Sendable {
    func extract(item: TaskMediaItem, progress: @escaping @Sendable (AudioExtractionProgress) -> Void) async throws -> [TranscriptionAudio]
    func speechChunks(from audio: [TranscriptionAudio], settings: TranscriptionSettings) async throws -> [TranscriptionAudio]
    func transcribe(mediaID: UUID, audio: TranscriptionAudio, settings: TranscriptionSettings,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionEvidence
}

public extension MediaTranscriptionPipeline {
    func speechChunks(from audio: [TranscriptionAudio], settings: TranscriptionSettings) async throws -> [TranscriptionAudio] { audio }
}

public struct ConfiguredMediaTranscriptionPipeline: MediaTranscriptionPipeline {
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
        guard let bookmark = try await mediaStore.resolve(mediaID: item.id, identity: media) else {
            throw QueueError.unavailable(String(localized: "找不到本机媒体文件，请在详情中重新关联。", bundle: voxlineLocalizationBundle))
        }
        // Extraction verifies the selected track and content before reusing or producing PCM.
        let result = try await extractor.extract(mediaURL: bookmark.url, mediaID: item.id, identity: media, onProgress: progress)
        if bookmark.isStale { try await mediaStore.save(mediaID: item.id, identity: media, url: bookmark.url) }
        return result.chunks
    }

    public func speechChunks(from audio: [TranscriptionAudio], settings: TranscriptionSettings) async throws -> [TranscriptionAudio] {
        guard settings.cloud?.protocolKind.usesSpeechChunks == true else { return audio }
        return try audio.flatMap { try SpeechAudioChunker.chunks(from: $0) }
    }

    public func transcribe(mediaID: UUID, audio: TranscriptionAudio, settings: TranscriptionSettings,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionEvidence {
        if settings.provider == .openAICompatible {
            let key = try await CloudTranscriptionServiceStore.shared.apiKey(for: settings)
            if settings.cloud?.protocolKind.usesSpeechChunks == true {
                let provider = try AudioChatTranscriptionProvider(settings: settings, apiKey: key,
                    padShortAudio: { try TranscriptionAudioUpload.paddedToOneSecond($0) },
                    evidenceDirectory: evidenceDirectory, mediaID: mediaID, onProgress: progress)
                return try await provider.transcribeEvidence(audio: audio)
            }
            let provider = try OpenAITranscriptionProvider(settings: settings, apiKey: key,
                evidenceDirectory: evidenceDirectory, mediaID: mediaID, onProgress: progress)
            return try await provider.transcribeEvidence(audio: audio)
        }
        let provider = try WhisperKitTranscriptionProvider(settings: settings, store: modelStore, evidenceDirectory: evidenceDirectory, mediaID: mediaID, onProgress: progress)
        return try await provider.transcribeEvidence(audio: audio)
    }
}
