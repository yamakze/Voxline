import AppKit
import Observation
import VoxlineCore

/// Recent-file metadata is read from the system document list, never a second result store.
@Observable
@MainActor
final class TaskLibrary {
    static let shared = TaskLibrary()
    var entries: [Entry] = []
    private var openTasks: [UUID: Entry] = [:]

    struct Entry: Identifiable {
        let id: String
        let url: URL?
        let task: ProcessingTask?
        let error: String?
        var title: String { task?.title ?? url?.deletingPathExtension().lastPathComponent ?? "未命名任务" }
    }

    func register(_ task: ProcessingTask, at url: URL?) {
        if let url, openTasks[task.id]?.url != url {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        openTasks[task.id] = Entry(id: task.id.uuidString, url: url, task: task, error: nil)
        entries.removeAll { $0.id == task.id.uuidString || (url != nil && $0.url == url) }
        if let entry = openTasks[task.id] { entries.insert(entry, at: 0) }
    }

    func removeOpenTask(_ id: UUID) {
        openTasks[id] = nil
        refresh()
    }

    func refresh() {
        var recent: [Entry] = []
        let openURLs = Set(openTasks.values.compactMap(\.url))
        for url in NSDocumentController.shared.recentDocumentURLs where !openURLs.contains(url) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                var task = try TaskDocumentCodec.decode(Data(contentsOf: url))
                task.interruptRunningItems()
                recent.append(Entry(id: url.absoluteString, url: url, task: task, error: nil))
            } catch {
                recent.append(Entry(id: url.absoluteString, url: url, task: nil, error: error.localizedDescription))
            }
        }
        entries = openTasks.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } + recent
    }
}
