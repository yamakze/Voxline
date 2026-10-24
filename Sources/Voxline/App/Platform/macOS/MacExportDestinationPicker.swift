#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
enum MacExportDestinationPicker {
    static func choose(suggestedName: String, contentType: UTType) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else { panel.begin { continuation.resume(returning: $0) } }
        }
        guard response == .OK, !Task.isCancelled else { return nil }
        return panel.url
    }
}
#endif
