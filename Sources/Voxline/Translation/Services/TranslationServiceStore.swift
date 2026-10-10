import Foundation
import Observation
import VoxlineCore

/// Persisted service metadata. Credentials are exclusively stored in Keychain.
public struct TranslationServiceConfig: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: URL
    public var modelID: String
    public var batchSize: Int
    public var systemPrompt: String

    public init(id: UUID = UUID(), name: String, baseURL: URL, modelID: String,
                batchSize: Int = TranslationSettings.defaultBatchSize, systemPrompt: String = TranslationSettings.defaultSystemPrompt) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.modelID = modelID
        self.batchSize = batchSize; self.systemPrompt = systemPrompt
    }

    private enum CodingKeys: String, CodingKey { case id, name, baseURL, modelID, batchSize, systemPrompt }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), name: try values.decode(String.self, forKey: .name),
                  baseURL: try values.decode(URL.self, forKey: .baseURL), modelID: try values.decode(String.self, forKey: .modelID),
                  batchSize: try values.decode(Int.self, forKey: .batchSize),
                  systemPrompt: try values.decode(String.self, forKey: .systemPrompt))
        try validate()
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationServiceError.emptyName }
        _ = try TranslationSettings(baseURL: baseURL, modelID: modelID, targetLanguage: "zh-Hans", serviceID: id, batchSize: batchSize, systemPrompt: systemPrompt)
    }
}

public enum TranslationServiceError: Error, LocalizedError, Equatable {
    case emptyName, invalidBaseURL, busy, unknownService, changedEndpoint, duplicateService, configurationUnavailable, rollbackFailed(String)
    public var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "服务名称不能为空。", bundle: voxlineLocalizationBundle)
        case .invalidBaseURL: String(localized: "请输入有效的 HTTP 或 HTTPS 服务地址。", bundle: voxlineLocalizationBundle)
        case .busy: String(localized: "服务配置正在读取或保存，请稍后再试。", bundle: voxlineLocalizationBundle)
        case .unknownService: String(localized: "本次任务引用的翻译服务未在此设备配置，请配置本次服务或将任务绑定到已有服务。", bundle: voxlineLocalizationBundle)
        case .changedEndpoint: String(localized: "服务地址与任务参数不同，请调整任务翻译参数或恢复服务地址。", bundle: voxlineLocalizationBundle)
        case .duplicateService: String(localized: "服务配置包含重复 ID，未加载损坏配置。", bundle: voxlineLocalizationBundle)
        case .configurationUnavailable: String(localized: "服务配置读取失败，请重新读取或保存有效配置后再处理。", bundle: voxlineLocalizationBundle)
        case .rollbackFailed(let reason): String(localized: "配置未保存，旧密钥恢复也失败：\(reason)。请重新配置密钥。", bundle: voxlineLocalizationBundle)
        }
    }
}

@Observable
@MainActor
public final class TranslationServiceStore {
    public static let shared = TranslationServiceStore()
    public private(set) var services: [TranslationServiceConfig] = []
    public private(set) var credentialPresence: [UUID: Bool] = [:]
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public private(set) var testingServiceID: UUID?
    public private(set) var testResult: [UUID: Result<String, any Error>] = [:]
    private let storageURL: URL
    private let vault: any TranslationCredentialVault
    private let client: OpenAICompatibleTranslationClient
    private var initialLoad: Task<Void, Never>?

    init(storageURL: URL? = nil, vault: any TranslationCredentialVault = KeychainTranslationCredentialVault(),
         client: OpenAICompatibleTranslationClient = .init(), autoLoad: Bool = true) {
        self.storageURL = storageURL ?? URL.applicationSupportDirectory.appendingPathComponent("Voxline/TranslationServices.json")
        self.vault = vault
        self.client = client
        if autoLoad { initialLoad = Task { await self.load() } }
    }

    public func load() async {
        guard !isSaving, !isLoading else { errorMessage = TranslationServiceError.busy.localizedDescription; return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let data: Data
            do { data = try Data(contentsOf: storageURL) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                services = []; credentialPresence = [:]; return
            }
            let metadata = try JSONDecoder().decode([TranslationServiceConfig].self, from: data)
            guard Set(metadata.map(\.id)).count == metadata.count else { throw TranslationServiceError.duplicateService }
            var presence: [UUID: Bool] = [:]
            for service in metadata { presence[service.id] = try await vault.contains(serviceID: service.id) }
            services = metadata
            credentialPresence = presence
            errorMessage = nil
        } catch { errorMessage = String(localized: "服务配置读取失败：\(error.localizedDescription)", bundle: voxlineLocalizationBundle) }
    }

