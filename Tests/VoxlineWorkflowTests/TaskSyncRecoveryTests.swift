import Foundation
import Testing
import VoxlineCore
@testable import VoxlineWorkflow

@Suite("Local save and shared recovery", .serialized) @MainActor
struct TaskSyncRecoveryTests {
    @Test func sharedFileChangesReloadOnlyAffectedDocumentsAndPreserveLocalWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        let first = ProcessingTask(title: "First")
        let unrelated = ProcessingTask(title: "Unrelated")
        let documents = try SharedTaskDocuments(directory: root.appendingPathComponent("cloud"),
            recoveryDirectory: library.tasksDirectory.appendingPathComponent("SyncRecovery"))
        let firstURL = documents.directory.appendingPathComponent(first.id.uuidString).appendingPathExtension("voxline")
        let unrelatedURL = documents.directory.appendingPathComponent(unrelated.id.uuidString).appendingPathExtension("voxline")
        try documents.write(TaskDocumentCodec.encode(first), to: firstURL)
        try documents.write(TaskDocumentCodec.encode(unrelated), to: unrelatedURL)
        try library.connectSharedDocuments(documents)
        var remote = first; remote.title = "Remote edit"
        try TaskDocumentCodec.encode(remote).write(to: firstURL, options: .atomic)
        try Data("invalid unrelated file".utf8).write(to: unrelatedURL, options: .atomic)
        await library.reloadSharedDocuments(at: [firstURL])
        #expect(library.task(for: first.id) == remote)
        #expect(library.entries.first { $0.taskID == unrelated.id }?.error == nil)
        // A pending local checkpoint survives a missing cloud file and a native reload.
        try library.commitCheckpoint(taskID: first.id) { $0.title = "Pending local edit" }
        try FileManager.default.removeItem(at: firstURL)
        await library.reloadSharedDocuments(at: [firstURL])
        #expect(library.task(for: first.id)?.title == "Pending local edit")
        let added = ProcessingTask(title: "New remote task")
        let addedURL = firstURL.deletingLastPathComponent().appendingPathComponent(added.id.uuidString).appendingPathExtension("voxline")
        try TaskDocumentCodec.encode(added).write(to: addedURL, options: .atomic)
        await library.reloadSharedDocuments(at: [addedURL])
        #expect(library.task(for: added.id) == added)
        try FileManager.default.removeItem(at: addedURL)
        await library.reloadSharedDocuments(at: [addedURL])
        #expect(library.task(for: added.id) == nil)
        await library.reloadSharedDocuments(at: [unrelatedURL])
        #expect(library.entries.first { $0.taskID == unrelated.id }?.error != nil)
        #expect(library.task(for: unrelated.id) == unrelated)
    }

    @Test func savedDraftAdvancesLocallyAndVersionSelectionPreservesBothEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        let cue = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 1000, sourceText: "Before")
        let item = TaskMediaItem(title: "Media", kind: .audio, source: .unassociated, cues: [cue])
        let task = ProcessingTask(title: "Initial", items: [item])
        try library.save(task)
        let settings = TaskSyncSettings(library: library, storageURL: root.appendingPathComponent("settings.json"))
        try await settings.enable(folder: root.appendingPathComponent("cloud"), originals: false)
        defer { try? settings.disable() }
        let url = try #require(library.url(for: task.id))
        var remote = task
        remote.title = "Remote edit"
        try TaskDocumentCodec.encode(remote).write(to: url, options: .atomic)
        var draft = item
        try draft.editSubtitle(comparedTo: cue, sourceText: "Local edit", translationText: "")
        try library.updateItem(draft, taskID: task.id, comparedTo: item)
        #expect(library.task(for: task.id)?.items[0] == draft)
        #expect(settings.fileStates[url.standardizedFileURL] == .conflict)
        #expect(library.errorMessage != nil)
        settings.refresh()
        #expect(library.errorMessage != nil)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == remote)
        // The page can take the committed snapshot and keep editing while publication is pending.
        var next = draft
        try next.editSubtitle(comparedTo: draft.cues[0], sourceText: "Next local edit", translationText: "")
        try library.updateItem(next, taskID: task.id, comparedTo: draft)
        let restarted = TaskLibrary(tasksDirectory: library.tasksDirectory)
        try restarted.connectSharedDocuments(SharedTaskDocuments(directory: url.deletingLastPathComponent(),
            recoveryDirectory: library.tasksDirectory.appendingPathComponent("SyncRecovery")))
        #expect(restarted.task(for: task.id)?.items[0] == next)
        let versions = try library.conflictVersions(taskID: task.id)
        #expect(versions.count == 2)
        let cloudVersion = try #require(versions.first { $0.origin == .shared })
        try library.keepConflictVersion(cloudVersion.id, taskID: task.id)
        #expect(library.task(for: task.id) == remote)
        #expect(library.entries.contains { $0.task?.items[0] == next && $0.taskID != task.id })
        #expect(library.sharedDocuments?.pendingURLs.isEmpty == true)
        #expect(library.errorMessage == nil)
    }

    @Test func remoteDeletionDoesNotReactivateBackupAndPendingLocalWorkCanBeRestored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        let task = ProcessingTask(title: "Before migration")
        try library.save(task)
        let settings = TaskSyncSettings(library: library, storageURL: root.appendingPathComponent("settings.json"))
        try await settings.enable(folder: root.appendingPathComponent("cloud"), originals: false)
        defer { try? settings.disable() }
        let url = try #require(library.url(for: task.id))
        let backup = try #require(FileManager.default.contentsOfDirectory(at: library.backupsDirectory.appendingPathComponent(task.id.uuidString), includingPropertiesForKeys: nil).first)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: backup)) == task)
        try FileManager.default.removeItem(at: url)
        await library.refresh()
        #expect(library.task(for: task.id) == nil)
        let restarted = TaskLibrary(tasksDirectory: library.tasksDirectory)
        try restarted.connectSharedDocuments(SharedTaskDocuments(directory: url.deletingLastPathComponent()))
        #expect(restarted.task(for: task.id) == nil)
        let recovering = ProcessingTask(title: "Recoverable")
        try library.save(recovering)
        let recoveryURL = try #require(library.url(for: recovering.id))
        try library.commitCheckpoint(taskID: recovering.id) { $0.title = "Unpublished work" }
        #expect(settings.fileStates[recoveryURL.standardizedFileURL] == .waitingForUpload)
        try FileManager.default.removeItem(at: recoveryURL)
        #expect(throws: SharedDocumentError.changed) { try library.publishSharedCheckpoints() }
        #expect(settings.fileStates[recoveryURL.standardizedFileURL] == .conflict)
        let versions = try library.conflictVersions(taskID: recovering.id)
        #expect(versions.count == 1)
        let local = try #require(versions.first)
        #expect(local.origin == .localRecovery)
        try library.keepConflictVersion(local.id, taskID: recovering.id)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: recoveryURL)).title == "Unpublished work")
        #expect(library.errorMessage == nil)
    }

    @Test func renamedLocalDocumentsAreArchivedByTaskIdentityAndNeverRediscovered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        let renamed = local.appendingPathComponent("My renamed task.voxline")
        var recent = [renamed]
        let library = TaskLibrary(tasksDirectory: local, recentDocumentURLs: { recent },
            forgetRecentDocument: { url in recent.removeAll { $0 == url } })
        let task = ProcessingTask(title: "Renamed document")
        try library.save(task, at: renamed)
        let settings = TaskSyncSettings(library: library, storageURL: root.appendingPathComponent("settings.json"))
        try await settings.enable(folder: root.appendingPathComponent("cloud"), originals: false)
        defer { try? settings.disable() }
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
        #expect(recent.isEmpty)
        try library.delete(taskID: task.id)
        await library.refresh()
        #expect(library.task(for: task.id) == nil)
        #expect(TaskLibrary(tasksDirectory: local, recentDocumentURLs: { recent }).entries.isEmpty)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: library.backupsDirectory.appendingPathComponent(task.id.uuidString), includingPropertiesForKeys: nil).first)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: backup)) == task)
    }

    @Test func selectingAnOldLocalVersionRejectsNewEditsAndPublicationFailureIsExplicit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        let documents = try SharedTaskDocuments(directory: root.appendingPathComponent("cloud"),
            recoveryDirectory: local.appendingPathComponent("SyncRecovery"))
        let library = TaskLibrary(tasksDirectory: local)
        try library.connectSharedDocuments(documents)
        let task = ProcessingTask(title: "Initial")
        #expect(try library.save(task) == .published)
        let url = try #require(library.url(for: task.id))
        try library.commitCheckpoint(taskID: task.id) { $0.title = "First local edit" }
        var remote = task
        remote.title = "Remote edit"
        try TaskDocumentCodec.encode(remote).write(to: url, options: .atomic)
        let versions = try library.conflictVersions(taskID: task.id)
        let selected = try #require(versions.first { $0.origin == .localRecovery })
        try library.commitCheckpoint(taskID: task.id) { $0.title = "Later local edit" }
        #expect(throws: SharedDocumentError.changed) { try library.keepConflictVersion(selected.id, taskID: task.id) }
        #expect(library.task(for: task.id)?.title == "Later local edit")
        let result = try library.save(try #require(library.task(for: task.id)))
        if case .pendingPublication = result {} else { Issue.record("Cloud failure must report a pending publication") }
        #expect(library.errorMessage != nil)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == remote)
    }
}
