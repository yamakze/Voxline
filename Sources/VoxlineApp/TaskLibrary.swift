import AppKit
import Foundation
import Observation
import VoxlineCore

@Observable
@MainActor
public final class TaskLibrary {
    public static let shared = TaskLibrary()

    public var entries: [Entry] = []
    public private(set) var errorMessage: String?
    public private(set) var openTasks: [UUID: Entry] = [:]

    public struct Entry: Identifiable, Sendable {
        public let id: String
        public let taskID: UUID
        public let url: URL?
        public var task: ProcessingTask?
        public let error: String?
        public var title: String { task?.title ?? url?.deletingPathExtension().lastPathComponent ?? "未命名任务" }
    }

    public let tasksDirectory: URL

    init(tasksDirectory: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.tasksDirectory = tasksDirectory ?? appSupport.appendingPathComponent("Voxline/Tasks", isDirectory: true)
        refresh()
    }

    public func task(for id: UUID) -> ProcessingTask? {
        if let entry = openTasks[id], let task = entry.task {
            return task
        }
        return entries.first(where: { $0.taskID == id })?.task
    }

    public func url(for id: UUID) -> URL? {
        openTasks[id]?.url ?? entries.first(where: { $0.taskID == id })?.url
    }

    public func register(_ task: ProcessingTask, at url: URL?) {
        let fileURL = url ?? defaultURL(for: task.id)
        if openTasks[task.id]?.url != fileURL {
            NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
        }
        let entry = Entry(id: task.id.uuidString, taskID: task.id, url: fileURL, task: task, error: nil)
        openTasks[task.id] = entry
        entries.removeAll { $0.taskID == task.id || $0.url == fileURL }
        entries.insert(entry, at: 0)
    }

    public func defaultURL(for taskID: UUID) -> URL {
        tasksDirectory.appendingPathComponent(taskID.uuidString).appendingPathExtension("voxline")
    }

    public func save(_ task: ProcessingTask, at url: URL? = nil) throws {
        let targetURL = url ?? self.url(for: task.id) ?? defaultURL(for: task.id)
        try persist(task, to: targetURL)
        register(task, at: targetURL)
    }

    private func persist(_ task: ProcessingTask, to url: URL) throws {
        let data = try TaskDocumentCodec.encode(task)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func delete(taskID: UUID) throws {
        let fileURL = self.url(for: taskID)
        if let fileURL { try FileManager.default.removeItem(at: fileURL) }
        openTasks[taskID] = nil
        entries.removeAll { $0.taskID == taskID }
    }

    public func refresh() {
        errorMessage = nil
        var foundEntries: [Entry] = []
        var seenIDs = Set<UUID>()

        // 1. In-memory open tasks
        for (id, entry) in openTasks {
            seenIDs.insert(id)
            foundEntries.append(entry)
        }

        // 2. Saved tasks in Application Support
        do {
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
            let taskFiles = try FileManager.default.contentsOfDirectory(at: tasksDirectory, includingPropertiesForKeys: nil)
            for fileURL in taskFiles where fileURL.pathExtension == "voxline" {
                let access = fileURL.startAccessingSecurityScopedResource()
                defer { if access { fileURL.stopAccessingSecurityScopedResource() } }

                do {
                    var task = try TaskDocumentCodec.decode(Data(contentsOf: fileURL))
                    task.interruptRunningItems()
                    if !seenIDs.contains(task.id) {
                        seenIDs.insert(task.id)
                        foundEntries.append(Entry(id: task.id.uuidString, taskID: task.id, url: fileURL, task: task, error: nil))
                    }
                } catch {
                    foundEntries.append(Entry(id: fileURL.absoluteString, taskID: UUID(), url: fileURL,
                                              task: nil, error: error.localizedDescription))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        // 3. System recent documents
        for url in NSDocumentController.shared.recentDocumentURLs {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            do {
                var task = try TaskDocumentCodec.decode(Data(contentsOf: url))
                task.interruptRunningItems()
                if !seenIDs.contains(task.id) {
                    seenIDs.insert(task.id)
                    foundEntries.append(Entry(id: url.absoluteString, taskID: task.id, url: url, task: task, error: nil))
                }
            } catch {
                if !foundEntries.contains(where: { $0.url == url }) {
                    foundEntries.append(Entry(id: url.absoluteString, taskID: UUID(), url: url, task: nil, error: error.localizedDescription))
                }
            }
        }

        entries = foundEntries.sorted { ($0.task?.startedAt ?? Date.distantPast) > ($1.task?.startedAt ?? Date.distantPast) }
    }
}
