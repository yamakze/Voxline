#if os(macOS)
import AppKit
import VoxlineWorkflow

extension TaskLibrary {
    static let shared = TaskLibrary(
        tasksDirectory: URL.applicationSupportDirectory.appendingPathComponent("Voxline/Tasks", isDirectory: true),
        recentDocumentURLs: { NSDocumentController.shared.recentDocumentURLs },
        noteRecentDocument: { NSDocumentController.shared.noteNewRecentDocumentURL($0) },
        forgetRecentDocument: { removed in
            let controller = NSDocumentController.shared
            let retained = controller.recentDocumentURLs.filter { $0 != removed }
            controller.clearRecentDocuments(nil)
            for url in retained.reversed() { controller.noteNewRecentDocumentURL(url) }
        }
    )
}

extension TaskProcessingQueue {
    static let shared = TaskProcessingQueue(library: .shared, translationPipeline: ConfiguredSubtitleTranslationPipeline())
}

#endif