    public func addOrUpdate(_ service: TranslationServiceConfig, apiKey: String) async throws {
        guard !isLoading, !isSaving else { throw TranslationServiceError.busy }
        try service.validate()
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
            catch {
                let failure = TranslationServiceError.rollbackFailed(error.localizedDescription)
                errorMessage = failure.localizedDescription
                throw failure
            }
            throw writeError
        }
        services = updated
        errorMessage = nil
        credentialPresence[service.id] = !key.isEmpty
        testResult[service.id] = nil
    }

    public func remove(id: UUID) async throws {
        guard !isLoading, !isSaving else { throw TranslationServiceError.busy }
        guard services.contains(where: { $0.id == id }) else { throw TranslationServiceError.unknownService }
        isSaving = true
        defer { isSaving = false }
        let previousKey = try await vault.read(serviceID: id)
        try await vault.write(nil, serviceID: id)
        let updated = services.filter { $0.id != id }
        do { try persist(updated) }
        catch {
            let writeError = error
            do { try await vault.write(previousKey, serviceID: id) }
            catch {
                let failure = TranslationServiceError.rollbackFailed(error.localizedDescription)
                errorMessage = failure.localizedDescription
                throw failure
            }
            throw writeError
        }
        services = updated
        credentialPresence[id] = nil
        testResult[id] = nil
    }

    public func apiKey(for settings: TranslationSettings) async throws -> String {
        guard let api = settings.api else { throw DomainValidationError.invalidTranslationSettings }
        await initialLoad?.value
        guard !isLoading, !isSaving else { throw TranslationServiceError.busy }
        guard errorMessage == nil else { throw TranslationServiceError.configurationUnavailable }
        guard let id = api.serviceID, let service = services.first(where: { $0.id == id }) else { throw TranslationServiceError.unknownService }
        guard service.baseURL == api.baseURL else { throw TranslationServiceError.changedEndpoint }
        let key = try await vault.read(serviceID: id)
        guard !isLoading, !isSaving else { throw TranslationServiceError.busy }
        guard errorMessage == nil else { throw TranslationServiceError.configurationUnavailable }
        guard let current = services.first(where: { $0.id == id }) else { throw TranslationServiceError.unknownService }
        guard current.baseURL == api.baseURL else { throw TranslationServiceError.changedEndpoint }
        credentialPresence[id] = key != nil
        // Empty credentials explicitly use no Authorization header; authentication failures remain visible.
        return key ?? ""
    }

    public func editingAPIKey(serviceID: UUID) async throws -> String {
        guard let service = services.first(where: { $0.id == serviceID }) else { throw TranslationServiceError.unknownService }
        let settings = try TranslationSettings(baseURL: service.baseURL, modelID: service.modelID, targetLanguage: "zh", serviceID: serviceID, batchSize: service.batchSize, systemPrompt: service.systemPrompt)
        return try await apiKey(for: settings)
    }

    public func testConnection(service: TranslationServiceConfig, apiKey: String? = nil) async throws -> String {
        guard testingServiceID == nil else { throw TranslationServiceError.busy }
        try service.validate()
        testingServiceID = service.id
        defer { testingServiceID = nil }
        do {
            let settings = try TranslationSettings(baseURL: service.baseURL, modelID: service.modelID, targetLanguage: "zh-Hans", serviceID: service.id, batchSize: service.batchSize, systemPrompt: service.systemPrompt)
            let key: String
            if let apiKey { key = apiKey }
            else { key = try await self.apiKey(for: settings) }
            let cue = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 1000, sourceText: "Connection check.")
            let input = try SubtitleTranslationRequest(inputs: [.init(cue)], cues: [cue])
            _ = try await client.translate(settings: settings, apiKey: key, request: input)
            let result = String(localized: "模型 \(service.modelID) 的聊天接口可用", bundle: voxlineLocalizationBundle)
            testResult[service.id] = .success(result)
            return result
        } catch { testResult[service.id] = .failure(error); throw error }
    }

    private func persist(_ services: [TranslationServiceConfig]) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(services).write(to: storageURL, options: .atomic)
    }
}
