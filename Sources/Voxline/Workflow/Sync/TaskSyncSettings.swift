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
    private var systemFileStates: [URL: FileState] = [:]
    public var fileStates: [URL: FileState] {
        var states = systemFileStates
        if let documents = library.sharedDocuments {
            for url in documents.pendingURLs where states[url] != .conflict { states[url] = .waitingForUpload }
            for (url, error) in documents.publicationErrors {
                switch error {
                case .conflict: states[url] = .conflict
                case .failed(let message): if states[url] != .conflict { states[url] = .failed(message) }
                }
            }
        }
        return states
    }
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
    private struct DocumentRevision: Equatable, Sendable {
        let modifiedAt: Date?
        let byteCount: Int?
        let isDownloaded: Bool
        let hasConflict: Bool
    }
    @ObservationIgnored private var documentRevisions: [URL: DocumentRevision] = [:]
    @ObservationIgnored private var refreshWork: Task<Void, Never>?
    @ObservationIgnored private var changedURLs = Set<URL>()
    @ObservationIgnored private var needsDirectoryScan = false
    @ObservationIgnored private var refreshGeneration = UUID()
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
            let taskBackups = library.backupsDirectory.appendingPathComponent(task.id.uuidString, isDirectory: true)
            let backups = FileManager.default.fileExists(atPath: taskBackups.path)
                ? try FileManager.default.contentsOfDirectory(at: taskBackups, includingPropertiesForKeys: nil).filter { $0.pathExtension == "voxline" } : []
            for backup in backups {
                let local = try TaskDocumentCodec.decode(Data(contentsOf: backup))
                guard local.id == task.id else { throw SharedDocumentError.changed }
                if local != task {
                    let copy = try local.duplicated()
                    let copyURL = library.tasksDirectory.appendingPathComponent(copy.id.uuidString).appendingPathExtension("voxline")
                    try TaskDocumentCodec.encode(copy).write(to: copyURL, options: .atomic)
                    // Consume only a backup whose distinct contents have been durably recovered.
                    try FileManager.default.removeItem(at: backup)
                }
            }
            try TaskDocumentCodec.encode(task).write(to: localURL, options: .atomic)
            for backup in backups where FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
        }
        if FileManager.default.fileExists(atPath: storageURL.path) { try FileManager.default.removeItem(at: storageURL) }
        stopObserving()
        try library.connectSharedDocuments(nil)
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        scopedURL = nil; folderURL = nil; isEnabled = false; systemFileStates = [:]; syncOriginalMedia = false
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

    /// The user retry publishes pending documents, then rereads actual system state.
    public func retryPublication() throws {
        do {
            try library.publishSharedCheckpoints()
            refresh()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func refresh() {
        documentRevisions = [:] // An explicit refresh also retries files without a metadata change.
        scheduleRefresh()
    }

    /// Merge native notifications without repeatedly decoding the entire task library.
    func scheduleRefresh(changed: Set<URL>? = nil) {
        guard folderURL != nil else { return }
        if let changed { changedURLs.formUnion(changed.map(\.standardizedFileURL)) }
        else { needsDirectoryScan = true }
        guard refreshWork == nil else { return }
        let generation = refreshGeneration
        refreshWork = Task { [weak self] in
            guard let self else { return }
            while self.refreshGeneration == generation {
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch is CancellationError { return } // The selected folder was detached.
                catch {
                    if self.refreshGeneration == generation {
                        self.errorMessage = error.localizedDescription; self.refreshWork = nil
                    }
                    return
                }
                guard self.refreshGeneration == generation else { return }
                let urls = self.needsDirectoryScan ? nil : self.changedURLs
                self.changedURLs = []; self.needsDirectoryScan = false
                await self.refreshFiles(changed: urls)
                guard !self.changedURLs.isEmpty || self.needsDirectoryScan else { break }
            }
            if self.refreshGeneration == generation { self.refreshWork = nil }
        }
    }

    private func refreshFiles(changed: Set<URL>?) async {
        guard let folder = folderURL, let documents = library.sharedDocuments else { return }
        let generation = refreshGeneration
        var discovered = Set<URL>()
        if changed == nil, let query {
            query.disableUpdates()
            for index in 0..<query.resultCount {
                if let item = query.result(at: index) as? NSMetadataItem,
                   let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                   url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") {
                    discovered.insert(url.standardizedFileURL)
                }
            }
            query.enableUpdates()
        }
        if changed == nil { documents.discoveredURLs = discovered.filter { documents.contains($0) }.sorted { $0.path < $1.path } }
        let known = Set(systemFileStates.keys)
        let pending = Set(documents.pendingURLs)
        let metadataURLs = discovered
        do {
            let (urls, states, revisions) = try await Task.detached(priority: .utility) {
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                let tasks = folder.appendingPathComponent("Tasks", isDirectory: true).standardizedFileURL
                let media = folder.appendingPathComponent("Media", isDirectory: true).standardizedFileURL
                var urls = changed ?? known.union(metadataURLs).union(pending)
                if changed == nil {
                    urls.formUnion(try FileManager.default.contentsOfDirectory(at: tasks, includingPropertiesForKeys: nil))
                    if FileManager.default.fileExists(atPath: media.path) {
                        urls.formUnion(try FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: nil))
                    }
                }
                urls = Set(urls.map(\.standardizedFileURL).filter { url in
                    (url.deletingLastPathComponent() == tasks && url.pathExtension == "voxline") ||
                    (url.deletingLastPathComponent() == media && !url.lastPathComponent.contains(".partial."))
                })
                var states: [URL: FileState] = [:]
                var revisions: [URL: DocumentRevision] = [:]
                for url in urls {
                    do {
                        var freshURL = url
                        freshURL.removeAllCachedResourceValues()
                        let state = try Self.state(of: freshURL)
                        states[url] = state
                        if url.pathExtension == "voxline" {
                            let values = try freshURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                            revisions[url] = DocumentRevision(modifiedAt: values.contentModificationDate, byteCount: values.fileSize,
                                isDownloaded: state != .notDownloaded && state != .downloading, hasConflict: state == .conflict)
                        }
                    }
                    catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
                    catch { states[url] = .failed(error.localizedDescription) }
                }
                return (urls, states, revisions)
            }.value
            guard refreshGeneration == generation, library.sharedDocuments === documents else { return }
            var updated = systemFileStates
            for url in urls { updated[url] = states[url] }
            if updated != systemFileStates { systemFileStates = updated }
            let existing = Set(library.entries.compactMap { $0.url?.standardizedFileURL })
            let unreadable = Set(library.entries.filter { $0.error != nil }.compactMap { $0.url?.standardizedFileURL })
            let taskChanges = Set(urls.filter { url in
                documents.contains(url) && (changed != nil || revisions[url] != documentRevisions[url] ||
                    unreadable.contains(url) || !existing.contains(url))
            })
            await library.reloadSharedDocuments(at: taskChanges)
            guard refreshGeneration == generation else { return }
            for url in urls where documents.contains(url) { documentRevisions[url] = revisions[url] }
            errorMessage = nil
        } catch {
            if refreshGeneration == generation { errorMessage = error.localizedDescription }
        }
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
            try library.connectSharedDocuments(documents)
            let presenter = SharedFolderPresenter(directory: folder) { [weak self] urls in
                Task { @MainActor in self?.scheduleRefresh(changed: urls) }
            }
            self.presenter = presenter
            NSFileCoordinator.addFilePresenter(presenter)
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
            query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, folder.path + "/")
            self.query = query
            for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, NSNotification.Name.NSMetadataQueryDidUpdate] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] notification in
                    let keys = [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey, NSMetadataQueryUpdateRemovedItemsKey]
                    let items = keys.flatMap { notification.userInfo?[$0] as? [NSMetadataItem] ?? [] }
                    let urls = Set(items.compactMap { $0.value(forAttribute: NSMetadataItemURLKey) as? URL })
                    Task { @MainActor in self?.scheduleRefresh(changed: urls.isEmpty ? nil : urls) }
                })
            }
            guard query.start() else { throw SharedDocumentError.missingFolder }
            refresh()
        } catch {
            if access { folder.stopAccessingSecurityScopedResource() }
            scopedURL = nil
            stopObserving()
            try library.connectSharedDocuments(nil)
            folderURL = nil; isEnabled = false
            throw error
        }
    }

    private func stopObserving() {
        refreshGeneration = UUID()
        refreshWork?.cancel(); refreshWork = nil
        changedURLs = []; needsDirectoryScan = false; documentRevisions = [:]
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

    nonisolated private static func state(of url: URL) throws -> FileState {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemHasUnresolvedConflictsKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey])
        if values.ubiquitousItemHasUnresolvedConflicts == true { return .conflict }
        if let error = values.ubiquitousItemDownloadingError ?? values.ubiquitousItemUploadingError { return .failed(error.localizedDescription) }
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return .notDownloaded }
        if values.ubiquitousItemIsUploading == true { return .uploading }
        if values.ubiquitousItemIsUploaded == true { return .synced }
        if values.ubiquitousItemIsUploaded == false { return .waitingForUpload }
        return .available
    }
}
