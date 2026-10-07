import SwiftUI
import VoxlineCore

public struct AppSettingsView: View {
    public enum Tab: String, CaseIterable, Identifiable {
        case models = "模型管理"
        case translation = "翻译服务"
        case cloudTranscription = "云端转写"
        case sync = "iCloud 同步"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .models: return "cpu"
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
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Picker("设置分类", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()
            #endif

            Group {
                switch selectedTab {
                case .models:
                    ModelManagementView()
                case .translation:
                    TranslationServicesSettingsView()
                case .cloudTranscription:
                    CloudTranscriptionServicesSettingsView()
                case .sync:
                    TaskSyncSettingsView()
                }
            }
        }
        .navigationTitle("设置")
    }
}
