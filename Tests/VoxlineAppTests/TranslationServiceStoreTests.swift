import Foundation
import Testing
import VoxlineCore
@testable import VoxlineApp

@Suite("Local translation settings and credentials", .serialized)
@MainActor
struct TranslationServiceStoreTests {
    private func service(id: UUID = UUID(), name: String = "Local test") -> TranslationServiceConfig {
        .init(id: id, name: name, baseURL: URL(string: "https://test.example/v1")!, modelID: "selected")
    }

    @Test func plaintextMigrationIsRemovedOnlyAfterAllKeychainWritesSucceed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("services.json")
        let first = service(), second = service()
        let legacy = try JSONSerialization.data(withJSONObject: [first, second].enumerated().map { index, service in
            ["id": service.id.uuidString, "name": service.name, "baseURL": service.baseURL.absoluteString,
             "modelID": service.modelID, "apiKey": "test-only-secret-\(index)"]
        })
        try legacy.write(to: url)
        let vault = TestCredentialVault()
        await vault.failWrites(for: second.id)
        let store = TranslationServiceStore(storageURL: url, vault: vault, autoLoad: false)
        await store.load()
        #expect(store.errorMessage != nil)
        #expect(store.services.isEmpty)
        #expect(try Data(contentsOf: url) == legacy)
        #expect(try await vault.read(serviceID: first.id) == "test-only-secret-0")
        await vault.failWrites(for: nil)
        await store.load()
        #expect(store.errorMessage == nil)
        #expect(store.services == [first, second])
        let clean = try String(contentsOf: url, encoding: .utf8)
        #expect(!clean.contains("apiKey"))
        #expect(!clean.contains("test-only-secret"))
        let settings = try TranslationSettings(baseURL: second.baseURL, modelID: second.modelID, targetLanguage: "zh", serviceID: second.id)
        #expect(try await store.apiKey(for: settings) == "test-only-secret-1")
        let reopened = TranslationServiceStore(storageURL: url, vault: vault, autoLoad: false)
        await reopened.load()
        #expect(reopened.services == [first, second])
        #expect(reopened.credentialPresence.values.allSatisfy { $0 })
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
        #expect(try await vault.read(serviceID: original.id) == "old-test-key")
        #expect(try Data(contentsOf: backup.appendingPathComponent("services.json")) == saved)
        await #expect(throws: (any Error).self) { try await store.remove(id: original.id) }
        #expect(store.services == [original])
        #expect(try await vault.read(serviceID: original.id) == "old-test-key")
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: backup, to: parent)
        try await store.remove(id: original.id)
        #expect(store.services.isEmpty)
        #expect(try await vault.read(serviceID: original.id) == nil)
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

private actor TestCredentialVault: TranslationCredentialVault {
    private var values: [UUID: String] = [:]
    private var failingID: UUID?
    func failWrites(for id: UUID?) { failingID = id }
    func read(serviceID: UUID) -> String? { values[serviceID] }
    func contains(serviceID: UUID) -> Bool { values[serviceID] != nil }
    func write(_ key: String?, serviceID: UUID) throws {
        if failingID == serviceID { throw TranslationCredentialError.invalidData }
        values[serviceID] = key
    }
}
