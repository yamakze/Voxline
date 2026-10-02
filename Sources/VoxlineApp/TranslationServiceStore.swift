import Foundation
import Observation
import VoxlineCore

public struct TranslationServiceConfig: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: URL
    public var modelID: String
    public var apiKey: String

    public init(id: UUID = UUID(), name: String, baseURL: URL, modelID: String, apiKey: String = "") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelID = modelID
        self.apiKey = apiKey
    }

    public var maskedAPIKey: String {
        if apiKey.isEmpty { return "未设置密钥" }
        if apiKey.count <= 6 { return String(repeating: "•", count: apiKey.count) }
        let start = apiKey.prefix(3)
        let end = apiKey.suffix(3)
        return "\(start)••••••••\(end)"
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationServiceError.emptyName
        }
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = baseURL.host, !host.isEmpty else {
            throw TranslationServiceError.invalidBaseURL
        }
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationServiceError.emptyModel
        }
    }
}

public enum TranslationServiceError: LocalizedError, Equatable {
    case emptyName, invalidBaseURL, emptyModel, connectionFailed(String), authFailed, serviceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "服务名称不能为空。"
        case .invalidBaseURL: "请输入有效的 HTTP 或 HTTPS 服务地址，如 https://api.openai.com/v1。"
        case .emptyModel: "模型名称不能为空。"
        case .connectionFailed(let reason): "连接失败：\(reason)"
        case .authFailed: "鉴权失败：API 密钥无效或未授权。"
        case .serviceUnavailable(let reason): "服务不可用：\(reason)"
        }
    }
}

@Observable
@MainActor
public final class TranslationServiceStore {
    public static let shared = TranslationServiceStore()

    public var services: [TranslationServiceConfig] = []
    public var testingServiceID: UUID?
    public var testResult: [UUID: Result<String, TranslationServiceError>] = [:]

    private let storageURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        storageURL = appSupport.appendingPathComponent("Voxline/TranslationServices.json")
        load()
    }

    public func load() {
        do {
            let data = try Data(contentsOf: storageURL)
            services = try JSONDecoder().decode([TranslationServiceConfig].self, from: data)
        } catch {
            if services.isEmpty {
                // Default preset
                if let defaultURL = URL(string: "https://api.openai.com/v1") {
                    services = [
                        TranslationServiceConfig(
                            name: "OpenAI 官方",
                            baseURL: defaultURL,
                            modelID: "gpt-4o-mini",
                            apiKey: ""
                        )
                    ]
                }
            }
        }
    }

    public func save() throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(services)
        try data.write(to: storageURL, options: .atomic)
    }

    public func addOrUpdate(_ service: TranslationServiceConfig) throws {
        try service.validate()
        if let index = services.firstIndex(where: { $0.id == service.id }) {
            services[index] = service
        } else {
            services.append(service)
        }
        try save()
    }

    public func remove(id: UUID) {
        services.removeAll { $0.id == id }
        testResult.removeValue(forKey: id)
        try? save()
    }

    public func testConnection(service: TranslationServiceConfig) async {
        testingServiceID = service.id
        defer { testingServiceID = nil }

        do {
            try service.validate()
            var request = URLRequest(url: service.baseURL.appendingPathComponent("models"))
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            if !service.apiKey.isEmpty {
                request.setValue("Bearer \(service.apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TranslationServiceError.connectionFailed("无效的 HTTP 响应")
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                throw TranslationServiceError.authFailed
            } else if http.statusCode >= 200 && http.statusCode < 300 {
                testResult[service.id] = .success("连接成功 (HTTP \(http.statusCode))")
            } else {
                throw TranslationServiceError.serviceUnavailable("HTTP 状态码 \(http.statusCode)")
            }
        } catch let err as TranslationServiceError {
            testResult[service.id] = .failure(err)
        } catch {
            testResult[service.id] = .failure(.connectionFailed(error.localizedDescription))
        }
    }
}
