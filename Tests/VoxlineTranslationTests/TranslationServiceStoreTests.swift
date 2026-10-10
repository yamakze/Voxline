import Foundation
import Testing
import VoxlineCore
@testable import VoxlineTranslation

@Suite("Local translation settings and credentials", .serialized)
@MainActor
struct TranslationServiceStoreTests {
    private func service(id: UUID = UUID(), name: String = "Local test") -> TranslationServiceConfig {
        .init(id: id, name: name, baseURL: URL(string: "https://test.example/v1")!, modelID: "selected")
    }

    @Test func customParametersPersistAndServiceEditsLeaveFrozenTaskSettingsIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("services.json")
        let vault = TestCredentialVault()
        let store = TranslationServiceStore(storageURL: url, vault: vault, autoLoad: false)
        var configured = service()
        configured.baseURL = URL(string: "https://test.example/proxy/v1?api-version=2026-01")!
        configured.batchSize = 7
        configured.systemPrompt = "译为简体中文，保留专名。"
        try await store.addOrUpdate(configured, apiKey: "test-only-secret")
        let snapshot = try TranslationSettings(baseURL: configured.baseURL, modelID: configured.modelID,
            targetLanguage: "zh", serviceID: configured.id, batchSize: configured.batchSize, systemPrompt: configured.systemPrompt)
        configured.batchSize = 50
        configured.systemPrompt = "保持口语风格。"
        try await store.addOrUpdate(configured, apiKey: "test-only-secret")
        let reopened = TranslationServiceStore(storageURL: url, vault: vault, autoLoad: false)
        await reopened.load()
        #expect(reopened.services == [configured])
        #expect(snapshot.batchSize == 7)
        #expect(snapshot.api?.systemPrompt == "译为简体中文，保留专名。")
        #expect(try await reopened.apiKey(for: snapshot) == "test-only-secret")
        let data = try Data(contentsOf: url)
        #expect(!String(decoding: data, as: UTF8.self).contains("test-only-secret"))
        configured.batchSize = 0
        await #expect(throws: DomainValidationError.invalidTranslationBatchSize) {
            try await reopened.addOrUpdate(configured, apiKey: "replacement-test-key")
        }
        #expect(try Data(contentsOf: url) == data)
        #expect(await vault.read(serviceID: configured.id) == "test-only-secret")
    }

    @Test func missingOrInvalidParametersFailLoadingAndPreserveConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("services.json")
        let configured = service()
        let vault = TestCredentialVault()
        let store = TranslationServiceStore(storageURL: url, vault: vault, autoLoad: false)
        try await store.addOrUpdate(configured, apiKey: "test-only-key")
        let valid = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(configured)) as? [String: Any])
        let invalidParameters: [(String, Any?)] = [
            ("batchSize", nil), ("systemPrompt", nil), ("batchSize", NSNull()),
            ("batchSize", 0), ("batchSize", "seven"), ("systemPrompt", NSNull()), ("systemPrompt", 7)
        ]
        for (field, value) in invalidParameters {
            var object = valid
            object[field] = value
            let broken = try JSONSerialization.data(withJSONObject: [object])
            try broken.write(to: url)
            await store.load()
            #expect(store.errorMessage != nil)
            #expect(store.services == [configured])
            #expect(try Data(contentsOf: url) == broken)
            #expect(await vault.read(serviceID: configured.id) == "test-only-key")
            let reopened = TranslationServiceStore(storageURL: url, vault: vault, autoLoad: false)
            await reopened.load()
            #expect(reopened.errorMessage != nil)
            #expect(reopened.services.isEmpty)
        }
    }

    @Test func firstTranslationWaitsForInitialMetadataLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("services.json")
        let configured = service()
        try JSONEncoder().encode([configured]).write(to: url)
        let vault = TestCredentialVault()
        try await vault.write("test-only-key", serviceID: configured.id)
        let store = TranslationServiceStore(storageURL: url, vault: vault)
        let frozen = try TranslationSettings(baseURL: configured.baseURL, modelID: configured.modelID, targetLanguage: "zh", serviceID: configured.id)
        #expect(try await store.apiKey(for: frozen) == "test-only-key")
        #expect(store.services == [configured])
        #expect(!store.isLoading)
    }

    @Test func saveAndDeleteFailuresRestoreCredentialsAndPreserveLastMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("settings")
        let url = parent.appendingPathComponent("services.json")
        let vault = TestCredentialVault()
        let store = TranslationServiceStore(storageURL: url, vault: vault, autoLoad: false)
        let original = service()
        try await store.addOrUpdate(original, apiKey: "old-test-key")
        let saved = try Data(contentsOf: url)
        let backup = directory.appendingPathComponent("last-saved")
        try FileManager.default.moveItem(at: parent, to: backup)
        try Data("occupied".utf8).write(to: parent)
        var updated = original
        updated.name = "New metadata"
        await #expect(throws: (any Error).self) { try await store.addOrUpdate(updated, apiKey: "new-test-key") }
        #expect(store.services == [original])
        #expect(await vault.read(serviceID: original.id) == "old-test-key")
        #expect(try Data(contentsOf: backup.appendingPathComponent("services.json")) == saved)
        await #expect(throws: (any Error).self) { try await store.remove(id: original.id) }
        #expect(store.services == [original])
        #expect(await vault.read(serviceID: original.id) == "old-test-key")
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: backup, to: parent)
        try await store.remove(id: original.id)
        #expect(store.services.isEmpty)
        #expect(await vault.read(serviceID: original.id) == nil)
        #expect(try JSONDecoder().decode([TranslationServiceConfig].self, from: Data(contentsOf: url)).isEmpty)
    }

    @Test func invalidFileAndChangedServiceNeverUseDefaultsOrRouteFrozenTasksElsewhere() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("services.json")
        let vault = TestCredentialVault()
        let store = TranslationServiceStore(storageURL: url, vault: vault, autoLoad: false)
        await store.load()
        #expect(store.errorMessage == nil)
        #expect(store.services.isEmpty)
        let configured = service()
        try await store.addOrUpdate(configured, apiKey: "test-key")
        let frozen = try TranslationSettings(baseURL: configured.baseURL, modelID: "frozen-model", targetLanguage: "zh", serviceID: configured.id)
        #expect(try await store.apiKey(for: frozen) == "test-key")
        var changed = configured
        changed.baseURL = URL(string: "https://different.example/v1")!
        try await store.addOrUpdate(changed, apiKey: "other-test-key")
        await #expect(throws: TranslationServiceError.changedEndpoint) { try await store.apiKey(for: frozen) }
        try Data("broken".utf8).write(to: url)
        await store.load()
        #expect(store.errorMessage != nil)
        #expect(store.services == [changed])
        await #expect(throws: TranslationServiceError.configurationUnavailable) { try await store.apiKey(for: frozen) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_KEYCHAIN_TEST"] == "1"))
    func realKeychainRoundTripKeepsCredentialOutOfMetadata() async throws {
        let vault = KeychainTranslationCredentialVault(service: "dev.voxline.tests.\(UUID().uuidString)")
        let id = UUID()
        #expect(try await vault.read(serviceID: id) == nil)
        #expect(try await vault.contains(serviceID: id) == false)
        try await vault.write("test-only-keychain-value", serviceID: id)
        #expect(try await vault.contains(serviceID: id))
        #expect(try await vault.read(serviceID: id) == "test-only-keychain-value")
        try await vault.write("test-only-updated-value", serviceID: id)
        #expect(try await vault.read(serviceID: id) == "test-only-updated-value")
        try await vault.write(nil, serviceID: id)
        #expect(try await vault.read(serviceID: id) == nil)
    }
}

actor TestCredentialVault: TranslationCredentialVault {
    private var values: [UUID: String] = [:]
    func read(serviceID: UUID) -> String? { values[serviceID] }
    func contains(serviceID: UUID) -> Bool { values[serviceID] != nil }
    func write(_ key: String?, serviceID: UUID) throws {
        values[serviceID] = key
    }
}
