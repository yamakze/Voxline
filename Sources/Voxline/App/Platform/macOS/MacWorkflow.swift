#if os(macOS)
import AppKit
import VoxlineWorkflow

extension TaskLibrary {
    static let shared = TaskLibrary(
        tasksDirectory: URL.applicationSupportDirectory.appendingPathComponent("Voxline/Tasks", isDirectory: true),
        recentDocumentURLs: { NSDocumentController.shared.recentDocumentURLs },
        noteRecentDocument: { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
    )
}

extension TaskProcessingQueue {
    static let shared = TaskProcessingQueue(library: .shared, translationPipeline: ConfiguredSubtitleTranslationPipeline())
}

#endif
