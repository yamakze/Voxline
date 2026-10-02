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
public struct RawTranscriptionSegment: Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let words: [RawWordTiming]?

    public init(startSeconds: Double, endSeconds: Double, text: String, words: [RawWordTiming]?) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.words = words
    }
}

public struct RawWordTiming: Sendable {
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
