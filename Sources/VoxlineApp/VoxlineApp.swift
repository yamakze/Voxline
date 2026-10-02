import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        VoxlineIconManager.shared.ensureDockIconIsSet()
    }
}

@main
struct VoxlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        VoxlineIconManager.shared.ensureDockIconIsSet()
    }

    var body: some Scene {
        Window("Voxline", id: "main") {
            MainWindowView()
                .tint(Color.voxlineAccent)
        }
        .defaultSize(width: 1140, height: 740)
        .commands {
            TaskNavigationCommands()
        }
    }
}

struct TaskNavigationCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
        }
    }
}
