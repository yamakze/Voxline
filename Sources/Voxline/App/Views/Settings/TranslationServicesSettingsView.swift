import VoxlineTranslation
import SwiftUI
import VoxlineCore

public struct TranslationServicesSettingsView: View {
    @State private var store = TranslationServiceStore.shared
    @State private var isAddingService = false
    @State private var editingService: TranslationServiceConfig?
    @State private var errorMessage: String?
    @State private var connectionTask: Task<Void, Never>?
    private var referencedService: TranslationServiceConfig?

    public init(referencedSettings: TranslationSettings? = nil) {
        if let api = referencedSettings?.api, let id = api.serviceID, let settings = referencedSettings {
            referencedService = .init(id: id, name: api.modelID, baseURL: api.baseURL, modelID: api.modelID,
                                      batchSize: settings.batchSize, systemPrompt: api.systemPrompt)
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("字幕文本发送到所选服务；音频保持本地。密钥仅保存在本设备。")
                    .font(.caption).foregroundStyle(.secondary)
                if let referencedService, !store.services.contains(where: { $0.id == referencedService.id }) {
                    Text("本次任务引用的服务尚未在此设备配置。地址、模型和参数沿用任务快照。")
                        .font(.callout)
                    Button("配置本次服务") { editingService = referencedService }
                }
                if store.isLoading { ProgressView("读取服务与 Keychain…") }
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("重新读取") { Task { await store.load() } }.disabled(store.isLoading || store.isSaving)
                }
                // Inset Grouped Service Cards
                if store.services.isEmpty {
                    ContentUnavailableView(
                        "尚未配置翻译服务",
                        systemImage: "character.bubble",
                        description: Text("点击右上角“+”按钮配置 OpenAI 或本地 Ollama 接口以开启字幕翻译。")
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
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                Text("翻译服务")
                    .font(.headline)
            }

            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }

            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await store.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新读取服务与 Keychain 凭据")
                .disabled(store.isLoading || store.isSaving)

                Button {
                    isAddingService = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加翻译服务…")
                .disabled(store.isLoading || store.isSaving)
            }
        }
        .navigationTitle("翻译服务")
        .onDisappear { connectionTask?.cancel() }
        .sheet(isPresented: $isAddingService) {
            ServiceEditorModal(service: nil, store: store) { newService, key in
                try await store.addOrUpdate(newService, apiKey: key)
            }
        }
        .sheet(item: $editingService) { service in
            ServiceEditorModal(service: service, store: store) { updated, key in
                try await store.addOrUpdate(updated, apiKey: key)
            }
        }
        .alert("服务配置未修改", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
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
                        connectionTask = Task {
                            defer { connectionTask = nil }
                            do { _ = try await store.testConnection(service: service) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.testingServiceID != nil || store.isLoading || store.isSaving)
                    .help("向服务发送一条短文本，调用当前模型验证聊天接口。")

                    if store.testingServiceID == service.id {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("连接中…").font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("取消测试") { connectionTask?.cancel() }
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

            Text("每批最多 \(service.batchSize) 条字幕").font(.caption).foregroundStyle(.secondary)

            Divider()

            // Service details
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("默认模型：").font(.caption2).foregroundStyle(.secondary)
                    Text(service.modelID).font(.caption.monospaced().bold())
                }

                HStack(spacing: 6) {
                    Text("API 密钥：").font(.caption2).foregroundStyle(.secondary)
                    Text(store.credentialPresence[service.id] == true ? "已保存在 Keychain" : "未设置（无鉴权）").font(.caption)
                }

                HStack {
                    Button("编辑", systemImage: "pencil") {
                        editingService = service
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .disabled(store.isLoading || store.isSaving)

                    Button("删除", systemImage: "trash") {
                        Task {
                            do { try await store.remove(id: service.id) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .disabled(store.isLoading || store.isSaving)
                }
            }
        }
        .padding(16)
        .liquidGlassSurface()
    }
}

// MARK: - Service Editor Modal with PasswordVisibilityField
private struct ServiceEditorModal: View {
    let original: TranslationServiceConfig?
    let store: TranslationServiceStore
    let onSave: (TranslationServiceConfig, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var baseURLString: String
    @State private var modelID: String
    @State private var batchSizeText: String
    @State private var systemPrompt: String
    @State private var apiKey: String
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var testSuccessMessage: String?
    @State private var isLoadingKey: Bool
    @State private var isSaving = false
    @State private var keyReadFailed = false
    @State private var connectionTask: Task<Void, Never>?

    init(service: TranslationServiceConfig?, store: TranslationServiceStore,
         onSave: @escaping (TranslationServiceConfig, String) async throws -> Void) {
        self.original = service
        self.store = store
        self.onSave = onSave
        _name = State(initialValue: service?.name ?? "")
        _baseURLString = State(initialValue: service?.baseURL.absoluteString ?? "https://api.openai.com/v1")
        _modelID = State(initialValue: service?.modelID ?? "gpt-4o-mini")
        _batchSizeText = State(initialValue: String(service?.batchSize ?? TranslationSettings.defaultBatchSize))
        _systemPrompt = State(initialValue: service?.systemPrompt ?? TranslationSettings.defaultSystemPrompt)
        _apiKey = State(initialValue: "")
        _isLoadingKey = State(initialValue: service.map { s in store.services.contains(where: { $0.id == s.id }) } ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Modal Header
            HStack {
                Text(original == nil ? "添加翻译服务" : "编辑翻译服务")
                    .font(.headline)
                Spacer()
                Button("取消") { connectionTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
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

                Section("字幕翻译参数") {
                    TextField("每批字幕数量", text: $batchSizeText)
                    Text("字幕和上下文容量较大时，每批可能少于此数量。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("系统提示词")
                    TextEditor(text: $systemPrompt).frame(minHeight: 80)
                        .accessibilityLabel("系统提示词")
                    Button("恢复默认提示词") { systemPrompt = TranslationSettings.defaultSystemPrompt }
                    Text("提示词控制翻译要求。字幕 ID 与 JSON 输出格式由应用固定维护；修改配置仅影响后续任务。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("API 凭据") {
                    PasswordVisibilityField("输入 API 密钥", text: $apiKey)
                    Text("密钥保存到 Keychain。留空时不发送鉴权头，仅适用于无需密钥的服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isLoadingKey || isSaving)
            if isLoadingKey { ProgressView("读取 Keychain…") }
            if keyReadFailed { Button("重新读取密钥") { Task { await loadCredential() } } }

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
                .disabled(isTesting || isLoadingKey || isSaving)
                .help("向服务发送一条短文本，调用当前模型验证聊天接口。")

                if isTesting {
                    ProgressView().controlSize(.small)
                    Button("取消测试") { connectionTask?.cancel() }
                }

                Spacer()

                Button("保存配置") {
                    saveService()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || isLoadingKey || isTesting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        #if os(macOS)
        .frame(width: 560, height: 690)
        #else
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        #endif
        .interactiveDismissDisabled(isSaving || isTesting)
        .onDisappear { connectionTask?.cancel() }
        .task { await loadCredential() }
    }

    private func buildConfig() throws -> TranslationServiceConfig {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TranslationServiceError.invalidBaseURL
        }
        guard let batchSize = Int(batchSizeText.trimmingCharacters(in: .whitespacesAndNewlines)), batchSize > 0 else {
            throw ProjectValidationError.invalidTranslationBatchSize
        }
        let config = TranslationServiceConfig(
            id: original?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: url,
            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            batchSize: batchSize, systemPrompt: systemPrompt
        )
        try config.validate()
        return config
    }

    private func testConnection() {
        errorMessage = nil
        testSuccessMessage = nil
        isTesting = true

        connectionTask = Task {
            defer { isTesting = false; connectionTask = nil }
            do {
                let config = try buildConfig()
                testSuccessMessage = try await store.testConnection(service: config, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveService() {
        guard !keyReadFailed || !apiKey.isEmpty else {
            errorMessage = "旧密钥尚未读取，重试读取或填写新密钥后再保存。"
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let config = try buildConfig()
                try await onSave(config, apiKey)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func loadCredential() async {
        guard let original, store.services.contains(where: { $0.id == original.id }) else { return }
        isLoadingKey = true
        defer { isLoadingKey = false }
        do {
            apiKey = try await store.editingAPIKey(serviceID: original.id)
            keyReadFailed = false
            errorMessage = nil
        } catch { keyReadFailed = true; errorMessage = error.localizedDescription }
    }
}
