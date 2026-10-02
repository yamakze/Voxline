import SwiftUI

@main
struct VoxlineApp: App {
    var body: some Scene {
        Window("Voxline · 任务", id: "tasks") {
            TaskLibraryView()
        }.defaultSize(width: 1060, height: 700)
        DocumentGroup(newDocument: VoxlineDocument()) { configuration in
            TaskDocumentView(document: configuration.$document, fileURL: configuration.fileURL)
        }
        .commands { TaskNavigationCommands() }
    }
}

struct TaskNavigationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("任务列表") { openWindow(id: "tasks") }.keyboardShortcut("1", modifiers: [.command])
        }
    }
}
