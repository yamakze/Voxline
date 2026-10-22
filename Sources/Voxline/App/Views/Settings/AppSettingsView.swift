import SwiftUI
import VoxlineCore

public struct AppSettingsView: View {
    public enum Tab: String, CaseIterable, Identifiable {
        #if os(macOS)
        case appearance = "外观"
        #endif
        case models = "模型管理"
        case sync = "iCloud 同步"
        case updates = "更新"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            #if os(macOS)
            case .appearance: return "paintpalette"
            #endif
            case .models: return "cpu"
            case .sync: return "arrow.triangle.2.circlepath"
            case .updates: return "arrow.clockwise.circle"
            }
        }
    }

    @State public var selectedTab: Tab

    #if os(macOS)
    public init(initialTab: Tab = .appearance) {
        _selectedTab = State(initialValue: initialTab)
    }
    #else
    public init(initialTab: Tab = .models) {
        _selectedTab = State(initialValue: initialTab)
    }
    #endif

    public var body: some View {
        Group {
            switch selectedTab {
            #if os(macOS)
            case .appearance:
                AppearanceSettingsView()
            #endif
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
                .frame(width: 520)
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
