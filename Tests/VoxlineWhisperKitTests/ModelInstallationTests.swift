import Foundation
import Testing
@testable import VoxlineWhisperKit

@Suite("Pinned model installation")
struct ModelInstallationTests {
    @Test func verifiesGitBlobAndLFSAndRejectsSameSizeCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("weight.bin")
        try Data("hello".utf8).write(to: file)
        let git = ModelFileManifest.File(path: "weight.bin", byteCount: 5,
            digest: "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", algorithm: .gitSHA1)
        let lfs = ModelFileManifest.File(path: "weight.bin", byteCount: 5,
            digest: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", algorithm: .sha256)
        try ModelFileManifest.verify([git, lfs], in: directory, hashes: true)
        try Data("HELLO".utf8).write(to: file)
        #expect(throws: WhisperModelError.differentFile("weight.bin")) {
            try ModelFileManifest.verify([git], in: directory, hashes: true)
        }
        #expect(throws: WhisperModelError.differentFile("weight.bin")) {
            try ModelFileManifest.verify([lfs], in: directory, hashes: true)
        }
        try Data("he".utf8).write(to: file)
        #expect(throws: WhisperModelError.incompleteFile("weight.bin")) {
            try ModelFileManifest.verify([git], in: directory, hashes: false)
        }
    }

    @Test func partialDownloadsCountTowardsDiskUsageAndCannotLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try ModelFileManifest.baseline()
        let root = directory.appendingPathComponent(manifest.modelID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: root.appendingPathComponent("unfinished.bin"))
        let store = WhisperModelStore(directory: directory)
        let inventory = try await store.inventory(modelID: manifest.modelID)
        #expect(inventory.byteCount == 7)
        guard case .incomplete = inventory.state else { Issue.record("Partial model incorrectly installed"); return }
        await #expect(throws: (any Error).self) { try await store.load(modelID: manifest.modelID) }
        try await store.delete(modelID: manifest.modelID)
        let deleted = try await store.inventory(modelID: manifest.modelID)
        #expect(deleted.byteCount == 0)
        guard case .missing = deleted.state else { Issue.record("Model files remain after deletion"); return }
    }

    @Test func rejectsDifferentVersionsAndStorageFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try ModelFileManifest.baseline()
        let root = directory.appendingPathComponent(manifest.modelID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var receipt = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        receipt["modelRevision"] = "old-version"
        try JSONSerialization.data(withJSONObject: receipt).write(to: root.appendingPathComponent("installation.json"))
        let store = WhisperModelStore(directory: directory)
        let inventory = try await store.inventory(modelID: manifest.modelID)
        if case .incomplete(let reason) = inventory.state { #expect(reason == WhisperModelError.differentVersion.localizedDescription) }
        else { Issue.record("Mismatched version accepted") }
        await #expect(throws: WhisperModelError.unknownModel) {
            try await store.download(modelID: "different-model", onProgress: { _ in })
        }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blocked)
        let blockedStore = WhisperModelStore(directory: blocked)
        await #expect(throws: (any Error).self) {
            try await blockedStore.download(modelID: manifest.modelID, onProgress: { _ in })
        }
    }

    @Test func cancelledDownloadDoesNotCreateAnInstallation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try ModelFileManifest.baseline()
        let store = WhisperModelStore(directory: directory)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.download(modelID: manifest.modelID, onProgress: { _ in Issue.record("Cancelled operation reported progress") })
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        let inventory = try await store.inventory(modelID: manifest.modelID)
        #expect(inventory.byteCount == 0)
    }

    @Test func activityReportsLoadingAndReturnsToIdleAfterFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhisperModelStore(directory: directory)
        var changes = await store.activityChanges().makeAsyncIterator()
        #expect(await changes.next() == false)
        let modelID = try ModelFileManifest.baseline().modelID
        await #expect(throws: WhisperModelError.notInstalled) { try await store.load(modelID: modelID) }
        #expect(await changes.next() == true)
        #expect(await changes.next() == false)
    }

    @Test @MainActor func deletionFailurePreservesInventoryAndRetriesDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let modelID = try ModelFileManifest.baseline().modelID
        let root = directory.appendingPathComponent(modelID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("unfinished.bin")
        try Data("partial".utf8).write(to: file)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = WhisperModelStore(directory: directory)
        let manager = ModelManager(store: store)
        await manager.refresh(modelID: modelID)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        await manager.delete(modelID: modelID)
        #expect(manager.deletionErrors[modelID] != nil)
        let remaining = try await store.inventory(modelID: modelID)
        #expect(manager.diskUsage[modelID] == remaining.byteCount)
        guard case .corrupted = manager.status(for: modelID) else {
            Issue.record("Delete error replaced the actual partial installation state")
            return
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        await manager.delete(modelID: modelID)
        #expect(manager.deletionErrors[modelID] == nil)
        #expect(manager.status(for: modelID) == .notDownloaded)
        #expect(manager.diskUsage[modelID] == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_MODEL_DIRECTORY"] != nil))
    @MainActor func realLoadedModelRejectsBusyDeletionThenDeletesWithoutManualUnload() async throws {
        let models = try #require(ProcessInfo.processInfo.environment["VOXLINE_MODEL_DIRECTORY"])
        let modelID = try ModelFileManifest.baseline().modelID
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent(modelID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: models).appendingPathComponent(modelID), to: root)
        let store = WhisperModelStore(directory: directory)
        let manager = ModelManager(store: store)
        await manager.refresh(modelID: modelID)
        var changes = await store.activityChanges().makeAsyncIterator()
        #expect(await changes.next() == false)
        let loading = Task { try await store.load(modelID: modelID) }
        #expect(await changes.next() == true)
        for _ in 0..<100 where !manager.isOperating { await Task.yield() }
        #expect(manager.isOperating)
        await manager.delete(modelID: modelID)
        #expect(manager.deletionErrors[modelID] == "模型使用中")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("installation.json").path))
        try await loading.value
        #expect(await changes.next() == false)
        for _ in 0..<100 where manager.isOperating { await Task.yield() }
        await manager.refresh(modelID: modelID)
        guard case .ready = manager.status(for: modelID) else { Issue.record("Real model did not load"); return }
        await manager.delete(modelID: modelID)
        #expect(manager.deletionErrors[modelID] == nil)
        #expect(manager.status(for: modelID) == .notDownloaded)
        #expect(manager.diskUsage[modelID] == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // The private sample installation is a read-only source for this disposable copy.
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: models).appendingPathComponent(modelID).path))
    }
}
