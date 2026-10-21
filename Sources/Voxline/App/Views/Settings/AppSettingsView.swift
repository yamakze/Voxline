import SwiftUI
import VoxlineCore

public struct AppSettingsView: View {
    public enum Tab: String, CaseIterable, Identifiable {
        case models = "模型管理"
        case sync = "iCloud 同步"
        case updates = "更新"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .models: return "cpu"
            case .sync: return "arrow.triangle.2.circlepath"
            case .updates: return "arrow.clockwise.circle"
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
            case .sync:
                TaskSyncSettingsView()
            case .updates:
                AppUpdatesSettingsView()
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
                .frame(width: 480)
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
