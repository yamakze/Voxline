import Foundation
import VoxlineCore
import WhisperKit

public struct WhisperKitTranscriptionProvider: TranscriptionProvider {
    public let settings: TranscriptionSettings
    private let store: WhisperModelStore
    private let evidenceDirectory: URL?
    private let mediaID: UUID?
    private let onProgress: @Sendable (VoxlineCore.TranscriptionProgress) -> Void

    public init(settings: TranscriptionSettings, store: WhisperModelStore = .shared, evidenceDirectory: URL? = nil, mediaID: UUID? = nil,
                onProgress: @escaping @Sendable (VoxlineCore.TranscriptionProgress) -> Void = { _ in }) throws {
        try settings.validate()
        guard settings.provider == .whisperKit else { throw CloudTranscriptionError.invalidConfiguration }
        guard settings.modelID == TranscriptionSettings.whisperKitBaseline.modelID else { throw WhisperModelError.unknownModel }
        if let code = settings.languageCode, !Constants.languageCodes.contains(code) {
            throw WhisperTranscriptionError.unsupportedLanguage(code)
        }
        self.settings = settings
        self.store = store
        self.evidenceDirectory = evidenceDirectory
        self.mediaID = mediaID
        self.onProgress = onProgress
    }

    public func transcribe(audio: TranscriptionAudio) async throws -> [RawTranscriptionSegment] {
        try await transcribeEvidence(audio: audio).segments
    }

    /// Only completed recognition can be realigned; partial decoding never becomes a completed result.
    public static func recoverCompletedEvidence(_ original: TranscriptionEvidence) throws -> TranscriptionEvidence {
        guard original.settings.provider == .whisperKit, original.outcome == .completed,
              original.failureReason == nil, original.partialDecodedText == nil, original.partialDecodedTokens == nil,
              !original.windows.isEmpty, original.durationMilliseconds <= 120_000 else {
            throw WhisperTranscriptionError.invalidAlignment("没有完整的本地识别结果可恢复。")
        }
        guard original.windows.allSatisfy({ $0.seekFrame >= 0 && $0.seekFrame <= 1_920_000 &&
            $0.frameCount > 0 && $0.frameCount <= 480_000 && $0.seekFrame + $0.frameCount <= 1_920_000 }) else {
            throw WhisperTranscriptionError.invalidAudio
        }
        let frameCount = original.windows.map { $0.seekFrame + $0.frameCount }.max()!
        guard Int64((frameCount + 15) / 16) == original.durationMilliseconds else { throw WhisperTranscriptionError.invalidAudio }
        let selected = original.windows.flatMap { $0.usesSegmentTimings == true ? $0.segmentsBeforeAlignment :
            ($0.alignedSegments ?? $0.segmentsBeforeAlignment) }
        guard selected.filter({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ==
                original.segments.filter({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw WhisperTranscriptionError.invalidAlignment("保存的识别结果遗漏或改变了窗口文本。")
        }
        var evidence = original
        let offset = Double(evidence.sourceStartMilliseconds) / 1000
        for index in evidence.windows.indices where evidence.windows[index].usesSegmentTimings != true {
            let window = evidence.windows[index]
            guard let aligned = window.alignedSegments else { continue }
            evidence.windows[index].usesSegmentTimings = try TranscriptionEvidenceSeeker.requiresSegmentTimings(
                original: window.segmentsBeforeAlignment, aligned: aligned,
                lower: offset + Double(window.seekFrame) / 16_000,
                upper: offset + Double(window.seekFrame + window.frameCount) / 16_000)
        }
        let recovered = evidence.windows.flatMap { $0.usesSegmentTimings == true ? $0.segmentsBeforeAlignment :
            ($0.alignedSegments ?? $0.segmentsBeforeAlignment) }
        evidence.segments = try TranscriptionEvidenceSeeker.validatedSegments(windows: evidence.windows,
            sourceOffsetSeconds: offset, frameCount: frameCount, returnedSegments: recovered)
        return evidence
    }

    /// Bounded input only. Local re-transcription must extract an explicit range first, preserving its source offset.
    public func transcribeEvidence(audio: TranscriptionAudio) async throws -> TranscriptionEvidence {
        let seeker = TranscriptionEvidenceSeeker(sourceStartMilliseconds: audio.sourceStartMilliseconds)
        var evidence = TranscriptionEvidence(settings: settings, audio: audio)
        do {
            let segments = try await store.transcribe(audio: audio, settings: settings, seeker: seeker, onProgress: onProgress)
            try Task.checkCancellation()
            evidence.windows = seeker.windows
            evidence.segments = segments
            evidence.outcome = .completed
        } catch let cause {
            evidence.windows = seeker.windows
            evidence.segments = evidence.windows.flatMap { $0.alignedSegments ?? $0.segmentsBeforeAlignment }
            evidence.partialDecodedText = seeker.partialDecode.text
            evidence.partialDecodedTokens = seeker.partialDecode.tokens
            evidence.outcome = Task.isCancelled || cause is CancellationError ? .cancelled : .failed
            evidence.failureReason = cause.localizedDescription
            let url: URL
            do { url = try persist(evidence) }
            catch { throw TranscriptionFailure(cause: cause, evidence: evidence, evidenceURL: nil, storageError: error.localizedDescription) }
            throw TranscriptionFailure(cause: cause, evidence: evidence, evidenceURL: url)
        }
        // A completed inference is published only after its unfiltered evidence is safely written.
        do { _ = try persist(evidence) }
        catch {
            evidence.outcome = .failed
            evidence.failureReason = "推理完成，但原始证据无法保存。"
            throw TranscriptionFailure(cause: error, evidence: evidence, evidenceURL: nil, storageError: error.localizedDescription)
        }
        onProgress(.completed(segmentCount: evidence.segments.count))
        return evidence
    }

    private func persist(_ evidence: TranscriptionEvidence) throws -> URL {
        let root: URL
        if let evidenceDirectory { root = evidenceDirectory }
        else {
            root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Voxline/Transcription", isDirectory: true)
        }
        // Device-local evidence belongs to the explicit queue media ID, never a guessed input path.
        let directory = mediaID.map { root.appendingPathComponent($0.uuidString, isDirectory: true) } ?? root
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        try encoder.encode(evidence).write(to: url, options: .atomic)
        return url
    }
}

public enum WhisperTranscriptionError: Error, LocalizedError, Equatable {
    case busy, unsupportedLanguage(String), invalidAudio, invalidAlignment(String), invalidTiming(String)

    public var errorDescription: String? {
        switch self {
        case .busy: "模型正在下载、加载或转写，请等待当前操作结束。"
        case .unsupportedLanguage(let code): "WhisperKit 不支持语言代码 \(code)。"
        case .invalidAudio: "转写输入必须是最多 120 秒的非空 16 kHz 单声道 Float32 PCM，且时长与参数一致。"
        case .invalidAlignment(let reason), .invalidTiming(let reason): reason
        }
    }
}
