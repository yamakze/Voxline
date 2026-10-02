import SwiftUI
import VoxlineCore

public struct TranslationServicesSettingsView: View {
    @State private var store = TranslationServiceStore.shared
    @State private var isAddingService = false
    @State private var editingService: TranslationServiceConfig?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .center) {
                    Text("翻译服务")
                        .font(.largeTitle.bold())
                    Spacer()
                    Button("添加服务…", systemImage: "plus") {
                        isAddingService = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Inset Grouped Service Cards
                if store.services.isEmpty {
                    ContentUnavailableView(
                        "尚未配置翻译服务",
                        systemImage: "character.bubble",
                        description: Text("点击右上角“添加服务”配置 OpenAI 或本地 Ollama 接口以开启字幕翻译。")
                    )
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 12) {
                        ForEach(store.services) { service in
                            serviceCard(service: service)
                        }
                    }
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $isAddingService) {
            ServiceEditorModal(service: nil) { newService in
                try? store.addOrUpdate(newService)
            }
        }
        .sheet(item: $editingService) { service in
            ServiceEditorModal(service: service) { updated in
                try? store.addOrUpdate(updated)
            }
        }
    }

    @ViewBuilder
    private func serviceCard(service: TranslationServiceConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                // Service Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "character.book.closed")
                        .font(.title3)
                        .foregroundStyle(.teal)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(service.name)
                            .font(.headline)

                        // Status dot from test result
                        if let result = store.testResult[service.id] {
                            switch result {
                            case .success:
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                    .help("接口连接正常")
                            case .failure:
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                    .help("接口连接异常")
                            }
                        }
                    }

                    Text(service.baseURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Test connection button
                VStack(alignment: .trailing, spacing: 4) {
                    Button("测试连接") {
                        Task { await store.testConnection(service: service) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.testingServiceID == service.id)

                    if store.testingServiceID == service.id {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("连接中…").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if let result = store.testResult[service.id] {
                        switch result {
                        case .success(let msg):
                            Text(msg).font(.caption2).foregroundStyle(.green)
                        case .failure(let err):
                            Text(err.localizedDescription).font(.caption2).foregroundStyle(.red)
                        }
                    }
                }
            }

            Divider()

            // Service details
            HStack(spacing: 24) {
                HStack(spacing: 6) {
                    Text("默认模型：").font(.caption2).foregroundStyle(.secondary)
                    Text(service.modelID).font(.caption.monospaced().bold())
                }

                HStack(spacing: 6) {
                    Text("API 密钥：").font(.caption2).foregroundStyle(.secondary)
                    Text(service.maskedAPIKey).font(.caption.monospaced())
                }

                Spacer()

                Button("编辑", systemImage: "pencil") {
                    editingService = service
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)

                Button("删除", systemImage: "trash") {
                    store.remove(id: service.id)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(16)
        .liquidGlassSurface()
    }
}

// MARK: - Service Editor Modal with PasswordVisibilityField
private struct ServiceEditorModal: View {
    let original: TranslationServiceConfig?
    let onSave: (TranslationServiceConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var baseURLString: String
    @State private var modelID: String
    @State private var apiKey: String
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var testSuccessMessage: String?

    init(service: TranslationServiceConfig?, onSave: @escaping (TranslationServiceConfig) -> Void) {
        self.original = service
        self.onSave = onSave
        _name = State(initialValue: service?.name ?? "")
        _baseURLString = State(initialValue: service?.baseURL.absoluteString ?? "https://api.openai.com/v1")
        _modelID = State(initialValue: service?.modelID ?? "gpt-4o-mini")
        _apiKey = State(initialValue: service?.apiKey ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Modal Header
            HStack {
                Text(original == nil ? "添加翻译服务" : "编辑翻译服务")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Divider()

            Form {
                Section("服务接入参数") {
                    TextField("显示名称（如 OpenAI 官方 / DeepSeek）", text: $name)
                    TextField("接口 Base URL（如 https://api.openai.com/v1）", text: $baseURLString)
                    TextField("默认模型 ID（如 gpt-4o-mini）", text: $modelID)
                }

                Section("API 凭据") {
                    PasswordVisibilityField("输入 sk-... 密钥", text: $apiKey)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal, 20)
            }
            if let testSuccessMessage {
                Text(testSuccessMessage).font(.caption).foregroundStyle(.green).padding(.horizontal, 20)
            }

            Divider()

            // Modal Footer
            HStack {
                Button("测试接口连通性") {
                    testConnection()
                }
                .disabled(isTesting)

                if isTesting {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button("保存配置") {
                    saveService()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .frame(width: 520, height: 460)
    }

    private func buildConfig() throws -> TranslationServiceConfig {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TranslationServiceError.invalidBaseURL
        }
        let config = TranslationServiceConfig(
            id: original?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: url,
            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try config.validate()
        return config
    }

    private func testConnection() {
        errorMessage = nil
        testSuccessMessage = nil
        isTesting = true

        Task {
            defer { isTesting = false }
            do {
                let config = try buildConfig()
                var request = URLRequest(url: config.baseURL.appendingPathComponent("models"))
                request.httpMethod = "GET"
                request.timeoutInterval = 10
                if !config.apiKey.isEmpty {
                    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                }

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw TranslationServiceError.connectionFailed("无效的 HTTP 响应")
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw TranslationServiceError.authFailed
                } else if http.statusCode >= 200 && http.statusCode < 300 {
                    testSuccessMessage = "测试连接成功 (HTTP \(http.statusCode))"
                } else {
                    throw TranslationServiceError.serviceUnavailable("HTTP 状态码 \(http.statusCode)")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveService() {
        do {
            let config = try buildConfig()
            onSave(config)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
