import Foundation
import Observation
import VoxlineCore

public struct CloudTranscriptionServiceConfig: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: URL
    public var modelID: String
    public var protocolKind: CloudTranscriptionProtocol

    public init(id: UUID = UUID(), name: String, baseURL: URL, modelID: String = "whisper-1", protocolKind: CloudTranscriptionProtocol = .audioTranscriptions) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.modelID = modelID; self.protocolKind = protocolKind
    }

    private enum CodingKeys: String, CodingKey { case id, name, baseURL, modelID, protocolKind }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        modelID = try values.decode(String.self, forKey: .modelID)
        protocolKind = try values.decodeIfPresent(CloudTranscriptionProtocol.self, forKey: .protocolKind) ?? .audioTranscriptions
    }

    public func settings(languageCode: String? = nil) throws -> TranscriptionSettings {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationServiceError.emptyName }
        let settings = TranscriptionSettings(provider: .openAICompatible, modelID: modelID,
            languageMode: languageCode == nil ? .automatic : .specified, languageCode: languageCode,
            cloud: .init(serviceID: id, baseURL: baseURL, protocolKind: protocolKind))
        try settings.validate()
        return settings
    }
}

@Observable @MainActor
public final class CloudTranscriptionServiceStore {
    public static let shared = CloudTranscriptionServiceStore()
    public private(set) var services: [CloudTranscriptionServiceConfig] = []
    public private(set) var credentialPresence: [UUID: Bool] = [:]
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    private let storageURL: URL
    private let vault: any TranslationCredentialVault
    private var initialLoad: Task<Void, Never>?

    init(storageURL: URL? = nil, vault: any TranslationCredentialVault = KeychainTranslationCredentialVault(service: "dev.voxline.transcription"), autoLoad: Bool = true) {
        self.storageURL = storageURL ?? URL.applicationSupportDirectory.appendingPathComponent("Voxline/TranscriptionServices.json")
        self.vault = vault
        if autoLoad { initialLoad = Task { await self.load() } }
    }

    public func load() async {
        guard !isLoading, !isSaving else { errorMessage = TranslationServiceError.busy.localizedDescription; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data: Data
            do { data = try Data(contentsOf: storageURL) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                services = []; credentialPresence = [:]; errorMessage = nil; return
            }
            let services = try JSONDecoder().decode([CloudTranscriptionServiceConfig].self, from: data)
            guard Set(services.map(\.id)).count == services.count else { throw TranslationServiceError.duplicateService }
            var presence: [UUID: Bool] = [:]
            for service in services {
                _ = try service.settings()
                presence[service.id] = try await vault.contains(serviceID: service.id)
            }
            self.services = services
            credentialPresence = presence
            errorMessage = nil
        } catch { errorMessage = "转写服务读取失败：\(error.localizedDescription)" }
    }

    public func addOrUpdate(_ service: CloudTranscriptionServiceConfig, apiKey: String) async throws {
        guard !isLoading, !isSaving else { throw TranslationServiceError.busy }
        _ = try service.settings()
        isSaving = true
        defer { isSaving = false }
        let previousKey = try await vault.read(serviceID: service.id)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try await vault.write(key.isEmpty ? nil : key, serviceID: service.id)
        var updated = services
        if let index = updated.firstIndex(where: { $0.id == service.id }) { updated[index] = service }
        else { updated.append(service) }
        do { try persist(updated) }
        catch {
            let writeError = error
            do { try await vault.write(previousKey, serviceID: service.id) }
            catch { errorMessage = TranslationServiceError.rollbackFailed(error.localizedDescription).localizedDescription; throw TranslationServiceError.rollbackFailed(error.localizedDescription) }
            throw writeError
        }
        services = updated
        credentialPresence[service.id] = !key.isEmpty
        errorMessage = nil
    }

    public func remove(id: UUID) async throws {
        guard !isLoading, !isSaving else { throw TranslationServiceError.busy }
        guard services.contains(where: { $0.id == id }) else { throw CloudTranscriptionError.unconfiguredService }
        isSaving = true
        defer { isSaving = false }
        let key = try await vault.read(serviceID: id)
        try await vault.write(nil, serviceID: id)
        let updated = services.filter { $0.id != id }
        do { try persist(updated) }
        catch {
            let writeError = error
            do { try await vault.write(key, serviceID: id) }
            catch { errorMessage = TranslationServiceError.rollbackFailed(error.localizedDescription).localizedDescription; throw TranslationServiceError.rollbackFailed(error.localizedDescription) }
            throw writeError
        }
        services = updated; credentialPresence[id] = nil; errorMessage = nil
    }

    public func apiKey(for settings: TranscriptionSettings) async throws -> String {
        try settings.validate()
        guard let cloud = settings.cloud else { throw CloudTranscriptionError.invalidConfiguration }
        await initialLoad?.value
        guard !isLoading, !isSaving else { throw TranslationServiceError.busy }
        guard errorMessage == nil else { throw TranslationServiceError.configurationUnavailable }
        guard let service = services.first(where: { $0.id == cloud.serviceID }) else { throw CloudTranscriptionError.unconfiguredService }
        guard service.baseURL == cloud.baseURL && service.protocolKind == cloud.protocolKind else { throw CloudTranscriptionError.changedEndpoint }
        let key = try await vault.read(serviceID: cloud.serviceID)
        // Actor reentrancy must not attach an old credential to a newly changed destination.
        guard !isLoading, !isSaving else { throw TranslationServiceError.busy }
        guard let current = services.first(where: { $0.id == cloud.serviceID }), current.baseURL == cloud.baseURL, current.protocolKind == cloud.protocolKind else { throw CloudTranscriptionError.changedEndpoint }
        guard errorMessage == nil else { throw TranslationServiceError.configurationUnavailable }
        return key ?? ""
    }

    public func editingAPIKey(serviceID: UUID) async throws -> String {
        guard let service = services.first(where: { $0.id == serviceID }) else { throw CloudTranscriptionError.unconfiguredService }
        return try await apiKey(for: service.settings())
    }

    private func persist(_ services: [CloudTranscriptionServiceConfig]) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(services).write(to: storageURL, options: .atomic)
    }

}
