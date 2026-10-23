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
        let audioRangeSegments: [RawTranscriptionSegment] = text.isEmpty ? [] : [.init(
            startSeconds: offset, endSeconds: Double(rangeEnd) / 1000,
            text: text, words: nil, timingSource: .audioRange)]
        if let segments = result.segments {
            // Punctuation can carry meaning (1.5 vs 15, -3 vs 3). Advisory text cannot replace it.
            let matchesTranscript = segments.lazy.flatMap(\.text).filter { !$0.isWhitespace }
                .elementsEqual(text.lazy.filter { !$0.isWhitespace }) && (text.isEmpty || !segments.isEmpty)
            guard matchesTranscript || (result.timingSource == .modelGenerated && !text.isEmpty) else {
                throw CloudTranscriptionError.invalidResponse
            }
            // Model annotations are advisory: keep the full transcript if their words disagree.
            evidence.segments = matchesTranscript ? segments.map {
                .init(startSeconds: offset + $0.start, endSeconds: offset + $0.end, text: $0.text,
                      words: nil, averageLogProbability: $0.averageLogProbability,
                      noSpeechProbability: $0.noSpeechProbability, timingSource: result.timingSource)
            } : audioRangeSegments
        } else {
            guard result.timingSource != .service else { throw CloudTranscriptionError.invalidResponse }
            evidence.segments = audioRangeSegments
        }
        evidence.partialDecodedText = nil
        evidence.partialDecodedTokens = nil
        evidence.failureReason = nil
        evidence.outcome = .completed
        // Validate before publishing and before a retry can replace any committed cues.
        do {
            _ = try SubtitleSegmenter.segment(evidence, sourceID: UUID(), mediaDurationMilliseconds: rangeEnd)
        } catch let error as SubtitleSegmentationError where result.timingSource == .modelGenerated && !text.isEmpty {
            switch error {
            case .invalidSegment, .invalidCueTiming:
                // Generated timing cannot invalidate a complete short-audio transcript.
                // cloudResult retains the original annotations for diagnosis and retry.
                evidence.segments = audioRangeSegments
                _ = try SubtitleSegmenter.segment(evidence, sourceID: UUID(), mediaDurationMilliseconds: rangeEnd)
            default: throw error
            }
        }
        return evidence
    }
}
