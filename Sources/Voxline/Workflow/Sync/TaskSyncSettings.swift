import Foundation
import Observation
import VoxlineCore
import VoxlineMedia

@Observable @MainActor
public final class TaskSyncSettings {
    public private(set) var isEnabled = false
    public private(set) var folderURL: URL?
    public private(set) var syncOriginalMedia = false
    public private(set) var errorMessage: String?
    public private(set) var isChanging = false
    public private(set) var isCopyingOriginalMedia = false
    public private(set) var fileStates: [URL: FileState] = [:]
    public enum FileState: Equatable, Sendable {
        case available, waitingForUpload, uploading, notDownloaded, downloading, synced, conflict, failed(String)
    }
    public struct MigrationSummary: Sendable {
        public let taskCount: Int
        public let mediaCount: Int
        public let mediaBytes: Int64
    }
    private struct Stored: Codable {
        let folderBookmark: Data
        let syncOriginalMedia: Bool
    }
    private let library: TaskLibrary
    private let storageURL: URL
    private let mediaStore: LocalMediaStore
    private let inspector: MediaInspector
    private var presenter: SharedFolderPresenter?
    private var query: NSMetadataQuery?
    private var observations: [NSObjectProtocol] = []
    private var scopedURL: URL?
    private var didRestore = false
    private var originalMediaWork: (id: UUID, task: Task<Void, Never>)?

    public init(library: TaskLibrary, storageURL: URL? = nil, mediaStore: LocalMediaStore = .shared, inspector: MediaInspector = .shared) {
        self.library = library
        self.storageURL = storageURL ?? URL.applicationSupportDirectory.appendingPathComponent("Voxline/TaskSync.json")
        self.mediaStore = mediaStore
        self.inspector = inspector
        library.onMediaSourcesSaved = { [weak self] task in self?.scheduleOriginalUpload(task) }
    }

