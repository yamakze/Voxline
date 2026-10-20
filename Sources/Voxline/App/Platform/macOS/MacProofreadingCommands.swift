#if os(macOS)
import SwiftUI

private struct FindSubtitleKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var findSubtitle: (() -> Void)? {
        get { self[FindSubtitleKey.self] }
        set { self[FindSubtitleKey.self] = newValue }
    }
}

struct MacProofreadingCommands: Commands {
    @FocusedValue(\.findSubtitle) private var findSubtitle

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(String(localized: "查找字幕…", bundle: appLocalizationBundle)) {
                findSubtitle?()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(findSubtitle == nil)
        }
    }
}
#endif
