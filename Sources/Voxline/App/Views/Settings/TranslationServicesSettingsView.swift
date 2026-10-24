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
    @State private var deletingService: TranslationServiceConfig?
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
                        Text(String(localized: "当前任务引用的服务尚未在此设备配置", bundle: appLocalizationBundle))
                            .font(.subheadline)
                        Spacer()
                        Button(String(localized: "配置此服务", bundle: appLocalizationBundle)) { editingService = referencedService }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.08), in: .rect(cornerRadius: 8))
                }

                if store.isLoading {
                    ProgressView(String(localized: "正在读取服务…", bundle: appLocalizationBundle))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }

                if let error = store.errorMessage {
                    HStack {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        Button(String(localized: "重试", bundle: appLocalizationBundle)) { Task { await store.load() } }.disabled(store.isLoading || store.isSaving)
                    }
                }

                // Inset Grouped Service Cards
                if store.services.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "尚未配置翻译服务", bundle: appLocalizationBundle), systemImage: "character.bubble")
                    } description: {
                        Text(String(localized: "配置 OpenAI 兼容接口或本地模型服务以启用字幕翻译。", bundle: appLocalizationBundle))
                    } actions: {
                        Button {
                            isAddingService = true
                        } label: {
                            Label(String(localized: "添加翻译服务", bundle: appLocalizationBundle), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLoading || store.isSaving)
                    }
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    HStack {
                        Text(String(localized: "已配置服务", bundle: appLocalizationBundle))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            isAddingService = true
                        } label: {
                            Label(String(localized: "添加服务", bundle: appLocalizationBundle), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(store.isLoading || store.isSaving)
                    }

                    VStack(spacing: 12) {
                        ForEach(store.services) { service in
                            serviceCard(service: service)
                        }
                    }
                }
            }
            .padding(24)
        }
        #if os(iOS)
        .navigationTitle(String(localized: "翻译服务", bundle: appLocalizationBundle))
        #else
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(String(localized: "翻译服务", bundle: appLocalizationBundle))
                    .font(.headline)
            }
        }
        #endif
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
        .confirmationDialog(String(localized: "本次任务使用此服务？", bundle: appLocalizationBundle), isPresented: Binding(
            get: { bindingService != nil }, set: { if !$0 { bindingService = nil } }), titleVisibility: .visible) {
            Button(String(localized: "绑定到本次任务", bundle: appLocalizationBundle)) {
                do {
                    if let bindingService { try onBindService?(bindingService) }
                    bindingService = nil
                } catch { errorMessage = error.localizedDescription }
            }
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) { bindingService = nil }
        } message: {
            Text(String(localized: "本次任务将使用所选服务地址和模型，保留原目标语言、批量数量、提示词与已有译文。\n\(bindingService?.name ?? "") · \(bindingService?.modelID ?? "")\n\(bindingService?.baseURL.absoluteString ?? "")", bundle: appLocalizationBundle))
        }
        .confirmationDialog(String(localized: "删除翻译服务？", bundle: appLocalizationBundle), isPresented: Binding(
            get: { deletingService != nil }, set: { if !$0 { deletingService = nil } }), titleVisibility: .visible) {
            Button(String(localized: "删除服务与本地密钥", bundle: appLocalizationBundle), role: .destructive) {
                guard let service = deletingService else { return }
                Task {
                    do {
                        try await store.remove(id: service.id)
                        deletingService = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) { deletingService = nil }
        } message: {
            Text(String(localized: "将从本设备删除该服务配置及钥匙串密钥。", bundle: appLocalizationBundle))
        }
        .alert(String(localized: "服务配置未修改", bundle: appLocalizationBundle), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func serviceCard(service: TranslationServiceConfig) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.teal.opacity(0.20), Color.teal.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.teal.opacity(0.24), lineWidth: 0.8)
                    )
                Image(systemName: "character.book.closed")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.teal)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(service.name)
                        .font(.headline)
                    Text(service.modelID)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: .capsule)
                }

                Text(service.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: store.credentialPresence[service.id] == true ? "key.fill" : "key.slash")
                        .font(.caption2)
                        .foregroundStyle(store.credentialPresence[service.id] == true ? .green : .secondary)
                    Text(store.credentialPresence[service.id] == true ? String(localized: "已存入钥匙串", bundle: appLocalizationBundle) : String(localized: "无密钥", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if onBindService != nil {
                    Button(referencedService?.id == service.id ? String(localized: "已绑定", bundle: appLocalizationBundle) : String(localized: "使用", bundle: appLocalizationBundle)) {
                        bindingService = service
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(referencedService?.id == service.id || store.isLoading || store.isSaving)
                }

                Button(String(localized: "编辑", bundle: appLocalizationBundle)) { editingService = service }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(String(localized: "删除", bundle: appLocalizationBundle), role: .destructive) { deletingService = service }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .nativeControlSurface()
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

    private var titleText: String {
        original == nil ? String(localized: "添加翻译服务", bundle: appLocalizationBundle) : String(localized: "编辑翻译服务", bundle: appLocalizationBundle)
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            editorForm
                .navigationTitle(titleText)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                            connectionTask?.cancel()
                            dismiss()
                        }
                        .disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "保存", bundle: appLocalizationBundle)) {
                            saveService()
                        }
                        .bold()
                        .disabled(isSaving || isLoadingKey || isTesting)
                    }
                }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .interactiveDismissDisabled(isSaving || isTesting)
        .onDisappear { connectionTask?.cancel() }
        .task { await loadCredential() }
        #elseif os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.teal.opacity(0.12))
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.teal)
                }
                .frame(width: 24, height: 24)
                Text(titleText)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }

            editorForm

            HStack {
                Button(String(localized: "测试连接", bundle: appLocalizationBundle)) {
                    testConnection()
                }
                .disabled(isTesting || isLoadingKey || isSaving)

                if isTesting {
                    ProgressView().controlSize(.small)
                    Button(String(localized: "取消测试", bundle: appLocalizationBundle)) { connectionTask?.cancel() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

                Spacer()

                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    connectionTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Button(String(localized: "保存", bundle: appLocalizationBundle)) {
                    saveService()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || isLoadingKey || isTesting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
        }
        .frame(width: 500)
        .frame(minHeight: 480, maxHeight: 620)
        .interactiveDismissDisabled(isSaving || isTesting)
        .onDisappear { connectionTask?.cancel() }
        .task { await loadCredential() }
        #endif
    }

    private var editorForm: some View {
        Form {
            Section(String(localized: "服务接入", bundle: appLocalizationBundle)) {
                TextField(String(localized: "名称", bundle: appLocalizationBundle), text: $name, prompt: Text(String(localized: "例如 OpenAI / DeepSeek", bundle: appLocalizationBundle)))
                TextField(String(localized: "接口地址", bundle: appLocalizationBundle), text: $baseURLString, prompt: Text("https://api.openai.com/v1"))
                TextField(String(localized: "模型", bundle: appLocalizationBundle), text: $modelID, prompt: Text("gpt-4o-mini"))
                PasswordVisibilityField(String(localized: "API 密钥（选填）", bundle: appLocalizationBundle), text: $apiKey)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAdvancedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.bold())
                        Text(String(localized: "高级选项", bundle: appLocalizationBundle))
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)

                if isAdvancedExpanded {
                    LabeledContent(String(localized: "每批字幕数", bundle: appLocalizationBundle)) {
                        TextField("", text: $batchSizeText)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }

                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 4) {
                            TextEditor(text: $systemPrompt)
                                .font(.callout)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 75)
                                .padding(4)
                                .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                                )

                            Button(String(localized: "恢复默认", bundle: appLocalizationBundle)) {
                                systemPrompt = TranslationSettings.defaultSystemPrompt
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.tint)
                        }
                    } label: {
                        Text(String(localized: "系统提示词", bundle: appLocalizationBundle))
                    }
                }
            }

            #if os(iOS)
            Section {
                HStack {
                    Button(String(localized: "测试连接", bundle: appLocalizationBundle)) {
                        testConnection()
                    }
                    .disabled(isTesting || isLoadingKey || isSaving)

                    if isTesting {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Button(String(localized: "取消测试", bundle: appLocalizationBundle)) { connectionTask?.cancel() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
            #endif

            if isLoadingKey {
                Section {
                    ProgressView(String(localized: "正在读取密钥…", bundle: appLocalizationBundle))
                }
            }
            if keyReadFailed {
                Section {
                    Button(String(localized: "重新读取密钥", bundle: appLocalizationBundle)) { Task { await loadCredential() } }
                }
            }

            if let errorMessage {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            if let testSuccessMessage {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text(testSuccessMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isLoadingKey || isSaving)
    }

    private func buildConfig() throws -> TranslationServiceConfig {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TranslationServiceError.invalidBaseURL
        }
        guard let batchSize = Int(batchSizeText.trimmingCharacters(in: .whitespacesAndNewlines)), batchSize > 0 else {
            throw DomainValidationError.invalidTranslationBatchSize
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
            errorMessage = String(localized: "旧密钥尚未读取，重试读取或填写新密钥后再保存。", bundle: appLocalizationBundle)
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