    public func restore() {
        guard !didRestore else { return }
        didRestore = true
        do {
            let data: Data
            do { data = try Data(contentsOf: storageURL) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
            #else
            let options: URL.BookmarkResolutionOptions = [.withoutUI]
            #endif
            let url = try URL(resolvingBookmarkData: stored.folderBookmark, options: options, bookmarkDataIsStale: &stale)
            try activate(url, originals: stored.syncOriginalMedia)
            if stale { try persist(folder: url, originals: stored.syncOriginalMedia) }
        } catch { errorMessage = String(localized: "同步恢复失败：\(error.localizedDescription)", bundle: voxlineLocalizationBundle) }
    }

    public func migrationSummary() throws -> MigrationSummary {
        guard library.protectedTaskID == nil else { throw SharedDocumentError.busy }
        var media: [String: Int64] = [:]
        for entry in library.entries {
            guard let task = entry.task, entry.error == nil else { throw SharedDocumentError.downloadRequired }
            for item in task.items {
                if let identity = item.media { media[identity.fingerprint + "." + (identity.fileName as NSString).pathExtension.lowercased()] = identity.byteCount }
            }
        }
        return .init(taskCount: library.entries.count, mediaCount: media.count, mediaBytes: media.values.reduce(0, +))
    }

    /// Explicit enable migrates complete documents. A collision keeps both existing files intact.
    public func enable(folder: URL, originals: Bool) async throws {
        guard !isChanging, originalMediaWork == nil, library.protectedTaskID == nil else { throw SharedDocumentError.busy }
        isChanging = true
        defer { isChanging = false }
        do {
            if isEnabled { try disable() }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            let documents = try SharedTaskDocuments(directory: folder.appendingPathComponent("Tasks", isDirectory: true),
                recoveryDirectory: library.tasksDirectory.appendingPathComponent("SyncRecovery", isDirectory: true))
            let tasks = try library.entries.map { entry in
                guard let task = entry.task, entry.error == nil else { throw SharedDocumentError.downloadRequired }
                return task
            }
            for task in tasks {
                let target = documents.directory.appendingPathComponent(task.id.uuidString).appendingPathExtension("voxline")
                let data = try TaskDocumentCodec.encode(task)
                if FileManager.default.fileExists(atPath: target.path) {
                    guard try TaskDocumentCodec.decode(documents.read(target)) == task else { throw SharedDocumentError.changed }
                } else { try documents.write(data, to: target) }
            }
            if originals { try await uploadOriginals(tasks, folder: folder) }
            try persist(folder: folder, originals: originals)
            try activate(folder, originals: originals)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription; throw error }
    }

    public func disable() throws {
        guard originalMediaWork == nil, library.protectedTaskID == nil else { throw SharedDocumentError.busy }
        try library.publishSharedCheckpoints()
        // Downloaded complete copies are required before revoking directory access.
        for entry in library.entries where entry.url.map({ library.sharedDocuments?.contains($0) == true }) == true {
            guard let task = entry.task, entry.error == nil else { throw SharedDocumentError.downloadRequired }
            guard let url = entry.url, let documents = library.sharedDocuments else { throw SharedDocumentError.missingFolder }
            var current = try TaskDocumentCodec.decode(documents.read(url, recordSnapshot: false))
            current.interruptRunningItems()
            guard current == task else { throw SharedDocumentError.changed }
            let localURL = library.tasksDirectory.appendingPathComponent(task.id.uuidString).appendingPathExtension("voxline")
            if FileManager.default.fileExists(atPath: localURL.path) {
                let local = try TaskDocumentCodec.decode(Data(contentsOf: localURL))
                if local != task {
                    let copy = try local.duplicated()
                    let copyURL = library.tasksDirectory.appendingPathComponent(copy.id.uuidString).appendingPathExtension("voxline")
                    try TaskDocumentCodec.encode(copy).write(to: copyURL, options: .atomic)
                }
            }
            try TaskDocumentCodec.encode(task).write(to: localURL, options: .atomic)
        }
        if FileManager.default.fileExists(atPath: storageURL.path) { try FileManager.default.removeItem(at: storageURL) }
        stopObserving()
        library.connectSharedDocuments(nil)
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        scopedURL = nil; folderURL = nil; isEnabled = false; fileStates = [:]; syncOriginalMedia = false
        errorMessage = nil
    }

    public func setOriginalMediaSync(_ enabled: Bool) async throws {
        guard !isChanging, originalMediaWork == nil, library.protectedTaskID == nil else { throw SharedDocumentError.busy }
        guard let folderURL, isEnabled else { throw SharedDocumentError.missingFolder }
        isChanging = true
        defer { isChanging = false }
        do {
            if enabled {
                let tasks = try library.entries.map { entry in
                    guard let task = entry.task, entry.error == nil else { throw SharedDocumentError.downloadRequired }
                    return task
                }
                try await uploadOriginals(tasks, folder: folderURL)
            }
            try persist(folder: folderURL, originals: enabled)
            syncOriginalMedia = enabled
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription; throw error }
    }

    public func requestDownload(_ url: URL) throws {
        try SharedTaskDocuments.requestDownload(url)
        refresh()
    }

    /// A downloaded original is associated only after checking its content and selected track.
    public func associateOriginal(for item: TaskMediaItem) async throws {
        guard let folderURL, let identity = item.media else { throw SharedDocumentError.missingFolder }
        let url = originalURL(identity, folder: folderURL)
        try SharedTaskDocuments.requestDownload(url)
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { throw SharedDocumentError.downloadRequired }
        let actual = try await inspector.inspect(url).identity(audioTrackID: identity.audioTrackID)
        guard identity.matchesContent(of: actual) else { throw MediaAccessError.fileChanged }
        try await mediaStore.save(projectID: item.id, identity: identity, url: url)
    }

    public func refresh() {
        guard let folderURL else { return }
        do {
            var states: [URL: FileState] = [:]
            let files = try FileManager.default.contentsOfDirectory(at: folderURL.appendingPathComponent("Tasks"), includingPropertiesForKeys: nil)
            for url in files where url.pathExtension == "voxline" { states[url.standardizedFileURL] = try state(of: url) }
            let mediaDirectory = folderURL.appendingPathComponent("Media", isDirectory: true)
            if FileManager.default.fileExists(atPath: mediaDirectory.path) {
                for url in try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil) where !url.lastPathComponent.contains(".partial.") {
                    states[url.standardizedFileURL] = try state(of: url)
                }
            }
            if let query {
                query.disableUpdates()
                defer { query.enableUpdates() }
                var discovered: [URL] = []
                for index in 0..<query.resultCount {
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                          url.standardizedFileURL.path.hasPrefix(folderURL.standardizedFileURL.path + "/") else { continue }
                    if library.sharedDocuments?.contains(url) == true {
                        states[url.standardizedFileURL] = try state(of: url); discovered.append(url)
                    } else if url.deletingLastPathComponent().standardizedFileURL == mediaDirectory.standardizedFileURL, !url.lastPathComponent.contains(".partial.") {
                        states[url.standardizedFileURL] = try state(of: url)
                    }
                }
                library.sharedDocuments?.discoveredURLs = discovered
            }
            fileStates = states
            library.refresh()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func activate(_ folder: URL, originals: Bool) throws {
        let access = folder.startAccessingSecurityScopedResource()
        do {
            let documents = try SharedTaskDocuments(directory: folder.appendingPathComponent("Tasks", isDirectory: true),
                recoveryDirectory: library.tasksDirectory.appendingPathComponent("SyncRecovery", isDirectory: true))
            stopObserving()
            if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
            scopedURL = access ? folder : nil
            folderURL = folder; isEnabled = true; syncOriginalMedia = originals
            library.connectSharedDocuments(documents)
            let presenter = SharedFolderPresenter(directory: folder) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
            self.presenter = presenter
            NSFileCoordinator.addFilePresenter(presenter)
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
            query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, folder.path + "/")
            self.query = query
            for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, NSNotification.Name.NSMetadataQueryDidUpdate] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                })
            }
            guard query.start() else { throw SharedDocumentError.missingFolder }
            refresh()
        } catch {
            if access { folder.stopAccessingSecurityScopedResource() }
            scopedURL = nil
            stopObserving()
            library.connectSharedDocuments(nil)
            folderURL = nil; isEnabled = false
            throw error
        }
    }

    private func stopObserving() {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
        query?.stop(); query = nil
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
        observations = []
    }

    private func persist(folder: URL, originals: Bool) throws {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        let bookmark = try folder.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Stored(folderBookmark: bookmark, syncOriginalMedia: originals)).write(to: storageURL, options: .atomic)
    }

    /// Explicit retry also covers originals whose earlier upload failed.
    public func retryOriginalMediaUpload() async throws {
        guard !isChanging, originalMediaWork == nil else { throw SharedDocumentError.busy }
        guard isEnabled, syncOriginalMedia, let folderURL else { throw SharedDocumentError.missingFolder }
        isChanging = true
        defer { isChanging = false }
        do {
            try await uploadOriginals(library.entries.compactMap(\.task), folder: folderURL)
            refresh()
        } catch { errorMessage = error.localizedDescription; throw error }
    }

    private func scheduleOriginalUpload(_ task: ProcessingTask) {
        guard isEnabled, syncOriginalMedia, !isChanging, let folderURL else { return }
        let preceding = originalMediaWork?.task
        let id = UUID()
        let work = Task { [weak self] in
            await preceding?.value
            guard let self else { return }
            self.isCopyingOriginalMedia = true
            defer {
                if self.originalMediaWork?.id == id {
                    self.originalMediaWork = nil
                    self.isCopyingOriginalMedia = false
                }
            }
            do { try await self.uploadOriginals([task], folder: folderURL); self.refresh() }
            catch { self.errorMessage = String(localized: "原媒体同步失败：\(error.localizedDescription)", bundle: voxlineLocalizationBundle) }
        }
        originalMediaWork = (id, work)
    }

    private func uploadOriginals(_ tasks: [ProcessingTask], folder: URL) async throws {
        let directory = folder.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied: Set<URL> = []
        for item in tasks.flatMap(\.items) {
            try Task.checkCancellation()
            guard let identity = item.media else { continue }
            let target = originalURL(identity, folder: folder)
            guard copied.insert(target).inserted else { continue }
            if FileManager.default.fileExists(atPath: target.path) {
                let actual = try await inspector.inspect(target).identity(audioTrackID: identity.audioTrackID)
                guard identity.matchesContent(of: actual) else { throw MediaAccessError.fileChanged }
                continue
            }
            guard let source = try await mediaStore.resolve(projectID: item.id, identity: identity) else { throw MediaAccessError.invalidBookmark }
            let access = source.url.startAccessingSecurityScopedResource()
            defer { if access { source.url.stopAccessingSecurityScopedResource() } }
            let actual = try await inspector.inspect(source.url).identity(audioTrackID: identity.audioTrackID)
            guard identity.matchesContent(of: actual) else { throw MediaAccessError.fileChanged }
            try await copyOriginal(source.url, identity: identity, to: target)
        }
    }

    /// Validation precedes publication; a changed source never acquires the expected hash filename.
    private func copyOriginal(_ sourceURL: URL, identity: MediaIdentity, to target: URL) async throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent("\(UUID()).partial")
            .appendingPathExtension(target.pathExtension)
        do {
            let copyWork = Task.detached {
                var result: Result<Void, any Error>?
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { source in
                    result = Result {
                        try Task.checkCancellation()
                        try FileManager.default.copyItem(at: source, to: temporary)
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw CocoaError(.fileWriteUnknown) }
                try result.get()
            }
            try await withTaskCancellationHandler { try await copyWork.value } onCancel: { copyWork.cancel() }
            try Task.checkCancellation()
            let actual = try await inspector.inspect(temporary).identity(audioTrackID: identity.audioTrackID)
            guard identity.matchesContent(of: actual) else { throw MediaAccessError.fileChanged }
            var result: Result<Void, any Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &coordinationError) { destination in
                result = Result { try FileManager.default.moveItem(at: temporary, to: destination) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileWriteUnknown) }
            try result.get()
        } catch {
            let cause = error
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch { throw TaskDeletionError.cleanupFailed(["\(temporary.path)：\(error.localizedDescription)"]) }
            }
            throw cause
        }
    }

    public func originalMediaState(for item: TaskMediaItem) -> FileState? {
        guard let folderURL, let identity = item.media else { return nil }
        return fileStates[originalURL(identity, folder: folderURL).standardizedFileURL]
    }

    public func originalMediaURL(for identity: MediaIdentity) throws -> URL {
        guard let folderURL else { throw SharedDocumentError.missingFolder }
        return originalURL(identity, folder: folderURL)
    }

    private func originalURL(_ identity: MediaIdentity, folder: URL) -> URL {
        folder.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(identity.fingerprint)
            .appendingPathExtension((identity.fileName as NSString).pathExtension.lowercased())
    }

    private func state(of url: URL) throws -> FileState {
        if let documents = library.sharedDocuments {
            if let error = documents.publicationErrors[url.standardizedFileURL] { return .failed(error) }
            if documents.pendingURLs.contains(url.standardizedFileURL) { return .waitingForUpload }
        }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemHasUnresolvedConflictsKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey])
        if let error = values.ubiquitousItemDownloadingError ?? values.ubiquitousItemUploadingError { return .failed(error.localizedDescription) }
        if values.ubiquitousItemHasUnresolvedConflicts == true { return .conflict }
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return .notDownloaded }
        if values.ubiquitousItemIsUploading == true { return .uploading }
        if values.ubiquitousItemIsUploaded == true { return .synced }
        if values.ubiquitousItemIsUploaded == false { return .waitingForUpload }
        return .available
    }
}
