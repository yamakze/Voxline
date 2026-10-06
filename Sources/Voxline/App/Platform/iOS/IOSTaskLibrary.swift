#if os(iOS)
import UIKit
import Observation
import SwiftUI
import VoxlineCore
import VoxlineWorkflow
import VoxlineTranslation

/// The shared task store owns results; iOS always imports into an independent Documents copy.
@MainActor @Observable
final class IOSTaskLibrary {
    static let shared = IOSTaskLibrary()
    let storage: TaskLibrary
    let queue: TaskProcessingQueue
    var errorMessage: String?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    var tasks: [ProcessingTask] {
        storage.entries.compactMap(\.task)
    }

    init(directory: URL = .documentsDirectory, pipeline: any MediaTranscriptionPipeline = LocalMediaTranscriptionPipeline(),
         resourceCleanup: TaskResourceCleanup = .init()) {
        let storage = TaskLibrary(tasksDirectory: directory, resourceCleanup: resourceCleanup)
        self.storage = storage
        queue = TaskProcessingQueue(library: storage, pipeline: pipeline, translationPipeline: ConfiguredSubtitleTranslationPipeline())
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

    func bindTranslationService(_ service: TranslationServiceConfig, taskID: UUID) throws {
        guard var task = storage.task(for: taskID), let settings = task.parameters.translation,
              let api = settings.api else { throw CheckpointError.taskUnavailable }
        var parameters = task.parameters
        parameters.translation = try TranslationSettings(baseURL: service.baseURL, modelID: service.modelID,
            targetLanguage: settings.targetLanguage, serviceID: service.id,
            batchSize: settings.batchSize, systemPrompt: api.systemPrompt)
        try task.updateParameters(parameters)
        try save(task)
    }

    func startTranslation(taskID: UUID, mediaID: UUID) throws {
        guard let task = storage.task(for: taskID), task.parameters.translation != nil,
              let item = task.items.first(where: { $0.id == mediaID }),
              item.hasCompletedTranscription else {
            throw QueueError.unavailable("本机翻译需要启用翻译且已完成转写的任务成果。")
        }
        try queue.start(taskID: taskID, mediaID: mediaID)
    }

    func task(_ id: UUID) -> ProcessingTask? { storage.task(for: id) }

    func handleScenePhaseChange(to phase: ScenePhase) {
        if phase == .background {
            guard queue.taskID != nil, backgroundTaskID == .invalid else { return }
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VoxlineTaskProcessing") { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? self.queue.cancel()
                    self.endBackgroundTask()
                }
            }
        } else if phase == .active {
            if queue.taskID == nil {
                endBackgroundTask()
            }
        }
    }

    func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
}
#endif
