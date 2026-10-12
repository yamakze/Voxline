#if os(iOS)
import SwiftUI
import VoxlineCore

public struct IOSRootView: View {
    @State private var selectedTab: IOSTab = .tasks

    public enum IOSTab: Hashable {
        case tasks
        case settings
    }

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            IOSTaskLibraryView()
                .tabItem {
                    Label(String(localized: "任务", bundle: appLocalizationBundle), systemImage: "tray.full")
                }
                .tag(IOSTab.tasks)

            NavigationStack {
                IOSSettingsView()
            }
            .tabItem {
                Label(String(localized: "设置", bundle: appLocalizationBundle), systemImage: "gearshape")
            }
            .tag(IOSTab.settings)
        }
        .tint(Color.voxlineAccent)
    }
}
#endif
