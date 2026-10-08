import Foundation

public enum TranscriptionTimingSource: String, Codable, Sendable {
    case service, modelGenerated, audioRange
}

/// Recognition survives alignment failure; relative times retain their actual provenance.
public struct CloudTranscriptionResult: Codable, Equatable, Sendable {
    public let text: String
    public let segments: [Segment]?
    public let timingSource: TranscriptionTimingSource
    public struct Segment: Codable, Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
        public let averageLogProbability: Double?
        public let noSpeechProbability: Double?
        public init(start: Double, end: Double, text: String,
                    averageLogProbability: Double? = nil, noSpeechProbability: Double? = nil) {
            self.start = start; self.end = end; self.text = text
            self.averageLogProbability = averageLogProbability; self.noSpeechProbability = noSpeechProbability
        }
    }
    public init(text: String, segments: [Segment]?, timingSource: TranscriptionTimingSource) {
        self.text = text; self.segments = segments; self.timingSource = timingSource
    }
}

public enum CloudTranscriptionAlignment {
    public static func completedEvidence(from original: TranscriptionEvidence) throws -> TranscriptionEvidence {
        guard let result = original.cloudResult else { throw CloudTranscriptionError.invalidResponse }
        var evidence = original
        let (rangeEnd, overflow) = evidence.sourceStartMilliseconds.addingReportingOverflow(evidence.durationMilliseconds)
        guard !overflow, evidence.sourceStartMilliseconds >= 0, evidence.durationMilliseconds > 0 else {
            throw TranscriptionInputError.invalidAudio
        }
        let offset = Double(evidence.sourceStartMilliseconds) / 1000
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let segments = result.segments {
            let joined = segments.map(\.text).joined()
            func content(_ value: String) -> String { value.filter { !$0.isWhitespace } }
            guard content(joined) == content(text), text.isEmpty || !segments.isEmpty else {
                throw CloudTranscriptionError.invalidResponse
            }
            evidence.segments = segments.map {
                .init(startSeconds: offset + $0.start, endSeconds: offset + $0.end, text: $0.text,
                      words: nil, averageLogProbability: $0.averageLogProbability,
                      noSpeechProbability: $0.noSpeechProbability, timingSource: result.timingSource)
            }
        } else {
            guard result.timingSource == .audioRange else { throw CloudTranscriptionError.invalidResponse }
            evidence.segments = text.isEmpty ? [] : [.init(startSeconds: offset,
                endSeconds: Double(rangeEnd) / 1000,
                text: text, words: nil, timingSource: .audioRange)]
        }
        evidence.partialDecodedText = nil
        evidence.partialDecodedTokens = nil
        evidence.failureReason = nil
        evidence.outcome = .completed
        // Validate before publishing and before a retry can replace any committed cues.
        _ = try SubtitleSegmenter.segment(evidence, sourceID: UUID(),
            mediaDurationMilliseconds: rangeEnd)
        return evidence
    }
}
