import SwiftUI
import VoxlineCore

struct AppleTranslationLanguagesView: View {
    @State private var source: String
    @State private var target: String
    @State private var batchSize = TranslationSettings.defaultBatchSize

    init(source: String = "en", target: String = "zh-Hans") {
        _source = State(initialValue: source)
        _target = State(initialValue: target)
    }

    var body: some View {
        Form {
            Section(String(localized: "语言准备", bundle: appLocalizationBundle)) {
                AppleTranslationLanguageSettings(source: $source, target: $target,
                    batchSize: $batchSize, preparesInPlace: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Apple 本机翻译", bundle: appLocalizationBundle))
    }
}
