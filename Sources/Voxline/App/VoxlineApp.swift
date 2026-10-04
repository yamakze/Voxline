import SwiftUI
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
        WindowGroup {
            #if os(macOS)
            MainWindowView()
                .tint(Color.voxlineAccent)
            #elseif os(iOS)
            IOSTaskLibraryView()
            #endif
        }
        #if os(macOS)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1140, height: 740)
        .commands {
            TaskNavigationCommands()
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
