import Foundation
import Testing
@testable import VoxlineCore
@testable import VoxlineWorkflow

@Suite("Shared publication and migration regression", .serialized) @MainActor
struct SharedPublicationRegressionTests {
    @Test func publicationConflictIsIsolatedToItsOwnDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        let documents = try SharedTaskDocuments(directory: root.appendingPathComponent("cloud"),
            recoveryDirectory: root.appendingPathComponent("recovery"))
        try library.connectSharedDocuments(documents)
        let tasks = [ProcessingTask(title: "A"), ProcessingTask(title: "B")]
        for task in tasks { try library.save(task) }
        for task in tasks { try library.commitCheckpoint(taskID: task.id) { $0.title += " local" } }
        let pending = documents.pendingURLs
        #expect(pending.count == 2)
        let blockedURL = try #require(pending.first)
        let healthyURL = pending[1]
        let healthyBefore = try Data(contentsOf: healthyURL)
        var remote = try TaskDocumentCodec.decode(Data(contentsOf: blockedURL))
        remote.title += " remote"
        try TaskDocumentCodec.encode(remote).write(to: blockedURL, options: .atomic)
        #expect(throws: SharedDocumentError.changed) { try library.publishSharedCheckpoints() }
        #expect(documents.pendingURLs == [blockedURL])
        #expect(documents.publicationErrors[blockedURL] == .conflict)
        #expect(try Data(contentsOf: healthyURL) != healthyBefore)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: healthyURL)).title.hasSuffix(" local"))
        #expect(documents.pendingURLs == [blockedURL])
    }

    @Test func invalidCloudBytesArePreservedWhileValidLocalWorkIsRestored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        let library = TaskLibrary(tasksDirectory: local)
        let directory = root.appendingPathComponent("cloud")
        let recovery = root.appendingPathComponent("recovery")
        let documents = try SharedTaskDocuments(directory: directory, recoveryDirectory: recovery)
        try library.connectSharedDocuments(documents)
        let task = ProcessingTask(title: "Complete local task")
        try library.save(task)
        try library.commitCheckpoint(taskID: task.id) { $0.title = "Saved local edit" }
        let url = try #require(library.url(for: task.id))
        try Data("broken JSON".utf8).write(to: url, options: .atomic)
        #expect(throws: SharedDocumentError.changed) { try library.publishSharedCheckpoints() }
        #expect(documents.publicationErrors[url.standardizedFileURL] == .conflict)
        let versions = try library.conflictVersions(taskID: task.id)
        #expect(versions.count == 1 && versions[0].origin == .localRecovery)
        #expect(!documents.versionReadErrors.isEmpty)
        let restarted = TaskLibrary(tasksDirectory: local)
        try restarted.connectSharedDocuments(SharedTaskDocuments(directory: directory, recoveryDirectory: recovery))
        #expect(restarted.task(for: task.id)?.title == "Saved local edit")
        let recovered = try restarted.conflictVersions(taskID: task.id)
        try restarted.keepConflictVersion(try #require(recovered.first).id, taskID: task.id)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)).title == "Saved local edit")
        #expect(restarted.sharedDocuments?.pendingURLs.isEmpty == true)
        let enumerator = try #require(FileManager.default.enumerator(at: recovery, includingPropertiesForKeys: nil))
        let rawFiles = enumerator.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "voxline" }
        #expect(try rawFiles.contains { try Data(contentsOf: $0) == Data("broken JSON".utf8) })
        try restarted.delete(taskID: task.id)
        #expect(restarted.task(for: task.id) == nil)
    }

    @Test func repeatedSyncCyclesPreserveEachDistinctBackupOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"))
        let settings = TaskSyncSettings(library: library, storageURL: root.appendingPathComponent("settings.json"))
        let folder = root.appendingPathComponent("cloud")
        let task = ProcessingTask(title: "Baseline")
        try library.save(task)
        try await settings.enable(folder: folder, originals: false)
        try library.commitCheckpoint(taskID: task.id, publishingImmediately: true) { $0.title = "Intermediate" }
        try settings.disable()
        #expect(library.entries.contains { $0.title.hasPrefix("Baseline") })
        try await settings.enable(folder: folder, originals: false)
        defer { try? settings.disable() }
        let backups = try FileManager.default.contentsOfDirectory(at: library.backupsDirectory.appendingPathComponent(task.id.uuidString), includingPropertiesForKeys: nil)
            .map { try TaskDocumentCodec.decode(Data(contentsOf: $0)) }
        #expect(backups.contains { $0.id == task.id && $0.title == "Intermediate" })
        try library.commitCheckpoint(taskID: task.id, publishingImmediately: true) { $0.title = "Latest" }
        try settings.disable()
        #expect(library.task(for: task.id)?.title == "Latest")
        #expect(library.entries.filter { $0.title.hasPrefix("Intermediate") }.count == 1)
        #expect(library.entries.filter { $0.title.hasPrefix("Baseline") }.count == 1)
    }

    @Test func syncModeChangesKeepLocalOrderAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        let library = TaskLibrary(tasksDirectory: local)
        let settings = TaskSyncSettings(library: library, storageURL: root.appendingPathComponent("settings.json"))
        let a = ProcessingTask(title: "A"), z = ProcessingTask(title: "Z")
        try library.save(a); try library.save(z)
        let requested = [z.id.uuidString, a.id.uuidString]
        try library.reorder(entryIDs: requested)
        #expect(library.entries.map(\.taskID) == [z.id, a.id])
        try await settings.enable(folder: root.appendingPathComponent("cloud"), originals: false)
        defer { try? settings.disable() }
        #expect(library.entries.map(\.taskID) == [z.id, a.id])
        try library.reorder(entryIDs: requested)
        try settings.disable()
        #expect(library.entries.map(\.taskID) == [z.id, a.id])
        #expect(TaskLibrary(tasksDirectory: local).entries.map(\.taskID) == [z.id, a.id])
    }

    @Test func explicitRetryPublishesAfterTransientFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("local"), sharedPublicationInterval: .milliseconds(20))
        let settings = TaskSyncSettings(library: library, storageURL: root.appendingPathComponent("settings.json"))
        let task = ProcessingTask(title: "Before")
        try library.save(task)
        try await settings.enable(folder: root.appendingPathComponent("cloud"), originals: false)
        defer { try? settings.disable() }
        let url = try #require(library.url(for: task.id))
        try library.commitCheckpoint(taskID: task.id) { $0.title = "Pending local edit" }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try await Task.sleep(for: .milliseconds(150))
        let documents = try #require(library.sharedDocuments)
        #expect(documents.publicationErrors[url.standardizedFileURL] != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try settings.retryPublication()
        #expect(documents.pendingURLs.isEmpty)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)).title == "Pending local edit")
    }

}
