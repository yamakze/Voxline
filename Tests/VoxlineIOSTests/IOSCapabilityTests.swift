#if os(iOS)
import Foundation
import Testing
import VoxlineCore
import VoxlineWorkflow
@testable import VoxlineTranslation
@testable import VoxlineApp

@Suite("iOS local capability integration") @MainActor
struct IOSCapabilityTests {
    @Test func nativeListMoveIncludesPlaceholderOffsetsAndPreservesResultsAcrossRestartAndWriteFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = IOSTaskLibrary(directory: directory)
        let tasks = [ProcessingTask(title: "A"), ProcessingTask(title: "B"), ProcessingTask(title: "C")]
        for task in tasks { try library.save(task) }
        let invalidURL = directory.appendingPathComponent("invalid.voxline")
        let invalidBytes = Data("Invalid document".utf8)
        try invalidBytes.write(to: invalidURL)
        await library.load()
        let invalid = try #require(library.storage.entries.first { $0.url == invalidURL })
        let ids = tasks.map { $0.id.uuidString }
        try library.storage.reorder(entryIDs: [ids[0], invalid.id, ids[1], ids[2]])
        let originalBytes = try tasks.map { try Data(contentsOf: library.storage.defaultURL(for: $0.id)) }

        // onMove's destination is an insertion offset, including the end of the list.
        try library.moveTasks(fromOffsets: [0], toOffset: 4)
        #expect(library.tasks.map(\.id) == [tasks[1].id, tasks[2].id, tasks[0].id])
        #expect(library.storage.entries[0].id == invalid.id)
        let reopened = IOSTaskLibrary(directory: directory)
        #expect(reopened.tasks == library.tasks)
        #expect(reopened.storage.entries[0].id == invalid.id)
        try reopened.moveTasks(fromOffsets: [3], toOffset: 0)
        #expect(reopened.tasks == tasks)
        try reopened.moveTasks(fromOffsets: [0, 3], toOffset: 4)
        #expect(reopened.tasks == [tasks[1], tasks[0], tasks[2]])
        #expect(reopened.storage.entries[0].id == invalid.id)

        // A real filesystem failure must leave the last published order and documents intact.
        let orderURL = directory.appendingPathComponent("task-order.json")
        let savedOrder = try Data(contentsOf: orderURL)
        let savedIDs = reopened.storage.entries.map(\.id)
        try FileManager.default.removeItem(at: orderURL)
        try FileManager.default.createDirectory(at: orderURL, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try reopened.moveTasks(fromOffsets: [0], toOffset: 3) }
        #expect(reopened.storage.entries.map(\.id) == savedIDs)
        #expect(try FileManager.default.contentsOfDirectory(atPath: orderURL.path).isEmpty)
        for (task, bytes) in zip(tasks, originalBytes) {
            #expect(try Data(contentsOf: reopened.storage.defaultURL(for: task.id)) == bytes)
        }
        #expect(try Data(contentsOf: invalidURL) == invalidBytes)
        try FileManager.default.removeItem(at: orderURL)
        try savedOrder.write(to: orderURL)
        #expect(IOSTaskLibrary(directory: directory).tasks == reopened.tasks)
    }

    @Test func realIOSKeychainKeepsCredentialsOutOfMetadataAndPreservesFrozenConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("TranslationServices.json")
        let vault = KeychainTranslationCredentialVault(service: "dev.voxline.ios-tests.\(UUID())")
        let store = TranslationServiceStore(storageURL: file, vault: vault, autoLoad: false)
        var service = TranslationServiceConfig(name: "Device test", baseURL: URL(string: "https://example.com/v1")!,
                                              modelID: "test-model", batchSize: 7, systemPrompt: "Translate dialogue.")
        let credential = "isolated-test-\(UUID())"
        try await store.addOrUpdate(service, apiKey: credential)
        do {
            let metadata = try String(contentsOf: file, encoding: .utf8)
            #expect(!metadata.contains(credential))
            let frozen = try TranslationSettings(baseURL: service.baseURL, modelID: service.modelID,
                                                 targetLanguage: "zh-Hans", serviceID: service.id,
                                                 batchSize: service.batchSize, systemPrompt: service.systemPrompt)
            let reopened = TranslationServiceStore(storageURL: file, vault: vault, autoLoad: false)
            await reopened.load()
            #expect(reopened.errorMessage == nil)
            #expect(reopened.services == [service])
            #expect(try await reopened.apiKey(for: frozen) == credential)
            service.modelID = "new-model"; service.batchSize = 2; service.systemPrompt = "New defaults."
            try await reopened.addOrUpdate(service, apiKey: credential)
            #expect(frozen.api?.modelID == "test-model")
            #expect(frozen.batchSize == 7)
            #expect(frozen.api?.systemPrompt == "Translate dialogue.")
            service.baseURL = URL(string: "https://different.example/v1")!
            try await reopened.addOrUpdate(service, apiKey: credential)
            await #expect(throws: TranslationServiceError.changedEndpoint) { try await reopened.apiKey(for: frozen) }
            try await reopened.remove(id: service.id)
            #expect(try await vault.read(serviceID: service.id) == nil)
        } catch {
            try await vault.write(nil, serviceID: service.id)
            throw error
        }
    }

    @Test func deviceCopyUsesSharedStoreWithoutWritingImportedSourceOrStartingUnfinishedTranscription() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.voxline")
        var task = ProcessingTask(title: "Imported", items: [.init(title: "audio", kind: .audio, source: .localFile(fileName: "audio.wav"))])
        task.items[0].cues = [try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 500, sourceText: "Original")]
        let bytes = try TaskDocumentCodec.encode(task)
        try bytes.write(to: source)
        let copies = directory.appendingPathComponent("device")
        let library = IOSTaskLibrary(directory: copies)
        var imported = try library.readImportedTask(from: source)
        try library.save(imported)
        imported.title = "Device edit"
        try library.save(imported)
        let original = imported.items[0]
        var edited = original
        try edited.editSubtitle(comparedTo: original.cues[0], sourceText: "Device correction", translationText: "校对")
        try library.storage.updateItem(edited, taskID: task.id, comparedTo: original)
        imported.items[0] = edited
        #expect(throws: TaskValidationError.taskChanged) {
            try library.storage.updateItem(original, taskID: task.id, comparedTo: original)
        }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(library.storage.url(for: task.id) == copies.appendingPathComponent(task.id.uuidString).appendingPathExtension("voxline"))
        #expect(IOSTaskLibrary(directory: copies).task(task.id) == imported)
        #expect(throws: QueueError.self) { try library.startTranslation(taskID: task.id, mediaID: task.items[0].id) }
        let invalid = directory.appendingPathComponent("invalid.voxline")
        try Data(#"{"formatVersion":999}"#.utf8).write(to: invalid)
        #expect(throws: DomainValidationError.self) { try library.readImportedTask(from: invalid) }
        #expect(library.task(task.id) == imported)
    }

    #if targetEnvironment(simulator)
    @Test func simulatorRejectsAppleTranslationExplicitly() async {
        await #expect(throws: AppleSubtitleTranslationError.simulatorUnsupported) {
            try await AppleTranslationCoordinator.languagePair(sourceID: "en", targetID: "zh-Hans")
        }
    }
    #endif
}
#endif
