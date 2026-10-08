import Foundation
import Testing
@testable import VoxlineApp
@testable import VoxlineCore
@testable import VoxlineMedia
@testable import VoxlineTranslation
@testable import VoxlineWhisperKit
@testable import VoxlineWorkflow

@Suite("Native localization resources")
struct LocalizationTests {
    @Test func modulesContainMatchingChineseAndEnglishResources() throws {
        let bundles = [appLocalizationBundle, VoxlineCore.voxlineLocalizationBundle,
            VoxlineMedia.voxlineLocalizationBundle, VoxlineTranslation.voxlineLocalizationBundle,
            VoxlineWhisperKit.voxlineLocalizationBundle, VoxlineWorkflow.voxlineLocalizationBundle]
        for bundle in bundles {
            let englishURL = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj"))
            let chineseURL = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "zh-Hans.lproj"))
            let english = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: englishURL), format: nil) as? [String: String])
            let chinese = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: chineseURL), format: nil) as? [String: String])
            #expect(!english.isEmpty)
            #expect(Set(english.keys) == Set(chinese.keys))
            for (key, value) in english {
                #expect(!value.isEmpty)
                // Formatting type and position must survive translation, including reordered arguments.
                let pattern = #"%(?:(\d+)\$)?([-+0 #]*\d*(?:\.\d+)?(?:ll|l|z)?[@dfiu])"#
                let regex = try NSRegularExpression(pattern: pattern)
                func arguments(_ text: String) -> [String: String] {
                    var result: [String: String] = [:]
                    for (index, match) in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated() {
                        let position = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? String(index + 1)
                        let type = Range(match.range(at: 2), in: text).map { String(text[$0]) }!
                        result[position] = type
                    }
                    return result
                }
                #expect(arguments(key) == arguments(value))
            }
        }
    }

    @Test func foundationResolvesCountsInterpolationAndModuleErrors() throws {
        let app = appLocalizationBundle
        let englishPath = try #require(app.path(forResource: "en", ofType: "lproj"))
        let english = try #require(Bundle(path: englishPath))
        let chinesePath = try #require(app.url(forResource: "Localizable", withExtension: "strings", subdirectory: "zh-Hans.lproj")?.deletingLastPathComponent().path)
        let chinese = try #require(Bundle(path: chinesePath))
        #expect(String(localized: "\(1) 条字幕", bundle: english, locale: Locale(identifier: "en")) == "1 subtitle")
        #expect(String(localized: "\(2) 条字幕", bundle: english, locale: Locale(identifier: "en")) == "2 subtitles")
        #expect(String(localized: "\(2) 条字幕", bundle: chinese, locale: Locale(identifier: "zh-Hans")) == "2 条字幕")
        #expect(String(localized: "媒体“\("user.mp4")”尚未选择音轨。", bundle: english, locale: Locale(identifier: "en")).contains("user.mp4"))
        let mediaPath = try #require(VoxlineMedia.voxlineLocalizationBundle.path(forResource: "en", ofType: "lproj"))
        let media = try #require(Bundle(path: mediaPath))
        #expect(String(localized: "提取音频的时间超出源媒体范围。", bundle: media) == "Extracted audio extends beyond the source media.")
    }
}
