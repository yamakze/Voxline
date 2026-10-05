#if os(iOS)
import SwiftUI
import VoxlineCore

struct IOSSettingsView: View {
    var body: some View {
        Form {
            Section("本地处理") {
                NavigationLink { ModelManagementView() } label: { Label("模型管理", systemImage: "cpu") }
                NavigationLink { IOSAppleLanguagesView() } label: { Label("Apple 本机翻译", systemImage: "character.book.closed") }
            }
            Section("翻译服务") {
                NavigationLink { TranslationServicesSettingsView() } label: { Label("OpenAI 兼容接口", systemImage: "network") }
            }
        }
        .navigationTitle("设置")
    }
}

struct IOSAppleLanguagesView: View {
    var settings: TranslationSettings?
    @State private var source = "en"
    @State private var target = "zh-Hans"
    @State private var batchSize = TranslationSettings.defaultBatchSize

    var body: some View {
        Form {
            Section("语言准备") {
                if let settings, case .appleTranslation(let sourceID) = settings.engine {
                    AppleTranslationLanguageSettings(source: .constant(sourceID), target: .constant(settings.targetLanguage),
                                                     batchSize: .constant(settings.batchSize), allowsEditing: false)
                } else {
                    AppleTranslationLanguageSettings(source: $source, target: $target, batchSize: $batchSize)
                }
            }
        }
        .navigationTitle("Apple 本机翻译")
    }
}
#endif
