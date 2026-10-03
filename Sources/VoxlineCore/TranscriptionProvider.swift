import Foundation

public protocol TranscriptionProvider: Sendable {
    func transcribe(audio: TranscriptionAudio) async throws -> [RawTranscriptionSegment]
}

public struct TranscriptionAudio: Sendable {
    public let localURL: URL
    public let sourceStartMilliseconds: Int64
    public let durationMilliseconds: Int64

    public init(localURL: URL, sourceStartMilliseconds: Int64, durationMilliseconds: Int64) throws {
        guard localURL.isFileURL, sourceStartMilliseconds >= 0, durationMilliseconds > 0 else {
            throw TranscriptionInputError.invalidAudio
        }
        self.localURL = localURL
        self.sourceStartMilliseconds = sourceStartMilliseconds
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Raw SDK evidence may have invalid alignment. Conversion to SubtitleCue must validate it explicitly.
public struct RawTranscriptionSegment: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let words: [RawWordTiming]?
    public let averageLogProbability: Double?
    public let noSpeechProbability: Double?

    public init(startSeconds: Double, endSeconds: Double, text: String, words: [RawWordTiming]?,
                averageLogProbability: Double? = nil, noSpeechProbability: Double? = nil) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.words = words
        self.averageLogProbability = averageLogProbability
        self.noSpeechProbability = noSpeechProbability
    }
}

public struct RawWordTiming: Codable, Equatable, Sendable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let probability: Double

    public init(text: String, startSeconds: Double, endSeconds: Double, probability: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.probability = probability
    }
}

public enum TranscriptionInputError: Error { case invalidAudio }

public enum TranscriptionProgress: Sendable {
    case readingAudio, loadingModel, detectingLanguage
    case decoding(tokenCount: Int)
    case completed(segmentCount: Int)
}

/// Every time in raw evidence is absolute on the source media timeline, including failed alignment.
public struct TranscriptionWindowEvidence: Codable, Equatable, Sendable {
    public let seekFrame: Int
    public let frameCount: Int
    public let decodedText: String
    public let decodedTokens: [Int]
    public let language: String
    public let skippedAsNoSpeech: Bool
    public let segmentsBeforeAlignment: [RawTranscriptionSegment]
    public var alignedSegments: [RawTranscriptionSegment]?

    public init(seekFrame: Int, frameCount: Int, decodedText: String, decodedTokens: [Int], language: String,
                skippedAsNoSpeech: Bool, segmentsBeforeAlignment: [RawTranscriptionSegment],
                alignedSegments: [RawTranscriptionSegment]? = nil) {
        self.seekFrame = seekFrame
        self.frameCount = frameCount
        self.decodedText = decodedText
        self.decodedTokens = decodedTokens
        self.language = language
        self.skippedAsNoSpeech = skippedAsNoSpeech
        self.segmentsBeforeAlignment = segmentsBeforeAlignment
        self.alignedSegments = alignedSegments
    }
}

public struct TranscriptionEvidence: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }
    public let settings: TranscriptionSettings
    public let sourceStartMilliseconds: Int64
    public let durationMilliseconds: Int64
    public var windows: [TranscriptionWindowEvidence]
    public var segments: [RawTranscriptionSegment]
    public var partialDecodedText: String?
    public var partialDecodedTokens: [Int]?
    public var outcome: Outcome
    public var failureReason: String?

    public init(settings: TranscriptionSettings, audio: TranscriptionAudio) {
        self.settings = settings
        sourceStartMilliseconds = audio.sourceStartMilliseconds
        durationMilliseconds = audio.durationMilliseconds
        windows = []
        segments = []
        partialDecodedText = nil
        partialDecodedTokens = nil
        outcome = .failed
    }
}

/// Failure retains unfiltered text and the input range; a partial result is never returned as success.
public struct TranscriptionFailure: Error, LocalizedError, Sendable {
    public let cause: any Error
    public let evidence: TranscriptionEvidence
    public let evidenceURL: URL?
    public let storageError: String?
    public var isCancelled: Bool { evidence.outcome == .cancelled }

    public init(cause: any Error, evidence: TranscriptionEvidence, evidenceURL: URL?, storageError: String? = nil) {
        self.cause = cause
        self.evidence = evidence
        self.evidenceURL = evidenceURL
        self.storageError = storageError
    }

    public var errorDescription: String? {
        let reason = evidence.failureReason ?? "转写失败记录缺少原因。"
        if let storageError { return "\(reason) 原始证据写入失败：\(storageError)" }
        return reason
    }
}
