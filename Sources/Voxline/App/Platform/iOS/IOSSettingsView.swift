#if os(iOS)
import SwiftUI
import VoxlineCore

struct IOSSettingsView: View {
    var body: some View {
        Form {
            Section(String(localized: "本地处理", bundle: appLocalizationBundle)) {
                NavigationLink { ModelManagementView() } label: { Label(String(localized: "模型管理", bundle: appLocalizationBundle), systemImage: "cpu") }
                NavigationLink { AppleTranslationLanguagesView() } label: { Label(String(localized: "Apple 本机翻译", bundle: appLocalizationBundle), systemImage: "character.book.closed") }
            }
            Section(String(localized: "同步", bundle: appLocalizationBundle)) {
                NavigationLink { TaskSyncSettingsView() } label: { Label(String(localized: "iCloud 同步", bundle: appLocalizationBundle), systemImage: "arrow.triangle.2.circlepath") }
            }
            Section(String(localized: "云端服务", bundle: appLocalizationBundle)) {
                NavigationLink { CloudTranscriptionServicesSettingsView() } label: { Label(String(localized: "云端转写服务", bundle: appLocalizationBundle), systemImage: "waveform.badge.mic") }
                NavigationLink { TranslationServicesSettingsView() } label: { Label(String(localized: "翻译服务", bundle: appLocalizationBundle), systemImage: "character.book.closed") }
            }
        }
        .navigationTitle(String(localized: "设置", bundle: appLocalizationBundle))
    }
}

#endif
