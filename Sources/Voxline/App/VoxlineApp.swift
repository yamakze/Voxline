import SwiftUI
import VoxlineWorkflow
#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        VoxlineIconManager.shared.ensureDockIconIsSet()
    }
}
#endif

@main
struct VoxlineApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        VoxlineIconManager.shared.ensureDockIconIsSet()
    }
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            MainWindowView()
                .tint(Color.voxlineAccent)
                .task { TaskSyncSettings.shared.restore() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1140, height: 740)
        .commands {
            TaskNavigationCommands()
        }

        Settings {
            AppSettingsView()
                .frame(minWidth: 720, minHeight: 520)
        }
        #elseif os(iOS)
        WindowGroup {
            IOSTaskLibraryView()
                .background(AppleTranslationSessionHost())
                .task { TaskSyncSettings.shared.restore() }
        }
        #endif
    }
}

#if os(macOS)
struct TaskNavigationCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
        }
    }
}
#endif
