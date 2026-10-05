#if os(iOS)
import Foundation
import Testing
import VoxlineCore
import VoxlineWhisperKit
import VoxlineWorkflow
@testable import VoxlineTranslation
@testable import VoxlineApp

@Suite("iOS local capability integration") @MainActor
struct IOSCapabilityTests {
    @Test func frameworkResourceProvidesPinnedModelInventory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inventory = try await WhisperModelStore(directory: directory).inventory(modelID: TranscriptionSettings.whisperKitBaseline.modelID)
        #expect(inventory.revision == "0f63a7800b00dd0226abd051b906c246e1907482")
        #expect(inventory.byteCount == 0)
        guard case .missing = inventory.state else { Issue.record("Missing weights must not appear installed or loaded"); return }
        await #expect(throws: WhisperModelError.self) {
            try await WhisperModelStore(directory: directory).inventory(modelID: "unknown-model")
        }
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
        #expect(throws: ProjectValidationError.self) { try library.readImportedTask(from: invalid) }
        #expect(library.task(task.id) == imported)
    }

    @Test func explicitDeviceServiceBindingUsesExistingKeychainAndKeepsImportedSourceUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TranslationServiceStore(storageURL: directory.appendingPathComponent("services.json"),
            vault: KeychainTranslationCredentialVault(service: "dev.voxline.binding-tests.\(UUID())"), autoLoad: false)
        let service = TranslationServiceConfig(name: "Existing device service", baseURL: URL(string: "https://example.com/v1")!, modelID: "device-model")
        let credential = "binding-test-\(UUID())"
        try await store.addOrUpdate(service, apiKey: credential)
        do {
            let old = try TranslationSettings(baseURL: service.baseURL, modelID: "imported-model", targetLanguage: "zh-Hans",
                serviceID: UUID(), batchSize: 2, systemPrompt: "Preserve tone.")
            let imported = ProcessingTask(title: "Imported service", parameters: .init(transcription: .whisperKitBaseline, translation: old))
            let source = directory.appendingPathComponent("source.voxline")
            let bytes = try TaskDocumentCodec.encode(imported)
            try bytes.write(to: source)
            let library = IOSTaskLibrary(directory: directory.appendingPathComponent("device"))
            try library.save(library.readImportedTask(from: source))
            await #expect(throws: TranslationServiceError.unknownService) { try await store.apiKey(for: old) }
            try library.bindTranslationService(service, taskID: imported.id)
            let settings = try #require(library.task(imported.id)?.parameters.translation)
            #expect(try await store.apiKey(for: settings) == credential)
            #expect(settings.api?.modelID == "device-model")
            #expect(settings.batchSize == 2)
            #expect(settings.api?.systemPrompt == "Preserve tone.")
            #expect(settings.targetLanguage == "zh-Hans")
            #expect(try Data(contentsOf: source) == bytes)
            #expect(IOSTaskLibrary(directory: directory.appendingPathComponent("device")).task(imported.id)?.parameters.translation == settings)
            try await store.remove(id: service.id)
        } catch {
            try await store.remove(id: service.id)
            throw error
        }
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
