import Foundation
import Testing
import AVFoundation
import VoxlineCore
@testable import VoxlineWhisperKit

@Suite("Local model installation")
struct ModelInstallationTests {
    @Test(arguments: WhisperModels.all.map(\.id)) func partialDownloadsCountTowardsDiskUsageAndCannotLoad(modelID: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent(modelID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: root.appendingPathComponent("unfinished.bin"))
        let store = WhisperModelStore(directory: directory)
        let inventory = try await store.inventory(modelID: modelID)
        #expect(inventory.byteCount == 7)
        guard case .incomplete = inventory.state else { Issue.record("Partial model incorrectly installed"); return }
        await #expect(throws: (any Error).self) { try await store.load(modelID: modelID) }
        try await store.delete(modelID: modelID)
        let deleted = try await store.inventory(modelID: modelID)
        #expect(deleted.byteCount == 0)
        guard case .missing = deleted.state else { Issue.record("Model files remain after deletion"); return }
    }

    @Test func unknownModelsAndStorageFailuresAreExplicit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WhisperModelStore(directory: directory)
        await #expect(throws: WhisperModelError.unknownModel) {
            try await store.download(modelID: "different-model", onProgress: { _ in })
        }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blocked)
        let blockedStore = WhisperModelStore(directory: blocked)
        await #expect(throws: (any Error).self) {
            try await blockedStore.download(modelID: WhisperModels.all[0].id, onProgress: { _ in })
        }
    }

    @Test func cancelledDownloadDoesNotCreateAnInstallation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelID = TranscriptionSettings.whisperKitBaseline.modelID
        let store = WhisperModelStore(directory: directory)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.download(modelID: modelID, onProgress: { _ in Issue.record("Cancelled operation reported progress") })
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        let inventory = try await store.inventory(modelID: modelID)
        #expect(inventory.byteCount == 0)
    }

    @Test func activityReportsLoadingAndReturnsToIdleAfterFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhisperModelStore(directory: directory)
        var changes = await store.activityChanges().makeAsyncIterator()
        #expect(await changes.next() == false)
        let modelID = TranscriptionSettings.whisperKitBaseline.modelID
        await #expect(throws: WhisperModelError.notInstalled) { try await store.load(modelID: modelID) }
        #expect(await changes.next() == true)
        #expect(await changes.next() == false)
    }

    @Test @MainActor func deletionFailurePreservesInventoryAndRetriesDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let modelID = TranscriptionSettings.whisperKitBaseline.modelID
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
    func realLoadedModelRejectsBusyDeletionThenDeletesWithoutManualUnload() async throws {
        let models = try #require(ProcessInfo.processInfo.environment["VOXLINE_MODEL_DIRECTORY"])
        let modelID = TranscriptionSettings.whisperKitBaseline.modelID
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent(modelID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: models).appendingPathComponent(modelID), to: root)
        let store = WhisperModelStore(directory: directory)
        var changes = await store.activityChanges().makeAsyncIterator()
        #expect(await changes.next() == false)
        let loading = Task { try await store.load(modelID: modelID) }
        #expect(await changes.next() == true)
        await #expect(throws: WhisperTranscriptionError.busy) { try await store.delete(modelID: modelID) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("installation.json").path))
        try await loading.value
        #expect(await changes.next() == false)
        let loaded = try await store.inventory(modelID: modelID)
        guard case .loaded = loaded.state else { Issue.record("Real model did not load"); return }
        try await store.delete(modelID: modelID)
        let deleted = try await store.inventory(modelID: modelID)
        #expect(deleted.byteCount == 0)
        guard case .missing = deleted.state else { Issue.record("Model files remain after deletion"); return }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: models).appendingPathComponent(modelID).path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_MULTI_MODEL_AUDIO"] != nil))
    func realCatalogDownloadsLoadsAndTranscribes() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["VOXLINE_MULTI_MODEL_AUDIO"])
        let cachedDirectory = ProcessInfo.processInfo.environment["VOXLINE_MULTI_MODEL_DIRECTORY"]
        let directory = cachedDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.temporaryDirectory.appendingPathComponent("Voxline-model-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if cachedDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: source))
        let frames = AVAudioFrameCount(min(input.length, 480_000))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames))
        try input.read(into: buffer, frameCount: frames)
        let audioURL = directory.appendingPathComponent("speech.wav")
        do {
            let output = try AVAudioFile(forWriting: audioURL, settings: input.processingFormat.settings)
            try output.write(from: buffer)
        }
        let audio = try TranscriptionAudio(localURL: audioURL, sourceStartMilliseconds: 0,
            durationMilliseconds: Int64((buffer.frameLength + 15) / 16))
        let store = WhisperModelStore(directory: directory)
        let models = try ProcessInfo.processInfo.environment["VOXLINE_MULTI_MODEL_ID"].map {
            [try WhisperModels.model(id: $0)]
        } ?? WhisperModels.all
        for model in models {
            let previous = try await store.inventory(modelID: model.id)
            if case .installed = previous.state {
                print("MODEL_INTEGRATION reusing test download \(model.id)")
            } else {
                print("MODEL_INTEGRATION downloading \(model.id)")
                try await store.download(modelID: model.id, onProgress: { _ in })
            }
            let reopened = WhisperModelStore(directory: directory)
            let installed = try await reopened.inventory(modelID: model.id)
            guard case .installed = installed.state else { Issue.record("Downloaded model is not installed"); return }
            #expect(installed.byteCount > 0)
            let settings = TranscriptionSettings(modelID: model.id, languageMode: .specified, languageCode: "en")
            let provider = try WhisperKitTranscriptionProvider(settings: settings, store: store,
                evidenceDirectory: directory.appendingPathComponent("Evidence"))
            let evidence = try await provider.transcribeEvidence(audio: audio)
            #expect(evidence.outcome == .completed)
            #expect(evidence.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let result = try SubtitleSegmenter.segment(evidence, sourceID: UUID(), mediaDurationMilliseconds: audio.durationMilliseconds)
            #expect(!result.cues.isEmpty)
            print("MODEL_INTEGRATION completed \(model.id) cues=\(result.cues.count) text=\(evidence.segments.map(\.text).joined())")
        }
        // The worker switches models automatically; deleting installed models needs no manual unload.
        for model in models {
            try await store.delete(modelID: model.id)
            let deleted = try await store.inventory(modelID: model.id)
            guard case .missing = deleted.state else { Issue.record("Model remains after deletion"); return }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_MULTI_MODEL_AUDIO"] != nil))
    func realDownloadCancellationKeepsPartialFilesAndReinstalls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhisperModelStore(directory: directory)
        let modelID = "openai_whisper-tiny"
        let (progress, continuation) = AsyncStream<WhisperModelDownloadProgress>.makeStream()
        let operation = Task {
            defer { continuation.finish() }
            try await store.download(modelID: modelID) { continuation.yield($0) }
        }
        var cancelledAfterDownloading = false
        for await value in progress {
            if case .files(_, let fraction) = value, fraction > 0, fraction < 1 {
                cancelledAfterDownloading = true
                operation.cancel()
                break
            }
        }
        #expect(cancelledAfterDownloading)
        await #expect(throws: CancellationError.self) { try await operation.value }
        let partial = try await store.inventory(modelID: modelID)
        #expect(partial.byteCount > 0)
        guard case .incomplete = partial.state else { Issue.record("Cancelled download was accepted as installed"); return }
        await #expect(throws: (any Error).self) { try await store.load(modelID: modelID) }
        try await store.download(modelID: modelID, onProgress: { _ in })
        let installed = try await store.inventory(modelID: modelID)
        guard case .installed = installed.state else { Issue.record("Re-download could not complete installation"); return }
        try await store.delete(modelID: modelID)
    }

}
