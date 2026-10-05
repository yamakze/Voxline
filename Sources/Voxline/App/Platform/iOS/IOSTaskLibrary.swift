#if os(iOS)
import Foundation
import Observation
import VoxlineCore
import VoxlineWorkflow

/// The shared task store owns results; iOS always imports into an independent Documents copy.
@MainActor @Observable
final class IOSTaskLibrary {
    let storage: TaskLibrary
    let queue: TaskProcessingQueue
    var errorMessage: String?
    var tasks: [ProcessingTask] {
        storage.entries.compactMap(\.task).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    init(directory: URL = .documentsDirectory) {
        let storage = TaskLibrary(tasksDirectory: directory)
        self.storage = storage
        queue = TaskProcessingQueue(library: storage, translationPipeline: ConfiguredSubtitleTranslationPipeline())
    }

    func load() {
        storage.refresh()
        let failures = storage.entries.compactMap { entry in entry.error.map { "\(entry.title)：\($0)" } }
        errorMessage = ([storage.errorMessage].compactMap { $0 } + failures).joined(separator: "\n")
        if errorMessage?.isEmpty == true { errorMessage = nil }
    }

    func readImportedTask(from url: URL) throws -> ProcessingTask {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var task = try TaskDocumentCodec.decode(Data(contentsOf: url))
        task.interruptRunningItems()
        return task
    }

    func save(_ task: ProcessingTask) throws {
        guard queue.taskID != task.id else { throw QueueError.busy }
        try storage.save(task, at: storage.defaultURL(for: task.id))
    }

    func startTranslation(taskID: UUID, mediaID: UUID) throws {
        guard let task = storage.task(for: taskID), task.parameters.translation != nil,
              let item = task.items.first(where: { $0.id == mediaID }),
              let checkpoint = item.checkpoint, !checkpoint.chunks.isEmpty,
              checkpoint.chunks.allSatisfy(\.isCompleted) else {
            throw QueueError.unavailable("本机翻译需要启用翻译且已完成转写的任务成果。")
        }
        try queue.start(taskID: taskID, mediaID: mediaID)
    }

    func task(_ id: UUID) -> ProcessingTask? { storage.task(for: id) }
}
#endif
