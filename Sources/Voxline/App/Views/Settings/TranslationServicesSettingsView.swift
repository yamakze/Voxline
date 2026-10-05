import VoxlineTranslation
import SwiftUI
import VoxlineCore

public struct TranslationServicesSettingsView: View {
    @State private var store = TranslationServiceStore.shared
    @State private var isAddingService = false
    @State private var editingService: TranslationServiceConfig?
    @State private var errorMessage: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var bindingService: TranslationServiceConfig?
    private var onBindService: ((TranslationServiceConfig) throws -> Void)?
    private var referencedService: TranslationServiceConfig?

    public init(referencedSettings: TranslationSettings? = nil, onBindService: ((TranslationServiceConfig) throws -> Void)? = nil) {
        self.onBindService = onBindService
        if let api = referencedSettings?.api, let id = api.serviceID, let settings = referencedSettings {
            referencedService = .init(id: id, name: api.modelID, baseURL: api.baseURL, modelID: api.modelID,
                                      batchSize: settings.batchSize, systemPrompt: api.systemPrompt)
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let referencedService, !store.services.contains(where: { $0.id == referencedService.id }) {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("当前任务引用的服务尚未在此设备配置")
                            .font(.subheadline)
                        Spacer()
                        Button("配置此服务") { editingService = referencedService }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.08), in: .rect(cornerRadius: 8))
                }

                if store.isLoading {
                    ProgressView("正在读取服务…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }

                if let error = store.errorMessage {
                    HStack {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        Button("重试") { Task { await store.load() } }.disabled(store.isLoading || store.isSaving)
                    }
                }

                // Inset Grouped Service Cards
                if store.services.isEmpty {
                    ContentUnavailableView(
                        "尚未配置翻译服务",
                        systemImage: "character.bubble",
                        description: Text("点击右上角“+”按钮配置 OpenAI 或本地 Ollama 接口以开启字幕翻译。")
                    )
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 12) {
                        ForEach(store.services) { service in
                            serviceCard(service: service)
                        }
                    }
                }
            }
            .padding(24)
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
        .confirmationDialog("本次任务使用此服务？", isPresented: Binding(
            get: { bindingService != nil }, set: { if !$0 { bindingService = nil } }), titleVisibility: .visible) {
            Button("绑定到本次任务") {
                do {
                    if let bindingService { try onBindService?(bindingService) }
                    bindingService = nil
                } catch { errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { bindingService = nil }
        } message: {
            Text("本次任务将使用所选服务地址和模型，保留原目标语言、批量数量、提示词与已有译文。\n\(bindingService?.name ?? "") · \(bindingService?.modelID ?? "")\n\(bindingService?.baseURL.absoluteString ?? "")")
        }
        .alert("服务配置未修改", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func serviceCard(service: TranslationServiceConfig) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.teal.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "character.book.closed")
                    .font(.system(size: 18))
                    .foregroundStyle(.teal)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(service.name)
                        .font(.headline)

                    if let result = store.testResult[service.id] {
                        switch result {
                        case .success:
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                                .help("连接正常")
                        case .failure:
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                                .help("连接失败")
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text(service.modelID)
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text(service.baseURL.host ?? service.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                if onBindService != nil {
                    Button(referencedService?.id == service.id ? "已绑定" : "使用") {
                        bindingService = service
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(referencedService?.id == service.id || store.isLoading || store.isSaving)
                }

                if store.testingServiceID == service.id {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("测试中…").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Button("测试") {
                        connectionTask = Task {
                            defer { connectionTask = nil }
                            do { _ = try await store.testConnection(service: service) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.testingServiceID != nil || store.isLoading || store.isSaving)
                }

                Menu {
                    Button {
                        editingService = service
                    } label: {
                        Label("编辑…", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        Task {
                            do { try await store.remove(id: service.id) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24, height: 24)
            }
        }
        .padding(14)
        .liquidGlassSurface(cornerRadius: 12)
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
    @State private var isAdvancedExpanded = false

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
            HStack {
                Text(original == nil ? "添加翻译服务" : "编辑翻译服务")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    connectionTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Divider()

            Form {
                Section("服务接入") {
                    TextField("名称", text: $name, prompt: Text("例如 OpenAI / DeepSeek"))
                    TextField("接口地址", text: $baseURLString, prompt: Text("https://api.openai.com/v1"))
                    TextField("模型", text: $modelID, prompt: Text("gpt-4o-mini"))
                    PasswordVisibilityField("API 密钥（选填）", text: $apiKey)
                }

                Section {
                    DisclosureGroup("高级选项", isExpanded: $isAdvancedExpanded) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("每批字幕数")
                                Spacer()
                                TextField("数量", text: $batchSizeText)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("系统提示词")
                                    Spacer()
                                    Button("恢复默认") {
                                        systemPrompt = TranslationSettings.defaultSystemPrompt
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                }
                                TextEditor(text: $systemPrompt)
                                    .font(.callout)
                                    .frame(minHeight: 90)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                    )
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isLoadingKey || isSaving)

            if isLoadingKey {
                ProgressView("正在读取密钥…")
                    .padding(.vertical, 8)
            }
            if keyReadFailed {
                Button("重新读取密钥") { Task { await loadCredential() } }
                    .padding(.vertical, 4)
            }

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            if let testSuccessMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text(testSuccessMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }

            Divider()

            HStack {
                Button("测试连接") {
                    testConnection()
                }
                .disabled(isTesting || isLoadingKey || isSaving)

                if isTesting {
                    ProgressView().controlSize(.small)
                    Button("取消") { connectionTask?.cancel() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

                Spacer()

                Button("保存") {
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
        .frame(width: 500, height: 480)
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
