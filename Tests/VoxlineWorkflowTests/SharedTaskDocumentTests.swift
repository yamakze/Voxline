import Foundation
import Testing
@testable import VoxlineCore
import VoxlineMedia
@testable import VoxlineWorkflow

@Suite("Shared Task documents", .serialized) @MainActor
struct SharedTaskDocumentTests {
    @Test func localCheckpointsSurviveRestartAndRemoteChangesStayProtected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        let cloud = root.appendingPathComponent("cloud")
        let recovery = local.appendingPathComponent("SyncRecovery")
        let documents = try SharedTaskDocuments(directory: cloud, recoveryDirectory: recovery)
        let library = TaskLibrary(tasksDirectory: local)
        try library.connectSharedDocuments(documents)
        let initial = ProcessingTask(title: "Initial")
        try library.save(initial)
        let url = try #require(library.url(for: initial.id))
        try library.commitCheckpoint(taskID: initial.id) { $0.title = "First checkpoint" }
        try library.commitCheckpoint(taskID: initial.id) { $0.title = "Latest checkpoint" }
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == initial)
        library.refresh()
        #expect(library.task(for: initial.id)?.title == "Latest checkpoint")
        let restarted = TaskLibrary(tasksDirectory: local)
        let restored = try SharedTaskDocuments(directory: cloud, recoveryDirectory: recovery)
        try restarted.connectSharedDocuments(restored)
        #expect(restarted.task(for: initial.id)?.title == "Latest checkpoint")
        var remote = initial
        remote.title = "Other device"
        try TaskDocumentCodec.encode(remote).write(to: url, options: .atomic)
        #expect(throws: SharedDocumentError.self) { try restarted.publishSharedCheckpoints() }
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == remote)
        #expect(restored.pendingURLs.count == 1)
        #expect(restarted.errorMessage != nil)
        let again = try SharedTaskDocuments(directory: cloud, recoveryDirectory: recovery)
        #expect(try TaskDocumentCodec.decode(again.read(url)).title == "Latest checkpoint")
        // Explicitly selecting the cloud version preserves unpublished local work as a copy.
        let versions = try restarted.conflictVersions(taskID: initial.id)
        try restarted.keepConflictVersion(try #require(versions.first).id, taskID: initial.id)
        #expect(restarted.task(for: initial.id) == remote)
        #expect(restarted.entries.contains { $0.task?.title == "Latest checkpoint" + String(localized: " 副本", bundle: VoxlineCore.voxlineLocalizationBundle) })
        #expect(restored.pendingURLs.isEmpty)
    }

    @Test func processingUpdatesCoalesceUntilTimerAndManualSavePublishesImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        let documents = try SharedTaskDocuments(directory: root.appendingPathComponent("cloud"),
            recoveryDirectory: local.appendingPathComponent("SyncRecovery"))
        let library = TaskLibrary(tasksDirectory: local, sharedPublicationInterval: .milliseconds(100))
        try library.connectSharedDocuments(documents)
        let initial = ProcessingTask(title: "Initial")
        try library.save(initial)
        let url = try #require(library.url(for: initial.id))
        for i in 0..<20 { try library.commitCheckpoint(taskID: initial.id) { $0.title = "Checkpoint \(i)" } }
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == initial)
        #expect(documents.pendingURLs.count == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)).title == "Checkpoint 19")
        #expect(documents.pendingURLs.isEmpty)
        try library.commitCheckpoint(taskID: initial.id) { $0.title = "New pending checkpoint" }
        var edit = try #require(library.task(for: initial.id))
        edit.title = "Proofread edit"
        try library.save(edit)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == edit)
        #expect(documents.pendingURLs.isEmpty)
    }

    @Test func missingLocalRecoveryFileStorageDoesNotPublishOrAdvanceMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        let recovery = local.appendingPathComponent("SyncRecovery")
        let documents = try SharedTaskDocuments(directory: root.appendingPathComponent("cloud"), recoveryDirectory: recovery)
        let library = TaskLibrary(tasksDirectory: local)
        try library.connectSharedDocuments(documents)
        let initial = ProcessingTask(title: "Initial")
        try library.save(initial)
        let url = try #require(library.url(for: initial.id))
        try FileManager.default.removeItem(at: recovery)
        #expect(throws: (any Error).self) { try library.commitCheckpoint(taskID: initial.id) { $0.title = "Unsaved" } }
        #expect(library.task(for: initial.id) == initial)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == initial)
    }

    @Test func remoteChangeRejectsDraftAndKeepsBothVersionsRecoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try SharedTaskDocuments(directory: root.appendingPathComponent("cloud"))
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        try library.connectSharedDocuments(shared)
        let initial = ProcessingTask(title: "Initial")
        try library.save(initial)
        let url = try #require(library.url(for: initial.id))
        var remote = initial
        remote.title = "Remote edit"
        try TaskDocumentCodec.encode(remote).write(to: url, options: .atomic)
        var draft = initial
        draft.title = "Unsaved local edit"
        #expect(throws: SharedDocumentError.self) { try library.save(draft) }
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == remote)
        #expect(library.task(for: initial.id) == initial)
        let copy = try library.saveRecoveryCopy(draft)
        #expect(copy.id != initial.id)
        #expect(copy.items == draft.items)
        library.refresh()
        #expect(library.task(for: initial.id) == remote)
        #expect(library.task(for: copy.id)?.title == "Unsaved local edit" + String(localized: " 副本", bundle: VoxlineCore.voxlineLocalizationBundle))
        let reopened = TaskLibrary(tasksDirectory: root.appendingPathComponent("other-device"))
        try reopened.connectSharedDocuments(try SharedTaskDocuments(directory: shared.directory))
        #expect(Set(reopened.entries.map(\.taskID)) == [initial.id, copy.id])
    }

    @Test func workerSnapshotSurvivesNotificationAndCannotOverwriteRemoteOrDeletedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try SharedTaskDocuments(directory: root.appendingPathComponent("cloud"))
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        try library.connectSharedDocuments(shared)
        let initial = ProcessingTask(title: "Working")
        try library.save(initial)
        library.protectedTaskID = initial.id
        let url = try #require(library.url(for: initial.id))
        var remote = initial
        remote.title = "Changed elsewhere"
        try TaskDocumentCodec.encode(remote).write(to: url, options: .atomic)
        library.refresh()
        #expect(library.task(for: initial.id) == initial)
        #expect(throws: SharedDocumentError.self) { try library.commitCheckpoint(taskID: initial.id) { $0.title = "Worker result" } }
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == remote)
        try FileManager.default.removeItem(at: url)
        #expect(throws: SharedDocumentError.self) { try library.save(initial) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        library.protectedTaskID = nil
        library.refresh()
        #expect(library.task(for: initial.id) == nil)
    }

    @Test func invalidRemoteVersionKeepsLastPublishedTaskAndBlocksSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try SharedTaskDocuments(directory: root.appendingPathComponent("cloud"))
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        try library.connectSharedDocuments(shared)
        let initial = ProcessingTask(title: "Proofread")
        try library.save(initial)
        let url = try #require(library.url(for: initial.id))
        try Data("broken JSON".utf8).write(to: url)
        library.refresh()
        #expect(library.task(for: initial.id) == initial)
        #expect(library.entries.first?.error != nil)
        #expect(throws: SharedDocumentError.self) { try library.save(initial) }
        #expect(try Data(contentsOf: url) == Data("broken JSON".utf8))
    }

    @Test func enableDisableRetainsDifferentLocalCopyAndDeviceOrderDoesNotEnterSharedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        let folder = root.appendingPathComponent("cloud")
        let library = TaskLibrary(tasksDirectory: local)
        let settings = TaskSyncSettings(library: library, storageURL: root.appendingPathComponent("settings.json"))
        let initial = ProcessingTask(title: "Original")
        try library.save(initial)
        try await settings.enable(folder: folder, originals: false)
        #expect(settings.isEnabled)
        var changed = initial
        changed.title = "Edited cloud"
        try library.save(changed)
        try library.reorder(entryIDs: library.entries.map(\.id))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Tasks/task-order.json").path))
        try settings.disable()
        #expect(!settings.isEnabled)
        #expect(library.task(for: initial.id) == changed)
        #expect(library.entries.contains { $0.task?.title == "Original" + String(localized: " 副本", bundle: VoxlineCore.voxlineLocalizationBundle) })
        let cloudFile = folder.appendingPathComponent("Tasks/\(initial.id).voxline")
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: cloudFile)) == changed)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path))
    }
    @Test func missingOriginalKeepsPolicyDisabledAndRelinkAllowsRetryWithoutChangingTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VoxlineMediaTests/Fixtures/multi-audio.mov")
        let source = root.appendingPathComponent("removed.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let inspector = MediaInspector()
        let inspection = try await inspector.inspect(source)
        let identity = try inspection.identity(audioTrackID: #require(inspection.audioTracks.first?.id))
        let item = TaskMediaItem(title: "Original", kind: .video, source: .localFile(fileName: identity.fileName), media: identity)
        let task = ProcessingTask(items: [item])
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        try library.save(task)
        let store = LocalMediaStore(directory: root.appendingPathComponent("associations"))
        try await store.save(projectID: item.id, identity: identity, url: source)
        let settingsURL = root.appendingPathComponent("settings.json")
        let settings = TaskSyncSettings(library: library, storageURL: settingsURL, mediaStore: store, inspector: inspector)
        try await settings.enable(folder: root.appendingPathComponent("cloud"), originals: false)
        try FileManager.default.removeItem(at: source)
        await #expect(throws: MediaAccessError.missingFile(identity.fileName)) { try await settings.setOriginalMediaSync(true) }
        #expect(settings.syncOriginalMedia == false)
        #expect(try (JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])?["syncOriginalMedia"] as? Bool == false)
        try await store.save(projectID: item.id, identity: identity, url: fixture)
        try await settings.setOriginalMediaSync(true)
        let target = try settings.originalMediaURL(for: identity)
        #expect(try Data(contentsOf: target) == Data(contentsOf: fixture))
        #expect(settings.syncOriginalMedia && settings.errorMessage == nil)
        #expect(library.task(for: task.id) == task)
        try settings.disable()
    }

    @Test func originalMediaCopyReusesActualContentAndRelinksOnOtherDevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VoxlineMediaTests/Fixtures/multi-audio.mov")
        let inspector = MediaInspector()
        let inspection = try await inspector.inspect(fixture)
        let tracks = inspection.audioTracks.filter(\.isDecodable)
        #expect(tracks.count >= 2)
        let identities = try tracks.map { try inspection.identity(audioTrackID: $0.id) }
        let items = identities.map { TaskMediaItem(title: "Track \($0.audioTrackID)", kind: .video, source: .localFile(fileName: $0.fileName), media: $0) }
        let mediaStore = LocalMediaStore(directory: root.appendingPathComponent("associations"))
        for item in items { try await mediaStore.save(projectID: item.id, identity: try #require(item.media), url: fixture) }
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        let task = ProcessingTask(items: items)
        try library.save(task)
        let settings = TaskSyncSettings(library: library, storageURL: root.appendingPathComponent("settings.json"), mediaStore: mediaStore, inspector: inspector)
        let summary = try settings.migrationSummary()
        #expect(summary.mediaCount == 1)
        #expect(summary.mediaBytes == inspection.byteCount)
        try await settings.enable(folder: root.appendingPathComponent("cloud"), originals: true)
        let original = try settings.originalMediaURL(for: identities[0])
        #expect(try Data(contentsOf: original) == Data(contentsOf: fixture))
        let copiedFiles = try FileManager.default.contentsOfDirectory(at: original.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(copiedFiles.count == 1)
        let otherStore = LocalMediaStore(directory: root.appendingPathComponent("other-associations"))
        let otherLibrary = TaskLibrary(tasksDirectory: root.appendingPathComponent("other-local"))
        let other = TaskSyncSettings(library: otherLibrary, storageURL: root.appendingPathComponent("other-settings.json"), mediaStore: otherStore, inspector: inspector)
        try await other.enable(folder: root.appendingPathComponent("cloud"), originals: false)
        try await other.associateOriginal(for: items[1])
        let resolved = try await otherStore.resolve(projectID: items[1].id, identity: identities[1])
        #expect(resolved?.url.standardizedFileURL == original.standardizedFileURL)
        try await settings.setOriginalMediaSync(false)
        #expect(FileManager.default.fileExists(atPath: original.path))
        try settings.disable()
        try other.disable()
        #expect(FileManager.default.fileExists(atPath: fixture.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

}
