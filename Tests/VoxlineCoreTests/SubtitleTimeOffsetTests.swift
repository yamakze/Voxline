import Foundation
import Testing
@testable import VoxlineCore

@Suite("Atomic subtitle timing offsets")
struct SubtitleTimeOffsetTests {
    @Test func offsetKeepsTextIDsAndTranslationAndRejectsInvalidWholeTimeline() throws {
        var first = try SubtitleCue(id: UUID(), startMilliseconds: 200, endMilliseconds: 500, sourceText: "First")
        first.translation = .succeeded(text: "第一句", sourceRevision: first.sourceRevision)
        let last = try SubtitleCue(id: UUID(), startMilliseconds: 500, endMilliseconds: 900, sourceText: "Second")
        let original = [first, last]
        let result = try SubtitleTimeOffset.shifted(original, by: 100, withinDuration: 1000)
        #expect(result.map(\.id) == original.map(\.id))
        #expect(result.map(\.sourceText) == original.map(\.sourceText))
        #expect(result.map(\.sourceRevision) == original.map(\.sourceRevision))
        #expect(result.map(\.translation) == original.map(\.translation))
        #expect(result.map(\.startMilliseconds) == [300, 600])
        #expect(result.map(\.endMilliseconds) == [600, 1000])
        #expect(throws: SubtitleTimeOffsetError.negativeTime) {
            try SubtitleTimeOffset.shifted(original, by: -201, withinDuration: 1000)
        }
        #expect(throws: DomainValidationError.cueOutsideMedia(last.id)) {
            try SubtitleTimeOffset.shifted(original, by: 101, withinDuration: 1000)
        }
        #expect(original == [first, last])
        let huge = try SubtitleCue(id: UUID(), startMilliseconds: Int64.max - 100, endMilliseconds: Int64.max, sourceText: "Huge")
        #expect(throws: SubtitleTimeOffsetError.invalidOffset) {
            try SubtitleTimeOffset.shifted([huge], by: 1, withinDuration: nil)
        }
    }

    @Test func nonFiniteAndUnrepresentableInputIsExplicitAndMillisecondRoundingIsStable() throws {
        for invalid in [Double.nan, .infinity, -.infinity, Double(Int64.max) / 1000, -Double.greatestFiniteMagnitude] {
            #expect(throws: SubtitleTimeOffsetError.invalidOffset) { try SubtitleTimeOffset.milliseconds(from: invalid) }
        }
        #expect(try SubtitleTimeOffset.milliseconds(from: 0.0006) == 1)
        #expect(try SubtitleTimeOffset.milliseconds(from: -0.0006) == -1)
        #expect(try SubtitleTimeOffset.milliseconds(from: 0.2) == 200)
    }
}
