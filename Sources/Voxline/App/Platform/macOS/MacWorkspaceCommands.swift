#if os(macOS)
import AppKit
import SwiftUI

struct WorkspaceFileActions {
    let createTask: () -> Void
    let openTask: () -> Void
}

private struct WorkspaceFileActionsKey: FocusedValueKey {
    typealias Value = WorkspaceFileActions
}

extension FocusedValues {
    var workspaceFiles: WorkspaceFileActions? {
        get { self[WorkspaceFileActionsKey.self] }
        set { self[WorkspaceFileActionsKey.self] = newValue }
    }
}

struct MacWorkspaceCommands: Commands {
    @FocusedValue(\.workspaceFiles) private var files

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "新建标签页", bundle: appLocalizationBundle)) {
                NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(String(localized: "新建任务", bundle: appLocalizationBundle)) {
                files?.createTask()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(files == nil)

            Button(String(localized: "打开任务文件…", bundle: appLocalizationBundle)) {
                files?.openTask()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(files == nil)
        }
    }
}
#endif
