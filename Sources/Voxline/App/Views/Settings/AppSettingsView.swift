import SwiftUI
import VoxlineCore

public struct AppSettingsView: View {
    public enum Tab: String, CaseIterable, Identifiable {
        case models = "模型管理"
        case translation = "翻译服务"
        case appleLanguages = "本机语言"
        case cloudTranscription = "云端转写"
        case sync = "iCloud 同步"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .models: return "cpu"
            case .appleLanguages: return "character.book.closed"
            case .translation: return "character.book.closed"
            case .cloudTranscription: return "waveform.badge.mic"
            case .sync: return "arrow.triangle.2.circlepath"
            }
        }
    }

    @State public var selectedTab: Tab

    public init(initialTab: Tab = .models) {
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        Group {
            switch selectedTab {
            case .models:
                ModelManagementView()
            case .appleLanguages:
                AppleTranslationLanguagesView()
            case .translation:
                TranslationServicesSettingsView()
            case .cloudTranscription:
                CloudTranscriptionServicesSettingsView()
            case .sync:
                TaskSyncSettingsView()
            }
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(String(localized: String.LocalizationValue(tab.rawValue), bundle: appLocalizationBundle)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
            }
        }
        #elseif os(iOS)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(String(localized: String.LocalizationValue(tab.rawValue), bundle: appLocalizationBundle)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        #endif
        .navigationTitle(String(localized: "设置", bundle: appLocalizationBundle))
    }
}
