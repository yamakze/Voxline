import Foundation
import Observation
import VoxlineCore

@Observable
@MainActor
public final class TaskLibrary {
    public private(set) var entries: [Entry] = []
    private var libraryError: String?
    public var errorMessage: String? {
        if let failure = sharedDocuments?.publicationErrors.values.first {
            return String(localized: "iCloud 同步失败，已保留本地成果：\(failure.message)", bundle: voxlineLocalizationBundle)
        }
        return libraryError
    }
    public enum SaveOutcome: Equatable {
        case local, published, pendingPublication
    }
    public private(set) var openTasks: [UUID: Entry] = [:]

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let taskID: UUID
        public let url: URL?
        public var task: ProcessingTask?
        public let error: String?
        public var title: String { task?.title ?? url?.deletingPathExtension().lastPathComponent ?? String(localized: "未命名任务", bundle: voxlineLocalizationBundle) }
    }

    public private(set) var sharedDocuments: SharedTaskDocuments?
    public var protectedTaskID: UUID?
    public var onMediaSourcesSaved: (@MainActor (ProcessingTask) -> Void)?

    public var backupsDirectory: URL { tasksDirectory.appendingPathComponent("Backups", isDirectory: true) }
    public let tasksDirectory: URL
    private var orderedEntryIDs: [String] = []
    private var orderURL: URL { tasksDirectory.appendingPathComponent("task-order.json") }
    private let recentDocumentURLs: @MainActor () -> [URL]
    private let noteRecentDocument: @MainActor (URL) -> Void
    private let forgetRecentDocument: @MainActor (URL) -> Void
    private let resourceCleanup: TaskResourceCleanup
    private let sharedPublicationInterval: Duration
    @ObservationIgnored private var publicationWork: Task<Void, Never>?

    public init(tasksDirectory: URL, recentDocumentURLs: @escaping @MainActor () -> [URL] = { [] },
                noteRecentDocument: @escaping @MainActor (URL) -> Void = { _ in },
                forgetRecentDocument: @escaping @MainActor (URL) -> Void = { _ in },
                resourceCleanup: TaskResourceCleanup = .init(), sharedPublicationInterval: Duration = .seconds(60)) {
        self.tasksDirectory = tasksDirectory
        self.recentDocumentURLs = recentDocumentURLs
        self.noteRecentDocument = noteRecentDocument
        self.forgetRecentDocument = forgetRecentDocument
        self.resourceCleanup = resourceCleanup
        self.sharedPublicationInterval = sharedPublicationInterval
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
        if sharedDocuments?.contains(fileURL) != true, openTasks[task.id]?.url != fileURL {
            noteRecentDocument(fileURL)
        }
        let entry = Entry(id: task.id.uuidString, taskID: task.id, url: fileURL, task: task, error: nil)
        openTasks[task.id] = entry
        let position = entries.firstIndex { $0.taskID == task.id || $0.url == fileURL } ?? 0
        entries.removeAll { $0.taskID == task.id || $0.url == fileURL }
        entries.insert(entry, at: min(position, entries.count))
    }

    public func defaultURL(for taskID: UUID) -> URL {
        (sharedDocuments?.directory ?? tasksDirectory).appendingPathComponent(taskID.uuidString).appendingPathExtension("voxline")
    }

    @discardableResult
    public func save(_ task: ProcessingTask, at url: URL? = nil, publishingImmediately: Bool = true) throws -> SaveOutcome {
        let targetURL = url ?? self.url(for: task.id) ?? defaultURL(for: task.id)
        let previousMedia = self.task(for: task.id)?.items.map(\.media)
        try persist(task, to: targetURL)
        register(task, at: targetURL)
        if previousMedia != task.items.map(\.media) { onMediaSourcesSaved?(task) }
        guard let documents = sharedDocuments, documents.contains(targetURL) else { return .local }
        scheduleSharedPublication()
        if publishingImmediately {
            do { try documents.publishCheckpoint(at: targetURL) }
            catch { return .pendingPublication }
        }
        return documents.pendingURLs.contains(targetURL.standardizedFileURL)
            ? .pendingPublication : .published
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
    public func commitCheckpoint<Result>(taskID: UUID, publishingImmediately: Bool = false, mutation: (inout ProcessingTask) throws -> Result) throws -> Result {
        guard var current = task(for: taskID) else { throw CheckpointError.taskUnavailable }
        let result = try mutation(&current)
        guard current.id == taskID else { throw TaskValidationError.taskChanged }
        try save(current, publishingImmediately: publishingImmediately)
        return result
    }

    private func persist(_ task: ProcessingTask, to url: URL) throws {
        let data = try TaskDocumentCodec.encode(task)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let sharedDocuments, sharedDocuments.contains(url) {
            if sharedDocuments.savesCheckpointsLocally { try sharedDocuments.saveCheckpoint(data, to: url) }
            else { try sharedDocuments.write(data, to: url) }
        }
        else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// Flushes actual pending documents; a failure leaves local recovery intact and visible.
    public func publishSharedCheckpoints() throws {
        guard let documents = sharedDocuments else { return }
        publicationWork?.cancel()
        publicationWork = nil
        var firstFailure: (any Error)?
        for url in documents.pendingURLs {
            do { try documents.publishCheckpoint(at: url) }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        // Each document retains its own error and recovery record; finish independent work first.
        if let firstFailure { throw firstFailure }
    }

    private func scheduleSharedPublication() {
        guard publicationWork == nil, let documents = sharedDocuments, !documents.pendingURLs.isEmpty else { return }
        let interval = sharedPublicationInterval
        publicationWork = Task { [weak self, weak documents] in
            do { try await Task.sleep(for: interval) }
            catch is CancellationError { return }
            catch { self?.libraryError = error.localizedDescription; return }
            guard let self, let documents, self.sharedDocuments === documents else { return }
            self.publicationWork = nil
            do { try self.publishSharedCheckpoints() }
            catch { return } // publishSharedCheckpoints exposes the error; recovery is retained.
        }
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
        if let sharedDocuments, sharedDocuments.contains(url), let task = entry.task {
            try sharedDocuments.publishCheckpoint(at: url)
            var current = try TaskDocumentCodec.decode(sharedDocuments.read(url, recordSnapshot: false))
            current.interruptRunningItems()
            guard current == task else { throw SharedDocumentError.changed }
        }
        var retainedTasks = entries.filter { $0.id != entryID }.compactMap(\.task)
        var cleanupWarnings: [String] = []
        if entry.task != nil {
            let localFiles = try FileManager.default.contentsOfDirectory(at: tasksDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "voxline" }
            let sharedFiles = try sharedDocuments.map {
                try FileManager.default.contentsOfDirectory(at: $0.directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "voxline" }
            } ?? []
            var checked: Set<URL> = [url.resolvingSymlinksInPath().standardizedFileURL]
            for otherURL in entries.compactMap(\.url) + recentDocumentURLs() + localFiles + sharedFiles {
                guard checked.insert(otherURL.resolvingSymlinksInPath().standardizedFileURL).inserted else { continue }
                let access = otherURL.startAccessingSecurityScopedResource()
                defer { if access { otherURL.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try sharedDocuments?.contains(otherURL) == true
                        ? sharedDocuments!.read(otherURL, recordSnapshot: false) : Data(contentsOf: otherURL)
                    retainedTasks.append(try TaskDocumentCodec.decode(data))
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
                catch { cleanupWarnings.append("\(otherURL.path)：\(error.localizedDescription)") }
            }
        }
        let remainingOrder = orderedEntryIDs.filter { $0 != entry.id }
        try JSONEncoder().encode(remainingOrder).write(to: orderURL, options: .atomic)
        if let sharedDocuments, sharedDocuments.contains(url) { try sharedDocuments.remove(url) }
        else { try FileManager.default.removeItem(at: url) }
        orderedEntryIDs = remainingOrder
        openTasks[entry.taskID] = nil
        entries.removeAll { $0.id == entryID }
        forgetRecentDocument(url)
        // The document is deleted first. Unknown references retain caches; cache failures cannot
        // turn successful task deletion into a failed edit or remove another task's resources.
        if let task = entry.task, cleanupWarnings.isEmpty {
            cleanupWarnings = resourceCleanup.removeResources(of: task, retaining: retainedTasks)
        }
        if !cleanupWarnings.isEmpty { libraryError = TaskDeletionError.cleanupFailed(cleanupWarnings).localizedDescription }
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
        try JSONEncoder().encode(entryIDs).write(to: orderURL, options: .atomic)
        orderedEntryIDs = entryIDs
        entries = reordered
    }

    @discardableResult
    public func saveRecoveryCopy(_ draft: ProcessingTask) throws -> ProcessingTask {
        let copy = try draft.duplicated()
        try save(copy, at: defaultURL(for: copy.id))
        return copy
    }

    public func conflictVersions(taskID: UUID) throws -> [SharedTaskDocuments.Version] {
        guard protectedTaskID != taskID else { throw SharedDocumentError.busy }
        guard let documents = sharedDocuments, let url = url(for: taskID), documents.contains(url) else { throw SharedDocumentError.missingFolder }
        return try documents.versions(at: url)
    }

    public func keepConflictVersion(_ versionID: UUID, taskID: UUID) throws {
        guard protectedTaskID != taskID else { throw SharedDocumentError.busy }
        guard let documents = sharedDocuments, let url = url(for: taskID), documents.contains(url) else { throw SharedDocumentError.missingFolder }
        let task = try documents.keepVersion(versionID, at: url)
        register(task, at: url)
        refresh()
    }

    public func connectSharedDocuments(_ documents: SharedTaskDocuments?) throws {
        if let documents {
            let sharedNames = Set(try FileManager.default.contentsOfDirectory(at: documents.directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "voxline" }.map(\.lastPathComponent) + documents.pendingURLs.map(\.lastPathComponent))
            let sharedIDs = Set(sharedNames.compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) })
            let localFiles = try FileManager.default.contentsOfDirectory(at: tasksDirectory, includingPropertiesForKeys: nil)
            for url in localFiles where url.pathExtension == "voxline" {
                let id: UUID
                do { id = try TaskDocumentCodec.decode(Data(contentsOf: url)).id }
                catch { continue } // Keep unreadable documents as explicit error entries in refresh.
                guard sharedIDs.contains(id) else { continue }
                let taskBackups = backupsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: taskBackups, withIntermediateDirectories: true)
                let backup = taskBackups.appendingPathComponent(UUID().uuidString).appendingPathExtension("voxline")
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                let knownURLs = openTasks.values.compactMap(\.url) + recentDocumentURLs()
                try FileManager.default.moveItem(at: url, to: backup)
                openTasks = openTasks.filter { $0.value.url?.resolvingSymlinksInPath().standardizedFileURL != canonical }
                for original in Set(knownURLs + [url]) where original.resolvingSymlinksInPath().standardizedFileURL == canonical {
                    forgetRecentDocument(original)
                }
            }
        }
        publicationWork?.cancel()
        publicationWork = nil
        if let previous = sharedDocuments {
            openTasks = openTasks.filter { $0.value.url.map { !previous.contains($0) } ?? true }
        }
        sharedDocuments = documents
        refresh()
        scheduleSharedPublication()
    }

    /// Only native-notified shared files are reloaded. Local tasks and recent documents stay untouched.
    func reloadSharedDocuments(at urls: Set<URL>) async {
        guard let documents = sharedDocuments else { return }
        var results: [(url: URL, previous: Entry?, result: Result<ProcessingTask, any Error>)] = []
        for url in urls.sorted(by: { $0.path < $1.path }) where documents.contains(url) {
            let previous = entries.first { $0.url?.standardizedFileURL == url.standardizedFileURL }
            if previous?.taskID == protectedTaskID, protectedTaskID != nil { continue }
            let result: Result<ProcessingTask, any Error>
            do { result = .success(try await documents.loadTask(url)) }
            catch { result = .failure(error) }
            guard sharedDocuments === documents else { return }
            results.append((url, previous, result))
        }
        var updated = entries
        for loaded in results {
            let current = entries.first { $0.url?.standardizedFileURL == loaded.url.standardizedFileURL }
            // A local edit or worker commit during I/O takes precedence over this earlier read.
            guard current == loaded.previous,
                  current?.taskID != protectedTaskID || protectedTaskID == nil else { continue }
            let entry: Entry
            switch loaded.result {
            case .success(let task):
                entry = Entry(id: task.id.uuidString, taskID: task.id, url: loaded.url, task: task, error: nil)
            case .failure(let error as CocoaError) where error.code == .fileReadNoSuchFile:
                if let current { openTasks[current.taskID] = nil }
                updated.removeAll { $0.url?.standardizedFileURL == loaded.url.standardizedFileURL }
                continue
            case .failure(let error):
                entry = Entry(id: current?.id ?? loaded.url.absoluteString, taskID: current?.taskID ?? UUID(),
                              url: loaded.url, task: current?.task, error: error.localizedDescription)
            }
            guard entry != current else { continue }
            if let current { openTasks[current.taskID] = nil }
            updated.removeAll { $0.url?.standardizedFileURL == loaded.url.standardizedFileURL || $0.taskID == entry.taskID }
            updated.append(entry)
        }
        if updated != entries { entries = sortedEntries(updated) }
    }

    public func refresh() {
        libraryError = nil
        do {
            orderedEntryIDs = FileManager.default.fileExists(atPath: orderURL.path)
                ? try JSONDecoder().decode([String].self, from: Data(contentsOf: orderURL)) : []
        } catch { libraryError = String(localized: "任务顺序读取失败：\(error.localizedDescription)", bundle: voxlineLocalizationBundle) }
        var foundEntries: [Entry] = []
        var seenIDs = Set<UUID>()

        // Shared documents are reread on native change notifications; a local worker keeps its snapshot.
        if let sharedDocuments {
            let previousEntries = entries
            openTasks = openTasks.filter { id, entry in
                id == protectedTaskID || entry.url.map { !sharedDocuments.contains($0) } ?? true
            }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: sharedDocuments.directory, includingPropertiesForKeys: nil)
                for url in Set(files + sharedDocuments.discoveredURLs + sharedDocuments.pendingURLs) where url.pathExtension == "voxline" {
                    if let protected = openTasks.values.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL && $0.taskID == protectedTaskID }) {
                        seenIDs.insert(protected.taskID); foundEntries.append(protected); continue
                    }
                    do {
                        var task = try TaskDocumentCodec.decode(sharedDocuments.read(url))
                        task.interruptRunningItems()
                        openTasks[task.id] = nil
                        guard seenIDs.insert(task.id).inserted else { continue }
                        foundEntries.append(Entry(id: task.id.uuidString, taskID: task.id, url: url, task: task, error: nil))
                    } catch {
                        let previous = previousEntries.first { $0.url?.standardizedFileURL == url.standardizedFileURL }
                        let id = previous?.taskID ?? UUID()
                        seenIDs.insert(id)
                        foundEntries.append(Entry(id: previous?.id ?? url.absoluteString, taskID: id, url: url,
                            task: previous?.task, error: error.localizedDescription))
                    }
                }
            } catch { libraryError = error.localizedDescription }
        }

        // 1. In-memory open tasks
        for (id, entry) in openTasks {
            guard !seenIDs.contains(id) else { continue }
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
            libraryError = error.localizedDescription
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
                    foundEntries.append(Entry(id: task.id.uuidString, taskID: task.id, url: url, task: task, error: nil))
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

        entries = sortedEntries(foundEntries)
    }

    private func sortedEntries(_ candidates: [Entry]) -> [Entry] {
        let positions = Dictionary(orderedEntryIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return candidates.sorted {
            let left = positions[$0.id]
            let right = positions[$1.id]
            if left != right { return (left ?? -1) < (right ?? -1) }
            if $0.task?.startedAt != $1.task?.startedAt {
                return ($0.task?.startedAt ?? .distantPast) > ($1.task?.startedAt ?? .distantPast)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
