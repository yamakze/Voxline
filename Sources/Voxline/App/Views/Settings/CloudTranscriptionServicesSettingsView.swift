import SwiftUI
import VoxlineCore
import VoxlineTranslation

public struct CloudTranscriptionServicesSettingsView: View {
    @State private var store = CloudTranscriptionServiceStore.shared
    @State private var isAddingService = false
    @State private var editingService: CloudTranscriptionServiceConfig?
    @State private var errorMessage: String?
    @State private var deletingService: CloudTranscriptionServiceConfig?
    private var referencedService: CloudTranscriptionServiceConfig?

    public init(referencedSettings: TranscriptionSettings? = nil) {
        if let cloud = referencedSettings?.cloud {
            referencedService = .init(id: cloud.serviceID, name: "云端转写", baseURL: cloud.baseURL, modelID: referencedSettings?.modelID ?? "whisper-1", protocolKind: cloud.protocolKind)
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let referencedService, !store.services.contains(where: { $0.id == referencedService.id }) {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("当前任务引用的转写服务尚未在此设备配置")
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

                if store.services.isEmpty {
                    ContentUnavailableView {
                        Label("尚未配置云端转写服务", systemImage: "waveform.badge.mic")
                    } description: {
                        Text("添加兼容接口以启用云端转写")
                    } actions: {
                        Button {
                            isAddingService = true
                        } label: {
                            Label("添加转写服务", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLoading || store.isSaving)
                    }
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    HStack {
                        Text("已配置服务")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            isAddingService = true
                        } label: {
                            Label("添加服务", systemImage: "plus")
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
        .navigationTitle("云端转写服务")
        #endif
        .sheet(isPresented: $isAddingService) {
            CloudTranscriptionServiceEditorModal(service: nil, store: store)
        }
        .sheet(item: $editingService) { service in
            CloudTranscriptionServiceEditorModal(service: service, store: store)
        }
        .confirmationDialog("删除转写服务？", isPresented: Binding(
            get: { deletingService != nil }, set: { if !$0 { deletingService = nil } }), titleVisibility: .visible) {
            Button("删除服务与本地密钥", role: .destructive) {
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
            Button("取消", role: .cancel) { deletingService = nil }
        } message: {
            Text("将从本设备删除该服务配置及钥匙串密钥。")
        }
        .alert("服务操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func serviceCard(service: CloudTranscriptionServiceConfig) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "waveform")
                    .font(.system(size: 20))
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(service.name)
                        .font(.headline)
                    Text(service.protocolKind.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: .capsule)
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
                    Text(store.credentialPresence[service.id] == true ? "已存入钥匙串" : "无密钥")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button("编辑") { editingService = service }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("删除", role: .destructive) { deletingService = service }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .liquidGlassSurface()
    }
}

private struct CloudTranscriptionServiceEditorModal: View {
    let original: CloudTranscriptionServiceConfig?
    let store: CloudTranscriptionServiceStore
    @Environment(\.dismiss) private var dismiss

    @State private var protocolKind: CloudTranscriptionProtocol
    @State private var name: String
    @State private var baseURLString: String
    @State private var modelID: String
    @State private var apiKey: String
    @State private var errorMessage: String?
    @State private var isLoadingKey: Bool
    @State private var isSaving = false
    @State private var keyReadFailed = false

    init(service: CloudTranscriptionServiceConfig?, store: CloudTranscriptionServiceStore) {
        self.original = service
        self.store = store
        let proto = service?.protocolKind ?? .audioTranscriptions
        _protocolKind = State(initialValue: proto)
        _name = State(initialValue: service?.name ?? "")
        _baseURLString = State(initialValue: service?.baseURL.absoluteString ?? Self.defaultURL(for: proto))
        _modelID = State(initialValue: service?.modelID ?? Self.defaultModel(for: proto))
        _apiKey = State(initialValue: "")
        _isLoadingKey = State(initialValue: service.map { s in store.services.contains(where: { $0.id == s.id }) } ?? false)
    }

    private static func defaultURL(for proto: CloudTranscriptionProtocol) -> String {
        switch proto {
        case .audioTranscriptions: "https://api.openai.com/v1"
        case .geminiAudioChat: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .qwenAudioChat: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
    }

    private static func defaultModel(for proto: CloudTranscriptionProtocol) -> String {
        switch proto {
        case .audioTranscriptions: "whisper-1"
        case .geminiAudioChat: "gemini-2.5-flash"
        case .qwenAudioChat: "qwen3-asr-flash"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(original == nil ? "添加转写服务" : "编辑转写服务")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Divider()

            Form {
                Section("服务接入") {
                    Picker("预设协议", selection: $protocolKind) {
                        ForEach(CloudTranscriptionProtocol.allCases, id: \.self) { proto in
                            Text(proto.label).tag(proto)
                        }
                    }
                    .onChange(of: protocolKind) { oldProto, newProto in
                        guard oldProto != newProto else { return }
                        switch newProto {
                        case .audioTranscriptions:
                            modelID = "whisper-1"
                            if baseURLString.isEmpty || baseURLString == Self.defaultURL(for: .geminiAudioChat) || baseURLString == Self.defaultURL(for: .qwenAudioChat) {
                                baseURLString = Self.defaultURL(for: .audioTranscriptions)
                            }
                        case .geminiAudioChat:
                            if modelID == "whisper-1" || modelID.isEmpty || modelID == Self.defaultModel(for: .qwenAudioChat) {
                                modelID = Self.defaultModel(for: .geminiAudioChat)
                            }
                            if baseURLString.isEmpty || baseURLString == Self.defaultURL(for: .audioTranscriptions) || baseURLString == Self.defaultURL(for: .qwenAudioChat) {
                                baseURLString = Self.defaultURL(for: .geminiAudioChat)
                            }
                        case .qwenAudioChat:
                            if modelID == "whisper-1" || modelID.isEmpty || modelID == Self.defaultModel(for: .geminiAudioChat) {
                                modelID = Self.defaultModel(for: .qwenAudioChat)
                            }
                            if baseURLString.isEmpty || baseURLString == Self.defaultURL(for: .audioTranscriptions) || baseURLString == Self.defaultURL(for: .geminiAudioChat) {
                                baseURLString = Self.defaultURL(for: .qwenAudioChat)
                            }
                        }
                    }

                    TextField("名称", text: $name, prompt: Text(placeholderName))
                    TextField("API 根地址", text: $baseURLString, prompt: Text(Self.defaultURL(for: protocolKind)))

                    if protocolKind == .audioTranscriptions {
                        HStack {
                            Text("转写模型")
                            Spacer()
                            Text("whisper-1")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("转写模型", text: $modelID, prompt: Text(placeholderModel))
                    }

                    if isLoadingKey {
                        ProgressView("正在从钥匙串安全读取密钥…")
                            .font(.caption)
                    } else {
                        PasswordVisibilityField("API 密钥（选填）", text: $apiKey)
                    }
                    if keyReadFailed {
                        Text("未能读取已存密钥，可重新输入更新。")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || isLoadingKey || (keyReadFailed && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (protocolKind != .audioTranscriptions && modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .frame(minWidth: 480, minHeight: 400)
        .task {
            if let original, isLoadingKey {
                do {
                    apiKey = try await store.editingAPIKey(serviceID: original.id)
                    isLoadingKey = false
                } catch {
                    keyReadFailed = true
                    isLoadingKey = false
                }
            }
        }
    }

    private var placeholderName: String {
        switch protocolKind {
        case .audioTranscriptions: "例如 OpenAI / 自建 Whisper"
        case .geminiAudioChat: "例如 Google Gemini"
        case .qwenAudioChat: "例如 阿里百炼 / 通义千问"
        }
    }

    private var placeholderModel: String {
        switch protocolKind {
        case .audioTranscriptions: "whisper-1"
        case .geminiAudioChat: "例如 gemini-2.5-flash"
        case .qwenAudioChat: "例如 qwen3-asr-flash"
        }
    }

    private func save() {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            errorMessage = "请输入有效的 HTTP 或 HTTPS API 根地址。"
            return
        }
        let finalModel = protocolKind == .audioTranscriptions ? "whisper-1" : modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalModel.isEmpty else {
            errorMessage = "请输入转写模型 ID。"
            return
        }
        let config = CloudTranscriptionServiceConfig(
            id: original?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: url,
            modelID: finalModel,
            protocolKind: protocolKind
        )
        do {
            _ = try config.settings()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await store.addOrUpdate(config, apiKey: apiKey)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
