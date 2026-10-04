import Foundation
import Testing
import Translation
import VoxlineCore
@testable import VoxlineApp

@Suite("Apple subtitle result mapping") @MainActor
struct AppleTranslationTests {
    @Test func equivalentLanguageIdentifiersPreserveChineseScriptAndRegionalEnglish() {
        let languages = [Locale.Language(identifier: "zh"), .init(identifier: "zh-TW"),
                         .init(identifier: "en"), .init(identifier: "en-GB")]
        #expect(AppleTranslationCoordinator.matchingLanguage("zh-Hans", in: languages)?.minimalIdentifier == "zh")
        #expect(AppleTranslationCoordinator.matchingLanguage("zh-Hant-TW", in: languages)?.minimalIdentifier == "zh-TW")
        #expect(AppleTranslationCoordinator.matchingLanguage("en-GB", in: languages)?.minimalIdentifier == "en-GB")
        #expect(AppleTranslationCoordinator.matchingLanguage("xx-XX", in: languages) == nil)
    }

    @Test func resultsUseIDsAndRejectPartialDuplicateUnknownOrBlankText() throws {
        let cues = try (0..<2).map {
            try SubtitleCue(id: UUID(), startMilliseconds: Int64($0 * 1000),
                            endMilliseconds: Int64($0 * 1000 + 500), sourceText: "Line \($0)")
        }
        let inputs = cues.map(TranslationBatchInput.init)
        func response(_ id: String?, _ text: String) -> TranslationSession.Response {
            .init(sourceLanguage: .init(identifier: "en"), targetLanguage: .init(identifier: "zh-Hans"),
                  sourceText: "Line", targetText: text, clientIdentifier: id)
        }
        let first = response(cues[0].id.uuidString, "第一句")
        let second = response(cues[1].id.uuidString, "第二句")
        let outputs = try AppleTranslationCoordinator.outputs([second, first], inputs: inputs)
        #expect(outputs.map(\.cueID) == cues.map(\.id))
        #expect(outputs.map(\.text) == ["第一句", "第二句"])
        for invalid in [[first], [first, first], [first, response(UUID().uuidString, "未知")],
                        [first, response(nil, "无 ID")], [first, response(cues[1].id.uuidString, "  ")]] {
            #expect(throws: AppleSubtitleTranslationError.self) {
                try AppleTranslationCoordinator.outputs(invalid, inputs: inputs)
            }
        }
    }
}
