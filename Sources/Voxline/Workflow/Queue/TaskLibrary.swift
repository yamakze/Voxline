import Foundation
import Observation
import VoxlineCore

@Observable
@MainActor
public final class TaskLibrary {
    public private(set) var entries: [Entry] = []
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
    private var orderedURLs: [URL] = []
    private var orderURL: URL { tasksDirectory.appendingPathComponent("task-order.json") }
    private let recentDocumentURLs: @MainActor () -> [URL]
    private let noteRecentDocument: @MainActor (URL) -> Void

    public init(tasksDirectory: URL, recentDocumentURLs: @escaping @MainActor () -> [URL] = { [] },
                noteRecentDocument: @escaping @MainActor (URL) -> Void = { _ in }) {
        self.tasksDirectory = tasksDirectory
        self.recentDocumentURLs = recentDocumentURLs
        self.noteRecentDocument = noteRecentDocument
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
            noteRecentDocument(fileURL)
        }
        let entry = Entry(id: task.id.uuidString, taskID: task.id, url: fileURL, task: task, error: nil)
        openTasks[task.id] = entry
        let position = entries.firstIndex { $0.taskID == task.id || $0.url == fileURL } ?? 0
        entries.removeAll { $0.taskID == task.id || $0.url == fileURL }
        entries.insert(entry, at: min(position, entries.count))
    }

    public func defaultURL(for taskID: UUID) -> URL {
        tasksDirectory.appendingPathComponent(taskID.uuidString).appendingPathExtension("voxline")
    }

    public func save(_ task: ProcessingTask, at url: URL? = nil) throws {
        let targetURL = url ?? self.url(for: task.id) ?? defaultURL(for: task.id)
        try persist(task, to: targetURL)
        register(task, at: targetURL)
    }

    /// Editing views keep their draft until this validated, atomic save succeeds.
    public func updateItem(_ item: TaskMediaItem, taskID: UUID, comparedTo original: TaskMediaItem) throws {
        guard var task = task(for: taskID),
              let index = task.items.firstIndex(where: { $0.id == original.id }),
              task.items[index] == original, item.id == original.id else { throw TaskValidationError.taskChanged }
        task.items[index] = item
        try save(task)
    }

    /// Apply worker results to the latest published edits; publish only after the whole document is saved.
    @discardableResult
    public func commitCheckpoint<Result>(taskID: UUID, mutation: (inout ProcessingTask) throws -> Result) throws -> Result {
        guard var current = task(for: taskID) else { throw CheckpointError.taskUnavailable }
        let result = try mutation(&current)
        guard current.id == taskID else { throw TaskValidationError.taskChanged }
        try save(current)
        return result
    }

    private func persist(_ task: ProcessingTask, to url: URL) throws {
        let data = try TaskDocumentCodec.encode(task)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func delete(taskID: UUID) throws {
        guard let entry = entries.first(where: { $0.taskID == taskID }) else { throw CheckpointError.taskUnavailable }
        try delete(entryID: entry.id)
    }

    public func delete(entryID: String) throws {
        guard let entry = entries.first(where: { $0.id == entryID }), let url = entry.url else {
            throw CheckpointError.taskUnavailable
        }
        guard entry.task?.status != .running else { throw CheckpointError.workRunning }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.removeItem(at: url)
        openTasks[entry.taskID] = nil
        entries.removeAll { $0.id == entryID }
    }

    /// Persist list order separately from immutable processing results.
    public func move(entryID: String, to destinationID: String) throws {
        guard let from = entries.firstIndex(where: { $0.id == entryID }),
              let to = entries.firstIndex(where: { $0.id == destinationID }) else { throw CheckpointError.taskUnavailable }
        guard entryID != destinationID else { return }
        var reordered = entries
        let entry = reordered.remove(at: from)
        reordered.insert(entry, at: to)
        try reorder(entryIDs: reordered.map(\.id))
    }

    public func reorder(entryIDs: [String]) throws {
        guard entryIDs.count == entries.count, Set(entryIDs) == Set(entries.map(\.id)) else {
            throw TaskValidationError.taskChanged
        }
        let current = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let reordered = entryIDs.map { current[$0]! }
        let urls = reordered.compactMap(\.url)
        try JSONEncoder().encode(urls).write(to: orderURL, options: .atomic)
        orderedURLs = urls
        entries = reordered
    }

    public func refresh() {
        errorMessage = nil
        do {
            orderedURLs = FileManager.default.fileExists(atPath: orderURL.path)
                ? try JSONDecoder().decode([URL].self, from: Data(contentsOf: orderURL)) : []
        } catch { errorMessage = "任务顺序读取失败：\(error.localizedDescription)" }
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
        for url in recentDocumentURLs() {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            do {
                var task = try TaskDocumentCodec.decode(Data(contentsOf: url))
                task.interruptRunningItems()
                if !seenIDs.contains(task.id) {
                    seenIDs.insert(task.id)
                    foundEntries.append(Entry(id: url.absoluteString, taskID: task.id, url: url, task: task, error: nil))
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // Deleted documents can remain in the system's recent-document list.
                continue
            } catch {
                if !foundEntries.contains(where: { $0.url == url }) {
                    foundEntries.append(Entry(id: url.absoluteString, taskID: UUID(), url: url, task: nil, error: error.localizedDescription))
                }
            }
        }

        entries = foundEntries.sorted {
            let left = $0.url.flatMap { orderedURLs.firstIndex(of: $0) }
            let right = $1.url.flatMap { orderedURLs.firstIndex(of: $0) }
            if left != right { return (left ?? -1) < (right ?? -1) }
            if $0.task?.startedAt != $1.task?.startedAt {
                return ($0.task?.startedAt ?? .distantPast) > ($1.task?.startedAt ?? .distantPast)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
