import Foundation
import Testing
@testable import VoxlineCore

@Suite("Readable subtitle segmentation")
struct SubtitleSegmentationTests {
    @Test func codecFrameEdgeErrorsClampWithoutChangingEvidenceOrDroppingDialogue() throws {
        let input = try evidence([
            .init(startSeconds: -0.005, endSeconds: 0.6, text: "First", words: nil),
            .init(startSeconds: 0.595, endSeconds: 1.005, text: "Last", words: nil)
        ], duration: 1000)
        let result = try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 1000)
        #expect(result.cues.map(\.sourceText) == ["First", "Last"])
        #expect(result.cues.map(\.startMilliseconds) == [0, 600])
        #expect(result.cues.map(\.endMilliseconds) == [600, 1000])
        #expect(result.evidence == input)
        let largeError = try evidence([.init(startSeconds: 0, endSeconds: 1.2, text: "Last", words: nil)], duration: 1000)
        #expect(throws: SubtitleSegmentationError.invalidSegment(0)) {
            try SubtitleSegmenter.segment(largeError, sourceID: sourceID, mediaDurationMilliseconds: 1000)
        }
    }
    private let sourceID = UUID(uuidString: "E53D56C0-E3B1-46C0-A953-734DFDA90F45")!

    private func evidence(_ segments: [RawTranscriptionSegment], start: Int64 = 0, duration: Int64 = 20_000) throws -> TranscriptionEvidence {
        let audio = try TranscriptionAudio(localURL: URL(fileURLWithPath: "/tmp/sample.wav"),
                                           sourceStartMilliseconds: start, durationMilliseconds: duration)
        var result = TranscriptionEvidence(settings: .whisperKitBaseline, audio: audio)
        result.outcome = .completed
        result.segments = segments
        return result
    }

    private func raw(_ words: [RawWordTiming]) -> RawTranscriptionSegment {
        RawTranscriptionSegment(startSeconds: words.first!.startSeconds, endSeconds: words.last!.endSeconds,
                                text: words.map(\.text).joined(), words: words)
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> RawWordTiming {
        RawWordTiming(text: text, startSeconds: start, endSeconds: end, probability: 0.9)
    }

    @Test func punctuationSilenceAndExtensionUseRealSpeechBoundaries() throws {
        let input = try evidence([raw([word(" Hello", 2, 2.2), word(" world!", 2.2, 2.4),
                                      word(" Next", 2.6, 3), word(" line", 3.8, 4.2)])])
        let output = try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 20_000)
        #expect(output.cues.map(\.sourceText) == ["Hello world!", "Next", "line"])
        #expect(output.cues.map(\.startMilliseconds) == [2000, 2600, 3800])
        #expect(output.cues.map(\.endMilliseconds) == [2600, 3600, 4800])
        #expect(output.entries[0].reviewReasons == [.shortDisplay])
        #expect(output.entries.allSatisfy { $0.alignment == .words })
        #expect(output.evidence.segments == input.segments)
    }

    @Test func widthBacktracksAtCommaAndNeverSplitsAWordOrPunctuation() throws {
        let input = try evidence([raw([word(" One,", 0, 0.3), word(" two", 0.3, 0.6),
                                      word(" three", 0.6, 0.9), word(" four", 0.9, 1.2),
                                      word(".", 1.2, 1.2)])])
        let output = try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 20_000,
                                                  policy: .init(maximumWidth: 14))
        #expect(output.cues.map(\.sourceText) == ["One,", "two three", "four."])
        #expect(output.entries.map(\.wordRange) == [0..<1, 1..<3, 3..<5])
        let fragments = try evidence([raw([word(" Super", 0, 0.1), word("califragilistic", 0.1, 0.5),
                                           word(" done", 0.5, 1)])])
        let longWord = try SubtitleSegmenter.segment(fragments, sourceID: sourceID, mediaDurationMilliseconds: 20_000,
                                                    policy: .init(maximumWidth: 8))
        #expect(longWord.cues.map(\.sourceText) == ["Supercalifragilistic", "done"])
        #expect(longWord.entries[0].reviewReasons.contains(.exceedsWidth))
    }

    @Test func durationCJKAndAbbreviationsRespectSourceWordBoundaries() throws {
        let input = try evidence([raw([word(" Dr.", 0, 0.5), word(" Smith", 0.5, 1), word(" speaks", 1, 2),
                                      word(" slowly", 2, 4), word(" today.", 4, 5)])])
        let output = try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 20_000,
                                                  policy: .init(maximumDurationMilliseconds: 3000))
        #expect(output.cues.map(\.sourceText) == ["Dr. Smith speaks", "slowly today."])
        let chinese = try evidence([raw([word("你好", 0, 0.5), word("世界。", 0.5, 1), word("再见！", 1, 2)])])
        let cjk = try SubtitleSegmenter.segment(chinese, sourceID: sourceID, mediaDurationMilliseconds: 20_000,
                                               policy: .init(maximumWidth: 6))
        #expect(cjk.cues.map(\.sourceText) == ["你好", "世界。", "再见！"])
        #expect(SubtitleSegmenter.visualWidth("你好e\u{301}🙂") == 7)
    }

    @Test func missingWordsStayWholeAndEmptySegmentsHaveAnAuditTrail() throws {
        let input = try evidence([
            RawTranscriptionSegment(startSeconds: .nan, endSeconds: .nan, text: " \n", words: nil),
            RawTranscriptionSegment(startSeconds: 3, endSeconds: 15, text: " Original complete text ", words: nil)
        ])
        let output = try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 20_000,
                                                  policy: .init(maximumWidth: 8))
        #expect(output.excludedEmptySegmentIndices == [0])
        #expect(output.cues.count == 1)
        #expect(output.cues[0].startMilliseconds == 3000)
        #expect(output.cues[0].endMilliseconds == 15_000)
        #expect(output.entries[0].alignment == .segment)
        #expect(output.entries[0].reviewReasons == [.missingWordTiming, .exceedsWidth, .exceedsDuration])
        #expect(output.evidence.segments[0].startSeconds.isNaN)
        let silent = try evidence([])
        #expect(try SubtitleSegmenter.segment(silent, sourceID: sourceID, mediaDurationMilliseconds: 20_000).cues.isEmpty)
    }

    @Test func identityEvidenceAndAlignmentSurviveReopeningAndResegmentation() throws {
        let input = try evidence([raw([word(" A", 122.25, 122.5), word(" sentence.", 122.5, 123)])], start: 120_000)
        let first = try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 140_000)
        let data = try JSONEncoder().encode(first)
        let reopened = try JSONDecoder().decode(SubtitleSegmentationResult.self, from: data)
        let second = try SubtitleSegmenter.segment(reopened.evidence, sourceID: reopened.sourceID,
                                                   mediaDurationMilliseconds: 140_000, policy: reopened.policy)
        #expect(first.entries == reopened.entries)
        #expect(first.entries == second.entries)
        #expect(first.cues[0].startMilliseconds == 122_250)
        #expect(first.evidence.segments == reopened.evidence.segments)
        let another = try SubtitleSegmenter.segment(input, sourceID: UUID(), mediaDurationMilliseconds: 140_000)
        #expect(first.cues[0].id != another.cues[0].id)
    }

    @Test func zeroDurationWordsStayWithSpeechAndDisplayStopsAtChunkEnd() throws {
        let input = try evidence([raw([word(" The", 19.6, 19.6), word(" end", 19.6, 19.8), word("!", 19.8, 19.8)])])
        let output = try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 20_000)
        #expect(output.cues.count == 1)
        #expect(output.cues[0].sourceText == "The end!")
        #expect(output.cues[0].startMilliseconds == 19_600)
        #expect(output.cues[0].endMilliseconds == 20_000)
        #expect(output.entries[0].reviewReasons == [.shortDisplay])
    }

    @Test func failedCancelledAndInvalidRangesCannotBecomeCompletedCues() throws {
        var input = try evidence([raw([word(" Text", 0, 1)])])
        for outcome in [TranscriptionEvidence.Outcome.failed, .cancelled] {
            input.outcome = outcome
            #expect(throws: SubtitleSegmentationError.incompleteTranscription) {
                try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 20_000)
            }
        }
        input.outcome = .completed
        input.partialDecodedText = "uncommitted"
        #expect(throws: SubtitleSegmentationError.incompleteTranscription) {
            try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 20_000)
        }
        input.partialDecodedText = nil
        #expect(throws: SubtitleSegmentationError.invalidRange) {
            try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 19_000)
        }
        #expect(throws: SubtitleSegmentationError.invalidPolicy) {
            try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 20_000,
                                          policy: .init(maximumWidth: 0))
        }
    }

    @Test func invalidAlignmentAndMissingTextAreRejectedWithoutRepair() throws {
        let invalid: [(RawTranscriptionSegment, SubtitleSegmentationError)] = [
            (.init(startSeconds: 0, endSeconds: 0, text: "Text", words: nil), .invalidSegment(0)),
            (.init(startSeconds: .nan, endSeconds: 1, text: "Text", words: nil), .invalidSegment(0)),
            (.init(startSeconds: 0, endSeconds: 21, text: "Text", words: nil), .invalidSegment(0)),
            (.init(startSeconds: 0, endSeconds: 1, text: "Text lost", words: [word(" Text", 0, 1)]), .textMismatch(0)),
            (raw([word(" A", 0, 0.7), word(" B", 0.5, 1)]), .invalidWords(0)),
            (.init(startSeconds: 0, endSeconds: 1, text: "Text", words: [word(" Text", 0, 21)]), .invalidWords(0)),
            (.init(startSeconds: 0, endSeconds: 1, text: "Text", words: [word(" Text", 0.5, 0.5)]), .invalidCueTiming(0)),
            (.init(startSeconds: 0, endSeconds: 1, text: "", words: [word(" Lost", 0, 1)]), .textMismatch(0))
        ]
        for (segment, error) in invalid {
            let input = try evidence([segment])
            #expect(throws: error) { try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 20_000) }
        }
        let overlapping = try evidence([raw([word(" First", 0, 2)]), raw([word(" Second", 1, 3)])])
        #expect(throws: SubtitleSegmentationError.invalidSegment(1)) {
            try SubtitleSegmenter.segment(overlapping, sourceID: sourceID, mediaDurationMilliseconds: 20_000)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_TRANSCRIPTION_EVIDENCE_DIRECTORY"] != nil))
    func realSavedProviderEvidenceProducesCuesOrExplicitFailure() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXLINE_TRANSCRIPTION_EVIDENCE_DIRECTORY"])
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        var completed = 0
        var rejected = 0
        var cueCount = 0
        for file in files {
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let input = try decoder.decode(TranscriptionEvidence.self, from: Data(contentsOf: file))
            if input.outcome != .completed {
                #expect(throws: SubtitleSegmentationError.incompleteTranscription) {
                    try SubtitleSegmenter.segment(input, sourceID: sourceID, mediaDurationMilliseconds: 1_077_718)
                }
                rejected += 1
                continue
            }
            let chunkID = try #require(UUID(uuidString: file.deletingPathExtension().lastPathComponent))
            let output = try SubtitleSegmenter.segment(input, sourceID: chunkID, mediaDurationMilliseconds: 1_077_718)
            #expect(output.evidence.segments == input.segments)
            #expect(output.cues.map(\.sourceText).joined().filter { !$0.isWhitespace } ==
                    input.segments.map(\.text).joined().filter { !$0.isWhitespace })
            #expect(Set(output.cues.map(\.id)).count == output.cues.count)
            completed += 1
            cueCount += output.cues.count
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let data = try encoder.encode(output)
            let reopened = try decoder.decode(SubtitleSegmentationResult.self, from: data)
            #expect(output.entries == reopened.entries)
            try FileManager.default.createDirectory(atPath: "tmp/segmentation-validation", withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: "tmp/segmentation-validation").appendingPathComponent(file.lastPathComponent), options: .atomic)
        }
        #expect(completed > 0)
        #expect(rejected > 0)
        print("S001_SEGMENTATION completed=\(completed) rejected=\(rejected) cues=\(cueCount)")
    }
}
